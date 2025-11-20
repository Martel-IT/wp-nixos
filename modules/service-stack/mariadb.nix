{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.wpbox.mariadb;
  wpCfg = config.services.wpbox.wordpress;
  hwCfg = config.services.wpbox.hardware;
in
{
  config = mkIf (config.services.wpbox.enable && cfg.enable) (
    let
      # Direct access to hardware config
      systemRamMb = hwCfg.ramMb;
      cpus = hwCfg.cores;
      
      wpEnabled = config.services.wpbox.enable;
      
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

      # PHP allocation
      availablePhpRamMb = systemRamMb - reservedRamMb;
      totalMaxChildren = max 2 (availablePhpRamMb / avgProcessMb);
      safeSiteCount = if numberOfSites > 0 then numberOfSites else 1;
      calculatedChildrenPerSite = max 2 (builtins.floor (totalMaxChildren / safeSiteCount));
      phpFpmRamMb = calculatedChildrenPerSite * avgProcessMb * safeSiteCount;

      # MariaDB lives inside the reserve
      osOverheadMb = 1024;
      availableInReserveMb = lib.max 512 (reservedRamMb - osOverheadMb);
      
      # 60% of reserve space to MariaDB
      dbBudgetMb = builtins.floor (availableInReserveMb * 0.60);

      innodbBufferPoolSizeMb = lib.min 16384 (builtins.floor(dbBudgetMb * 0.70));
      
      tmpTableSizeMb = if dbBudgetMb > 2048 then 128 else 64;
      maxHeapTableSizeMb = tmpTableSizeMb;
      
      sortBufferSizeMb = 2;
      readBufferSizeMb = 1;
      joinBufferSizeMb = 2;
      
      innodbLogFileSizeMb = lib.min 2048 (builtins.floor(innodbBufferPoolSizeMb * 0.25));

      maxConnections = 50 + (numberOfSites * 30) + (cpus * 10);

      threadCacheSize = builtins.floor(maxConnections * 0.10);
      tableOpenCache = 2000 + (numberOfSites * 200);
      innodbBufferPoolInstances = lib.min 8 (lib.max 1 (builtins.floor(innodbBufferPoolSizeMb / 1024)));

      defaultSettings = {
        "character-set-server" = "utf8mb4";
        "collation-server" = "utf8mb4_unicode_ci";
        max_allowed_packet = "256M";
        slow_query_log = "1";
        long_query_time = "2";
        "skip-log-bin" = true;
        innodb_file_per_table = "1";
        innodb_flush_log_at_trx_commit = "2";
        innodb_flush_method = "O_DIRECT";
        table_definition_cache = "4096";
      };

      tunedSettings = {
        innodb_buffer_pool_size = "${toString innodbBufferPoolSizeMb}M";
        innodb_buffer_pool_instances = toString innodbBufferPoolInstances;
        innodb_log_file_size = "${toString innodbLogFileSizeMb}M";
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
      warnings = 
        (optional (dbBudgetMb < 256)
          "WPBox MariaDB: Database budget is low (${toString dbBudgetMb}MB). Consider increasing osRamHeadroom.");

      services.mysql = {
        enable = true;
        package = cfg.package;
        dataDir = cfg.dataDir;
        
        settings = {
          mysqld = lib.mkMerge [
            defaultSettings
            (lib.mkIf cfg.autoTune.enable tunedSettings)
          ];
        };

        ensureDatabases = [];
        ensureUsers = [];
      };

      # Simplified info script - uses only config values
      system.activationScripts.wpbox-mariadb-info = lib.mkIf cfg.autoTune.enable (lib.mkAfter ''
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "   WPBox MariaDB Build-Time Tuning"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "   Configured RAM:     ${toString systemRamMb}MB"
        echo "   Configured Cores:   ${toString cpus}"
        echo "   Reserved (Stack):   ${toString reservedRamMb}MB"
        echo "   DB Budget:          ${toString dbBudgetMb}MB"
        echo "   InnoDB Buffer Pool: ${toString innodbBufferPoolSizeMb}MB"
        echo "   Max Connections:    ${toString maxConnections}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      '');

      systemd.tmpfiles.rules = [
        "d '${cfg.dataDir}' 0750 mysql mysql - -"
      ];
    }
  );
}