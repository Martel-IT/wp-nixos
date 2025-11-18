{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.wpbox.mariadb;
  wpCfg = config.services.wpbox.wordpress;
  hwCfg = config.hardware;
  
  # Helper to get detected or configured RAM
  getSystemRamMb = 
    if hwCfg.runtimeMemoryMb != null then
      hwCfg.runtimeMemoryMb
    else
      hwCfg.fallback.ramMb or 4096;
  
  # Helper to get detected or configured CPU cores    
  getSystemCores =
    if hwCfg.runtimeCores != null then
      hwCfg.runtimeCores
    else
      hwCfg.fallback.cores or 2;

  # Calculate PHP-FPM memory usage
  calculatePhpMemoryUsage = 
    let
      wpEnabled = wpCfg.enable or false;
      activeSites = if wpEnabled 
                    then filterAttrs (n: v: v.enabled) wpCfg.sites
                    else {};
      numberOfSites = length (attrNames activeSites);
      safeSiteCount = max 1 numberOfSites;
      
      # Get tuning parameters
      avgProcessMb = wpCfg.tuning.avgProcessSize or 70;
      reservedRamMb = wpCfg.tuning.osRamHeadroom or 2048;
      
      # Calculate PHP workers
      availablePhpRamMb = max 512 (getSystemRamMb - reservedRamMb);
      totalMaxChildren = max 2 (availablePhpRamMb / avgProcessMb);
      calculatedChildrenPerSite = max 2 (floor (totalMaxChildren / safeSiteCount));
    in
      calculatedChildrenPerSite * avgProcessMb * safeSiteCount;
in
{
  options.services.wpbox.mariadb = {
    enable = mkEnableOption "Managed MariaDB for WordPress";
    
    package = mkOption {
      type = types.package;
      default = pkgs.mariadb;
      description = "MariaDB package to use";
    };

    autoTune = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable MariaDB auto-tuning based on available RAM";
      };
      
      ramAllocationRatio = mkOption {
        type = types.float;
        default = 0.30;
        description = "Ratio of available RAM to allocate to MariaDB (0.30 = 30%)";
      };
      
      minBufferPoolMb = mkOption {
        type = types.int;
        default = 256;
        description = "Minimum InnoDB buffer pool size in MB";
      };
      
      maxBufferPoolMb = mkOption {
        type = types.int;
        default = 32768; # 32GB
        description = "Maximum InnoDB buffer pool size in MB";
      };
    };
    
    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/mysql";
      description = "Data directory for MariaDB";
    };

    backup = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable automated MariaDB backups";
      };
      
      schedule = mkOption {
        type = types.str;
        default = "daily";
        description = "Backup schedule (systemd timer format)";
      };
      
      retention = mkOption {
        type = types.int;
        default = 7;
        description = "Number of backup copies to retain";
      };
      
      path = mkOption {
        type = types.path;
        default = "/backup/mariadb";
        description = "Path where backups are stored";
      };
    };

    tuning = {
      # Manual tuning overrides
      innodbBufferPoolSize = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Manual override for InnoDB buffer pool size (e.g., '2G')";
      };
      
      maxConnections = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "Manual override for max connections";
      };
      
      queryCacheSize = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Manual override for query cache size (e.g., '128M')";
      };
    };
  };

  config = mkIf (config.services.wpbox.enable && cfg.enable) (
    let
      # System resources
      systemRamMb = getSystemRamMb;
      systemCores = getSystemCores;
      
      # Calculate memory budget
      phpFpmRamMb = if wpCfg.enable then calculatePhpMemoryUsage else 0;
      reservedRamMb = wpCfg.tuning.osRamHeadroom or 2048;
      
      # Available RAM for MariaDB
      availableForDb = max 256 (systemRamMb - phpFpmRamMb - reservedRamMb);
      dbBudgetMb = max cfg.autoTune.minBufferPoolMb 
                       (min cfg.autoTune.maxBufferPoolMb 
                            (builtins.floor (availableForDb * cfg.autoTune.ramAllocationRatio)));
      
      # --- Tuned Values ---
      # InnoDB Buffer Pool: 70% of DB budget
      innodbBufferPoolSizeMb = 
        if cfg.tuning.innodbBufferPoolSize != null then
          cfg.tuning.innodbBufferPoolSize
        else
          min cfg.autoTune.maxBufferPoolMb (builtins.floor (dbBudgetMb * 0.70));
      
      # Buffer Pool Instances (1 per GB, max 64)
      innodbBufferPoolInstances = 
        min 64 (max 1 (builtins.floor (innodbBufferPoolSizeMb / 1024)));
      
      # Log file size: 25% of buffer pool (max 2GB)
      innodbLogFileSizeMb = min 2048 (builtins.floor (innodbBufferPoolSizeMb * 0.25));
      
      # Query Cache
      queryCacheSizeMb = 
        if cfg.tuning.queryCacheSize != null then
          cfg.tuning.queryCacheSize
        else
          if dbBudgetMb > 4096 then 256
          else if dbBudgetMb > 2048 then 128
          else 64;
      
      # Connection pool
      numberOfSites = length (attrNames (filterAttrs (n: v: v.enabled) wpCfg.sites));
      maxConnections = 
        if cfg.tuning.maxConnections != null then
          cfg.tuning.maxConnections
        else
          50 + (numberOfSites * 30) + (systemCores * 10);
      
      # Thread cache
      threadCacheSize = min 256 (builtins.floor (maxConnections * 0.10));
      
      # Table cache  
      tableOpenCache = 2000 + (numberOfSites * 200);
      tableDefinitionCache = 1400 + (numberOfSites * 100);
      
      # Temp tables
      tmpTableSizeMb = if dbBudgetMb > 4096 then 256 else 128;
      maxHeapTableSizeMb = tmpTableSizeMb;
      
      # Per-thread buffers
      sortBufferSizeMb = if dbBudgetMb > 4096 then 4 else 2;
      readBufferSizeMb = if dbBudgetMb > 4096 then 2 else 1;
      joinBufferSizeMb = if dbBudgetMb > 4096 then 4 else 2;
      readRndBufferSizeMb = if dbBudgetMb > 4096 then 2 else 1;
    in
    {
      # Validation warnings
      warnings = 
        let 
          totalAllocatedMb = phpFpmRamMb + dbBudgetMb + reservedRamMb;
          connectionMemory = maxConnections * (sortBufferSizeMb + readBufferSizeMb + joinBufferSizeMb + 2);
          totalWithConnections = totalAllocatedMb + connectionMemory;
        in
        optional (systemRamMb > 0 && totalWithConnections > systemRamMb)
          "WPBox MariaDB: Total memory usage (${toString totalWithConnections}MB) may exceed system RAM (${toString systemRamMb}MB) under load!";

      # MariaDB service configuration
      services.mysql = {
        enable = true;
        package = cfg.package;
        dataDir = cfg.dataDir;
        
        settings = {
          mysqld = mkMerge [
            # Base configuration
            {
              # Character sets
              character_set_server = "utf8mb4";
              collation_server = "utf8mb4_unicode_ci";
              
              # Network
              bind_address = "127.0.0.1";
              port = 3306;
              skip_networking = false;
              max_allowed_packet = "256M";
              
              # Logging
              slow_query_log = true;
              long_query_time = 2;
              slow_query_log_file = "${cfg.dataDir}/slow-queries.log";
              log_error = "${cfg.dataDir}/error.log";
              
              # Binary logging (disabled for single-server setups)
              skip_log_bin = true;
              
              # Basic settings
              sql_mode = "STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION";
              default_storage_engine = "InnoDB";
              performance_schema = false; # Save memory on small instances
            }
            
            # Auto-tuned settings
            (mkIf cfg.autoTune.enable {
              # Connection settings
              max_connections = maxConnections;
              thread_cache_size = threadCacheSize;
              thread_stack = "256K";
              
              # InnoDB settings
              innodb_buffer_pool_size = "${toString innodbBufferPoolSizeMb}M";
              innodb_buffer_pool_instances = innodbBufferPoolInstances;
              innodb_log_file_size = "${toString innodbLogFileSizeMb}M";
              innodb_log_buffer_size = "32M";
              innodb_file_per_table = true;
              innodb_flush_log_at_trx_commit = 2;
              innodb_flush_method = "O_DIRECT";
              innodb_lock_wait_timeout = 50;
              innodb_read_io_threads = systemCores;
              innodb_write_io_threads = systemCores;
              innodb_io_capacity = if systemRamMb > 8192 then 2000 else 1000;
              innodb_io_capacity_max = if systemRamMb > 8192 then 4000 else 2000;
              
              # Query cache
              query_cache_type = 1;
              query_cache_size = "${toString queryCacheSizeMb}M";
              query_cache_limit = "2M";
              query_cache_min_res_unit = "2K";
              
              # Temp tables
              tmp_table_size = "${toString tmpTableSizeMb}M";
              max_heap_table_size = "${toString maxHeapTableSizeMb}M";
              
              # Per-thread buffers
              sort_buffer_size = "${toString sortBufferSizeMb}M";
              read_buffer_size = "${toString readBufferSizeMb}M";
              read_rnd_buffer_size = "${toString readRndBufferSizeMb}M";
              join_buffer_size = "${toString joinBufferSizeMb}M";
              
              # Table cache
              table_open_cache = tableOpenCache;
              table_definition_cache = tableDefinitionCache;
              
              # Other optimizations
              key_buffer_size = "32M"; # MyISAM index cache (minimal as we use InnoDB)
              myisam_sort_buffer_size = "32M";
              
              # WordPress specific optimizations
              optimizer_search_depth = 0; # Let optimizer choose
              optimizer_prune_level = 1;
            })
          ];
        };
      };

      # Backup configuration
      systemd.services.mariadb-backup = mkIf cfg.backup.enable {
        description = "MariaDB Backup Service";
        after = [ "mysql.service" ];
        requires = [ "mysql.service" ];
        
        serviceConfig = {
          Type = "oneshot";
          User = "mysql";
          Group = "mysql";
          
          ExecStart = pkgs.writeScript "mariadb-backup" ''
            #!${pkgs.bash}/bin/bash
            set -e
            
            BACKUP_DIR="${cfg.backup.path}"
            TIMESTAMP=$(date +%Y%m%d_%H%M%S)
            BACKUP_FILE="$BACKUP_DIR/mariadb_backup_$TIMESTAMP.sql.gz"
            
            # Create backup directory
            mkdir -p "$BACKUP_DIR"
            
            # Perform backup
            echo "Starting MariaDB backup..."
            ${cfg.package}/bin/mysqldump \
              --all-databases \
              --single-transaction \
              --quick \
              --lock-tables=false \
              --routines \
              --triggers \
              --events \
              | ${pkgs.gzip}/bin/gzip -9 > "$BACKUP_FILE"
            
            echo "Backup completed: $BACKUP_FILE"
            
            # Cleanup old backups
            echo "Cleaning old backups..."
            find "$BACKUP_DIR" -name "mariadb_backup_*.sql.gz" -mtime +${toString cfg.backup.retention} -delete
            
            echo "Backup process completed successfully"
          '';
        };
      };

      # Backup timer
      systemd.timers.mariadb-backup = mkIf cfg.backup.enable {
        description = "MariaDB Backup Timer";
        wantedBy = [ "timers.target" ];
        
        timerConfig = {
          OnCalendar = cfg.backup.schedule;
          Persistent = true;
          RandomizedDelaySec = "30min";
        };
      };

      # System tmpfiles
      systemd.tmpfiles.rules = [
        "d '${cfg.dataDir}' 0750 mysql mysql - -"
        "d '${hwCfg.detectionCache.directory}' 0755 root root - -"
      ] ++ optional cfg.backup.enable
        "d '${cfg.backup.path}' 0750 mysql mysql - -";

      # Activation script for info display
      system.activationScripts.wpbox-mariadb-info = mkAfter (mkIf cfg.autoTune.enable ''
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "   WPBox MariaDB Configuration"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "   System RAM:         ${toString systemRamMb}MB"
        echo "   CPU Cores:          ${toString systemCores}"
        echo "   Reserved (OS):      ${toString reservedRamMb}MB"
        echo "   PHP-FPM RAM:        ${toString phpFpmRamMb}MB"
        echo "   DB Budget:          ${toString dbBudgetMb}MB"
        echo ""
        echo "   Tuned Settings:"
        echo "   ├─ Buffer Pool:     ${toString innodbBufferPoolSizeMb}MB (${toString innodbBufferPoolInstances} instances)"
        echo "   ├─ Log File Size:   ${toString innodbLogFileSizeMb}MB"
        echo "   ├─ Query Cache:     ${toString queryCacheSizeMb}MB"
        echo "   ├─ Max Connections: ${toString maxConnections}"
        echo "   ├─ Tmp Table Size:  ${toString tmpTableSizeMb}MB"
        echo "   └─ Table Cache:     ${toString tableOpenCache}"
        echo ""
        echo "   Auto-Tuning: ${if cfg.autoTune.enable then "✓ ENABLED" else "✗ DISABLED"}"
        echo "   Backups:     ${if cfg.backup.enable then "✓ ENABLED (${cfg.backup.schedule})" else "✗ DISABLED"}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      '');
    }
  );
}
