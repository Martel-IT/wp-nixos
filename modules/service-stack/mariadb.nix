{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.wpbox.mariadb;
  wpCfg = config.services.wpbox.wordpress;
in
{
  # No options defined here (see interface.nix)

  config = mkIf (config.services.wpbox.enable && cfg.enable) {
    
    let
      # --- 1. GET SYSTEM & PHP-FPM FACTS ---
      
      systemRamMb = config.hardware.memorySize or 4096;
      cpus = config.nix.settings.cores or 2;
      
      wpEnabled = config.services.wpbox.wordpress.enable or false;
      
      # Calculate PHP-FPM's total RAM usage
      activeSites = if wpEnabled 
                    then filterAttrs (n: v: v.enabled) config.services.wpbox.wordpress.sites
                    else {};
      numberOfSites = length (attrNames activeSites);
      
      wpTuning = config.services.wpbox.wordpress.tuning or {
        osRamHeadroom = 2048;
        avgProcessSize = 70;
      };
      
      reservedRamMb = wpTuning.osRamHeadroom or 2048;
      avgProcessMb = wpTuning.avgProcessSize or 70;

      availablePhpRamMb = systemRamMb - reservedRamMb;
      totalMaxChildren = max 2 (availablePhpRamMb / avgProcessMb);
      safeSiteCount = if numberOfSites > 0 then numberOfSites else 1;
      calculatedChildrenPerSite = max 2 (floor (totalMaxChildren / safeSiteCount));
      
      phpFpmRamMb = calculatedChildrenPerSite * avgProcessMb * safeSiteCount;

      # --- 2. CALCULATE DB BUDGET ---
      
      availableRamMb = lib.max 512 (systemRamMb - phpFpmRamMb - reservedRamMb);
      
      # Final budget for MariaDB
      dbBudgetMb = builtins.floor(availableRamMb * cfg.autoTune.ramAllocationRatio);

      # --- 3. CALCULATE TUNED VALUES ---
      
      # InnoDB Buffer Pool: 70% of DB budget (max 16GB for small servers)
      innodbBufferPoolSizeMb = lib.min 16384 (builtins.floor(dbBudgetMb * 0.70));
      
      # Query Cache (MariaDB still supports it well, unlike MySQL 8)
      # We allocate a small amount if budget permits
      queryCacheSizeMb = lib.min 128 (builtins.floor(dbBudgetMb * 0.05));
      
      # Tmp Table Size
      tmpTableSizeMb = if dbBudgetMb > 2048 then 128 else 64;
      maxHeapTableSizeMb = tmpTableSizeMb;
      
      # Buffers per connection
      sortBufferSizeMb = 2;
      readBufferSizeMb = 1;
      joinBufferSizeMb = 2;
      
      # InnoDB Log File Size: 25% of buffer pool (max 2GB)
      innodbLogFileSizeMb = lib.min 2048 (builtins.floor(innodbBufferPoolSizeMb * 0.25));
      
      # Max Connections
      maxConnections = 50 + (numberOfSites * 30) + (cpus * 10);
      
      # Thread Cache
      threadCacheSize = builtins.floor(maxConnections * 0.10);
      
      # Table Open Cache
      tableOpenCache = 2000 + (numberOfSites * 200);
      
      # InnoDB instances
      innodbBufferPoolInstances = lib.min 8 (lib.max 1 (builtins.floor(innodbBufferPoolSizeMb / 1024)));

      # --- Default Settings ---
      defaultSettings = {
        "character-set-server" = "utf8mb4";
        "collation-server" = "utf8mb4_unicode_ci";
        max_allowed_packet = "256M";
        slow_query_log = "1";
        long_query_time = "2";
        "skip-log-bin" = true; # Disable binlog for perf unless replication needed
        innodb_file_per_table = "1";
        innodb_flush_log_at_trx_commit = "2"; # 2 is faster, 1 is safer
        innodb_flush_method = "O_DIRECT";
        table_definition_cache = "4096";
      };
      
      # --- Tuned Settings ---
      tunedSettings = {
        innodb_buffer_pool_size = "${toString innodbBufferPoolSizeMb}M";
        innodb_buffer_pool_instances = toString innodbBufferPoolInstances;
        innodb_log_file_size = "${toString innodbLogFileSizeMb}M";
        
        query_cache_type = "1"; # Enable for MariaDB
        query_cache_limit = "2M";
        query_cache_size = "${toString queryCacheSizeMb}M";
        
        tmp_table_size = "${toString tmpTableSizeMb}M";
        max_heap_table_size = "${toString maxHeapTableSizeMb}M";
        
        sort_buffer_size = "${toString sortBufferSizeMb}M";
        read_buffer_size = "${toString readBufferSizeMb}M";
        join_buffer_size = "${toString joinBufferSizeMb}M";
        
        max_connections = toString maxConnections;
        thread_cache_size = toString threadCacheSize;
        table_open_cache = toString tableOpenCache;
      };
    in
    {
      # --- SAFETY CHECKS ---
      warnings = 
        let 
          totalAllocatedMb = phpFpmRamMb + dbBudgetMb + reservedRamMb;
        in
        optional (systemRamMb > 0 && totalAllocatedMb > systemRamMb)
          "WPBox MariaDB: Total allocated RAM (${toString totalAllocatedMb}MB) exceeds system RAM (${toString systemRamMb}MB). Risk of OOM!";

      # --- ENABLE MARIADB SERVICE ---
      # Note: NixOS uses 'services.mysql' even for MariaDB package
      services.mysql = {
        enable = true;
        package = cfg.package;
        dataDir = cfg.dataDir;
        
        settings = lib.mkMerge [
          defaultSettings
          (lib.mkIf cfg.autoTune.enable tunedSettings)
        ];
        
        ensureDatabases = [];
        ensureUsers = [];
      };

      # --- ACTIVATION INFO ---
      system.activationScripts.wpbox-mariadb-info = lib.mkIf cfg.autoTune.enable ''
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "🗄️  WPBox MariaDB Auto-Tuning"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "   System RAM:         ${toString systemRamMb}MB"
        echo "   Reserved (OS):      ${toString reservedRamMb}MB"
        echo "   PHP-FPM RAM:        ${toString phpFpmRamMb}MB"
        echo "   DB Budget:          ${toString dbBudgetMb}MB"
        echo "   InnoDB Buffer Pool: ${toString innodbBufferPoolSizeMb}MB"
        echo "   Query Cache:        ${toString queryCacheSizeMb}MB"
        echo "   Max Connections:    ${toString maxConnections}"
        echo "   Auto-Tuning:        ${if cfg.autoTune.enable then "✓ ENABLED" else "✗ DISABLED"}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      '';

      # --- SYSTEMD TMPFILES ---
      systemd.tmpfiles.rules = [
        "d '${cfg.dataDir}' 0750 mysql mysql - -"
      ];
    };
};
}