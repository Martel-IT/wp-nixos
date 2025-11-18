{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.wpbox.mariadb;
  wpCfg = config.services.wpbox.wordpress;

  getDetectedRamMb = 
    let
      ramFile = "/run/wpbox/detected-ram-mb";
      fallbackRam = 4096;
    in
    if config.hardware.runtimeMemoryMb != null 
    then config.hardware.runtimeMemoryMb
    else fallbackRam;

  getDetectedCores =
    let
      coresFile = "/run/wpbox/detected-cores";
      fallbackCores = 2;
    in
    if config.hardware.runtimeCores != null
    then config.hardware.runtimeCores
    else fallbackCores;
in
{
  config = mkIf (config.services.wpbox.enable && cfg.enable) (
    let
      # --- 1. GET SYSTEM & PHP-FPM FACTS ---
      systemRamMb = getDetectedRamMb;
      cpus = getDetectedCores;
      
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
      
      # Tmp Table Size (Query Cache rimossa)
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
        "skip-log-bin" = true;
        innodb_file_per_table = "1";
        innodb_flush_log_at_trx_commit = "2";
        innodb_flush_method = "O_DIRECT";
        table_definition_cache = "4096";
      };

      # --- Tuned Settings ---
      tunedSettings = {
        innodb_buffer_pool_size = "${toString innodbBufferPoolSizeMb}M";
        innodb_buffer_pool_instances = toString innodbBufferPoolInstances;
        innodb_log_file_size = "${toString innodbLogFileSizeMb}M";
        
        # Query Cache rimosso per compatibilità futura
        
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
      system.activationScripts.wpbox-mariadb-info = lib.mkAfter (lib.mkIf cfg.autoTune.enable ''
        # Rileggi i valori reali dal file cache
        if [ -f /run/wpbox/detected-ram-mb ]; then
          ACTUAL_RAM=$(cat /run/wpbox/detected-ram-mb)
          ACTUAL_CORES=$(cat /run/wpbox/detected-cores)
        else
          ACTUAL_RAM=${toString systemRamMb}
          ACTUAL_CORES=${toString cpus}
        fi
        
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "   WPBox MariaDB Auto-Tuning"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "   System RAM:         ''${ACTUAL_RAM}MB (detected)"
        echo "   CPU Cores:          ''${ACTUAL_CORES} (detected)"
        echo "   Reserved (OS):      ${toString reservedRamMb}MB"
        echo "   PHP-FPM RAM:        ${toString phpFpmRamMb}MB"
        echo "   DB Budget:          ${toString dbBudgetMb}MB"
        echo "   InnoDB Buffer Pool: ${toString innodbBufferPoolSizeMb}MB"
        echo "   Max Connections:    ${toString maxConnections}"
        echo "   Auto-Tuning:        ${if cfg.autoTune.enable then "✓ ENABLED" else "✗ DISABLED"}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      '');

      # --- SYSTEMD TMPFILES ---
      systemd.tmpfiles.rules = [
        "d '${cfg.dataDir}' 0750 mysql mysql - -"
        "d /run/wpbox 0755 root root - -"
      ];
    }
  );
}