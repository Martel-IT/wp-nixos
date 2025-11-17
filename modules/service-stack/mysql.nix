{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.wpbox.mysql;
in
{
  ################################################
  ##                OPTIONS                     ##
  ################################################
  options.services.wpbox.mysql = {
    enable = mkEnableOption "Auto-tuned MySQL for WordPress";

    package = mkOption {
      type = types.package;
      default = pkgs.mysql80;
      description = "MySQL package to use.";
    };

    autoTune = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable automatic tuning of MySQL based on system RAM/CPU.";
      };

      # Percentage of RAM *not* used by PHP-FPM to allocate to MySQL
      ramAllocationRatio = mkOption {
        type = types.float;
        default = 0.30; # 30% of available RAM after PHP
        description = "Percentage of (System RAM - PHP RAM) to dedicate to MySQL.";
      };
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/mysql";
      description = "MySQL data directory.";
    };
  };

  ################################################
  ##                CONFIGURATION               ##
  ################################################
  config = lib.mkIf cfg.enable (
    
    let
      # --- 1. GET SYSTEM & PHP-FPM FACTS ---
      
      # Get system specs (fallback to safe values)
      systemRamMb = config.hardware.memorySize or 4096;
      cpus = config.nix.settings.cores or 2;
      
      # Get WordPress/PHP-FPM configuration
      wpEnabled = config.services.wpbox.wordpress.enable or false;
      
      # Calculate PHP-FPM's total RAM usage
      # Get active sites and their worker counts
      activeSites = if wpEnabled 
                    then filterAttrs (n: v: v.enabled) config.services.wpbox.wordpress.sites
                    else {};
      numberOfSites = length (attrNames activeSites);
      
      # Get tuning config from wordpress module
      wpTuning = config.services.wpbox.wordpress.tuning or {
        osRamHeadroom = 2048;
        avgProcessSize = 70;
      };
      
      reservedRamMb = wpTuning.osRamHeadroom or 2048;
      avgProcessMb = wpTuning.avgProcessSize or 70;
      
      # Calculate PHP-FPM RAM usage (from php-fpm.nix logic)
      availablePhpRamMb = systemRamMb - reservedRamMb;
      totalMaxChildren = max 2 (availablePhpRamMb / avgProcessMb);
      safeSiteCount = if numberOfSites > 0 then numberOfSites else 1;
      calculatedChildrenPerSite = max 2 (floor (totalMaxChildren / safeSiteCount));
      
      # Total PHP-FPM RAM usage
      phpFpmRamMb = calculatedChildrenPerSite * avgProcessMb * safeSiteCount;
      
      # --- 2. CALCULATE MYSQL BUDGET ---
      
      # RAM left after OS headroom and PHP-FPM
      # We keep a 10% buffer for OS processes
      systemBufferMb = builtins.floor(reservedRamMb * 0.10);
      availableRamMb = lib.max 512 (systemRamMb - phpFpmRamMb - reservedRamMb);
      
      # Final budget for MySQL
      mysqlBudgetMb = builtins.floor(availableRamMb * cfg.autoTune.ramAllocationRatio);
      
      # --- 3. CALCULATE TUNED VALUES (MySQL Tuner logic) ---
      
      # InnoDB Buffer Pool: 70% of MySQL budget (max 16GB for small servers)
      innodbBufferPoolSizeMb = lib.min 16384 (builtins.floor(mysqlBudgetMb * 0.70));
      
      # Query Cache: 5% of MySQL budget (max 512MB)
      # Note: Query cache is deprecated in MySQL 8.0, but we keep for MySQL 5.7 compat
      queryCacheSizeMb = lib.min 512 (builtins.floor(mysqlBudgetMb * 0.05));
      
      # Tmp Table Size: 128MB default, scaled up for large RAM
      tmpTableSizeMb = if mysqlBudgetMb > 2048 then 256 else 128;
      
      # Max Heap Table Size: Same as tmp_table_size
      maxHeapTableSizeMb = tmpTableSizeMb;
      
      # Sort Buffer Size: 2MB default (per connection)
      sortBufferSizeMb = 2;
      
      # Read Buffer Size: 1MB default (per connection)
      readBufferSizeMb = 1;
      
      # Join Buffer Size: 2MB default (per connection)
      joinBufferSizeMb = 2;
      
      # InnoDB Log File Size: 25% of buffer pool (max 2GB)
      innodbLogFileSizeMb = lib.min 2048 (builtins.floor(innodbBufferPoolSizeMb * 0.25));
      
      # Max Connections: Based on CPU cores and sites
      # Formula: 50 base + (30 per site) + (10 per CPU core)
      maxConnections = 50 + (numberOfSites * 30) + (cpus * 10);
      
      # Thread Cache Size: Based on max connections
      threadCacheSize = builtins.floor(maxConnections * 0.10); # 10% of max connections
      
      # Table Open Cache: Based on number of sites
      tableOpenCache = 2000 + (numberOfSites * 200);
      
      # InnoDB instances: 1 per 1GB of buffer pool (max 8)
      innodbBufferPoolInstances = lib.min 8 (lib.max 1 (builtins.floor(innodbBufferPoolSizeMb / 1024)));
      
      # --- Default "safe" settings for WordPress workloads ---
      defaultSettings = {
        # Character set
        "character-set-server" = "utf8mb4";
        "collation-server" = "utf8mb4_unicode_ci";
        
        # Connection settings
        max_allowed_packet = "256M";
        
        # Slow query log
        slow_query_log = "1";
        long_query_time = "2";
        
        # Binary logging (disabled for performance, enable for replication)
        skip-log-bin = true;
        
        # InnoDB settings
        innodb_file_per_table = "1";
        innodb_flush_log_at_trx_commit = "2"; # 1 = full ACID, 2 = better performance
        innodb_flush_method = "O_DIRECT";
        
        # Query cache (deprecated in MySQL 8.0, ignored if not supported)
        query_cache_type = "0"; # Disabled by default in MySQL 8.0
        
        # Table cache
        table_definition_cache = "4096";
      };
      
      # --- Auto-Tuned settings (overrides defaults) ---
      tunedSettings = {
        # InnoDB Buffer Pool
        innodb_buffer_pool_size = "${toString innodbBufferPoolSizeMb}M";
        innodb_buffer_pool_instances = toString innodbBufferPoolInstances;
        innodb_log_file_size = "${toString innodbLogFileSizeMb}M";
        
        # Memory tables
        tmp_table_size = "${toString tmpTableSizeMb}M";
        max_heap_table_size = "${toString maxHeapTableSizeMb}M";
        
        # Connection buffers
        sort_buffer_size = "${toString sortBufferSizeMb}M";
        read_buffer_size = "${toString readBufferSizeMb}M";
        join_buffer_size = "${toString joinBufferSizeMb}M";
        
        # Connection settings
        max_connections = toString maxConnections;
        thread_cache_size = toString threadCacheSize;
        
        # Table cache
        table_open_cache = toString tableOpenCache;
      };

    in
    {
      # --- SAFETY CHECKS ---
      warnings = 
        let 
          totalAllocatedMb = phpFpmRamMb + mysqlBudgetMb + reservedRamMb;
        in
        optional (systemRamMb > 0 && totalAllocatedMb > systemRamMb)
          "⚠️  WPBox MySQL: Total allocated RAM (${toString totalAllocatedMb}MB) exceeds system RAM (${toString systemRamMb}MB). Risk of OOM!";

      # --- ENABLE MYSQL SERVICE ---
      services.mysql = {
        enable = true;
        package = cfg.package;
        dataDir = cfg.dataDir;
        
        # Merge: start with defaults, then apply tuned values if autoTune is on
        settings = lib.mkMerge [
          defaultSettings
          (lib.mkIf cfg.autoTune.enable tunedSettings)
        ];
        
        # Ensure Unix socket authentication for local connections
        ensureDatabases = [];
        ensureUsers = [];
      };

      # --- AUTHENTICATION: Unix socket (peer) for local connections ---
      # MySQL 8.0+ uses auth_socket by default for root@localhost
      # This is automatically configured, but we ensure it explicitly
      
      # --- ACTIVATION INFO ---
      system.activationScripts.wpbox-mysql-info = lib.mkIf cfg.autoTune.enable ''
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "🗄️  WPBox MySQL Auto-Tuning"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "   System RAM:         ${toString systemRamMb}MB"
        echo "   Reserved (OS):      ${toString reservedRamMb}MB"
        echo "   PHP-FPM RAM:        ${toString phpFpmRamMb}MB"
        echo "   MySQL Budget:       ${toString mysqlBudgetMb}MB"
        echo "   InnoDB Buffer Pool: ${toString innodbBufferPoolSizeMb}MB"
        echo "   Max Connections:    ${toString maxConnections}"
        echo "   Active Sites:       ${toString numberOfSites}"
        echo "   Auto-Tuning:        ${if cfg.autoTune.enable then "✓ ENABLED" else "✗ DISABLED"}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      '';

      # --- SYSTEMD TMPFILES ---
      systemd.tmpfiles.rules = [
        "d '${cfg.dataDir}' 0750 mysql mysql - -"
      ];
    }
  );
}
