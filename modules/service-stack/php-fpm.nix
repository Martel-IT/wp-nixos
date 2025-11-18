{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.wpbox.wordpress;
  phpCfg = config.services.wpbox.phpfpm;
  hwCfg = config.hardware;
  
  # Get system resources
  getSystemRamMb = 
    if hwCfg.runtimeMemoryMb != null then
      hwCfg.runtimeMemoryMb
    else
      hwCfg.fallback.ramMb or 4096;
  
  getSystemCores =
    if hwCfg.runtimeCores != null then
      hwCfg.runtimeCores
    else
      hwCfg.fallback.cores or 2;

  # Active sites
  activeSites = filterAttrs (n: v: v.enabled) cfg.sites;
  numberOfSites = length (attrNames activeSites);
  safeSiteCount = max 1 numberOfSites;
  
  # Calculate pool sizes
  calculatePoolSizes = 
    let
      systemRamMb = getSystemRamMb;
      systemCores = getSystemCores;
      
      # Tuning parameters
      autoTune = cfg.tuning.enableAuto;
      reservedRamMb = cfg.tuning.osRamHeadroom;
      avgProcessMb = cfg.tuning.avgProcessSize;
      
      # Available RAM for PHP
      availablePhpRamMb = max 512 (systemRamMb - reservedRamMb);
      
      # Total workers we can support
      totalMaxChildren = max 2 (availablePhpRamMb / avgProcessMb);
      
      # Distribute workers among sites
      baseChildrenPerSite = max 2 (floor (totalMaxChildren / safeSiteCount));
      
      # Adjust based on system cores
      adjustedChildrenPerSite = 
        if systemCores >= 8 then
          min (baseChildrenPerSite * 2) (floor (totalMaxChildren / safeSiteCount))
        else
          baseChildrenPerSite;
    in {
      maxChildren = if autoTune then adjustedChildrenPerSite else 10;
      startServers = max 1 (adjustedChildrenPerSite / 4);
      minSpareServers = max 1 (adjustedChildrenPerSite / 4);
      maxSpareServers = max 2 (adjustedChildrenPerSite / 2);
      inherit systemRamMb systemCores availablePhpRamMb;
    };
  
  poolSizes = calculatePoolSizes;
  
  # PHP version selection
  phpPackage = pkgs.php82.withExtensions ({ enabled, all }: enabled ++ (with all; [
    imagick
    redis
    memcached
    apcu
    opcache
    zip
    gd
    mbstring
    intl
    bcmath
    soap
    exif
  ]));
in
{
  options.services.wpbox.phpfpm = {
    enable = mkEnableOption "Managed PHP-FPM Pools for WordPress";
    
    package = mkOption {
      type = types.package;
      default = phpPackage;
      description = "PHP package with extensions";
    };
    
    monitoring = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable PHP-FPM status monitoring";
      };
      
      statusPath = mkOption {
        type = types.str;
        default = "/status";
        description = "PHP-FPM status page path";
      };
      
      pingPath = mkOption {
        type = types.str;
        default = "/ping";
        description = "PHP-FPM ping path";
      };
    };
    
    opcache = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable OPcache";
      };
      
      memory = mkOption {
        type = types.int;
        default = 128;
        description = "OPcache memory consumption in MB";
      };
      
      maxFiles = mkOption {
        type = types.int;
        default = 10000;
        description = "Maximum number of files OPcache can cache";
      };
      
      validateTimestamps = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to check file timestamps";
      };
      
      revalidateFreq = mkOption {
        type = types.int;
        default = 2;
        description = "How often to check file timestamps (seconds)";
      };
    };
    
    emergency = {
      restartThreshold = mkOption {
        type = types.int;
        default = 10;
        description = "Number of child processes to fail within interval before emergency restart";
      };
      
      restartInterval = mkOption {
        type = types.str;
        default = "1m";
        description = "Interval for counting failed children";
      };
    };
  };

  config = mkIf (config.services.wpbox.enable) {
    # Assertions
    assertions = [
      {
        assertion = poolSizes.systemRamMb > 0;
        message = "System RAM detection failed";
      }
      {
        assertion = poolSizes.maxChildren > 0;
        message = "Invalid PHP-FPM pool size calculation";
      }
    ];
    
    # Warnings
    warnings = 
      let
        totalExpectedFootprint = 
          (poolSizes.maxChildren * cfg.tuning.avgProcessSize * safeSiteCount) + 
          cfg.tuning.osRamHeadroom;
      in
      optional (poolSizes.systemRamMb > 0 && totalExpectedFootprint > poolSizes.systemRamMb)
        "WPBox PHP-FPM: Total memory usage (${toString totalExpectedFootprint}MB) may exceed system RAM (${toString poolSizes.systemRamMb}MB)";

    # PHP-FPM pools configuration
    services.phpfpm = {
      phpPackage = phpCfg.package;
      
      pools = mapAttrs' (name: siteOpts: 
        let
          # Allow custom pool config to override auto-tuning
          customPool = siteOpts.php.custom_pool or null;
          
          # Pool-specific settings
          poolSettings = if customPool != null then
            customPool
          else {
            # Process manager settings
            pm = "dynamic";
            "pm.max_children" = toString poolSizes.maxChildren;
            "pm.start_servers" = toString poolSizes.startServers;
            "pm.min_spare_servers" = toString poolSizes.minSpareServers;
            "pm.max_spare_servers" = toString poolSizes.maxSpareServers;
            "pm.max_requests" = "1000";
            "pm.process_idle_timeout" = "10s";
            "pm.max_spawn_rate" = "32";
          };
          
          # PHP ini settings for the pool
          phpIniSettings = ''
            ; Basic settings
            expose_php = Off
            allow_url_fopen = On
            allow_url_include = Off
            
            ; Error handling
            display_errors = Off
            display_startup_errors = Off
            log_errors = On
            error_log = /var/log/phpfpm/wordpress-${name}-error.log
            
            ; Resource limits
            memory_limit = ${siteOpts.php.memory_limit or cfg.defaults.phpMemoryLimit}
            upload_max_filesize = ${siteOpts.nginx.client_max_body_size or cfg.defaults.uploadMaxSize}
            post_max_size = ${siteOpts.nginx.client_max_body_size or cfg.defaults.uploadMaxSize}
            max_execution_time = ${toString (siteOpts.php.max_execution_time or cfg.defaults.maxExecutionTime)}
            max_input_time = 60
            max_input_vars = 3000
            
            ; Session
            session.cookie_httponly = On
            session.use_only_cookies = On
            session.cookie_secure = ${if config.services.wpbox.nginx.enableSSL then "On" else "Off"}
            session.cookie_samesite = Lax
            session.gc_maxlifetime = 1440
            session.gc_probability = 1
            session.gc_divisor = 100
            
            ; OPcache settings
            ${optionalString phpCfg.opcache.enable ''
              opcache.enable = 1
              opcache.enable_cli = 0
              opcache.memory_consumption = ${toString phpCfg.opcache.memory}
              opcache.interned_strings_buffer = 16
              opcache.max_accelerated_files = ${toString phpCfg.opcache.maxFiles}
              opcache.max_wasted_percentage = 5
              opcache.use_cwd = 1
              opcache.validate_timestamps = ${toString (siteOpts.php.opcache_validate_timestamps or phpCfg.opcache.validateTimestamps)};
              opcache.revalidate_freq = ${toString phpCfg.opcache.revalidateFreq}
              opcache.fast_shutdown = 1
              opcache.enable_file_override = 0
              opcache.max_file_size = 0
              opcache.consistency_checks = 0
              opcache.force_restart_timeout = 30
            ''}
            
            ; Security
            disable_functions = exec,passthru,shell_exec,system,proc_open,popen,parse_ini_file,show_source
            open_basedir = /var/lib/wordpress/${name}:/tmp:/usr/share/php:/nix/store
            
            ; Performance
            realpath_cache_size = 4M
            realpath_cache_ttl = 120
            
            ; Custom PHP settings from site config
            ${siteOpts.php.extra_ini or ""}
          '';
        in
        nameValuePair "wordpress-${name}" {
          user = "wordpress";
          group = "nginx";
          
          phpOptions = phpIniSettings;
          
          settings = poolSettings // {
            # Socket configuration
            "listen.owner" = "nginx";
            "listen.group" = "nginx";
            "listen.mode" = "0660";
            
            # Backlog
            "listen.backlog" = "512";
            
            # Logging
            "php_admin_value[error_log]" = "/var/log/phpfpm/wordpress-${name}-error.log";
            "php_admin_flag[log_errors]" = "on";
            "catch_workers_output" = "yes";
            "decorate_workers_output" = "no";
            
            # Emergency restart
            "emergency_restart_threshold" = toString phpCfg.emergency.restartThreshold;
            "emergency_restart_interval" = phpCfg.emergency.restartInterval;
            
            # Request handling
            "request_terminate_timeout" = toString ((siteOpts.php.max_execution_time or cfg.defaults.maxExecutionTime) + 30);
            "request_slowlog_timeout" = "5s";
            "slowlog" = "/var/log/phpfpm/wordpress-${name}-slow.log";
            
            # Environment variables
            "env[HOSTNAME]" = "$HOSTNAME";
            "env[PATH]" = "/usr/local/bin:/usr/bin:/bin";
            "env[TMP]" = "/tmp";
            "env[TMPDIR]" = "/tmp";
            "env[TEMP]" = "/tmp";
            
            # Status monitoring
            "pm.status_path" = phpCfg.monitoring.statusPath;
            "ping.path" = phpCfg.monitoring.pingPath;
            "ping.response" = "pong";
            
            # Process control
            "process.priority" = "-5";
            "rlimit_files" = "131072";
            "rlimit_core" = "unlimited";
          };
          
          phpEnv = {
            PATH = lib.makeBinPath [ 
              phpCfg.package 
              pkgs.coreutils
              pkgs.bash
              pkgs.gzip
              pkgs.bzip2
            ];
            WP_HOME = "/var/lib/wordpress/${name}";
          };
        }
      ) activeSites;
    };

    # System directories and files
    systemd.tmpfiles.rules = [
      "d /var/log/phpfpm 0755 root root - -"
      "d /var/cache/wordpress 0755 wordpress nginx - -"
      "d /var/run/phpfpm 0755 root root - -"
    ] ++ flatten (mapAttrsToList (name: _: [
      "f /var/log/phpfpm/wordpress-${name}-error.log 0644 wordpress nginx - -"
      "f /var/log/phpfpm/wordpress-${name}-slow.log 0644 wordpress nginx - -"
    ]) activeSites);

    # Log rotation
    services.logrotate.settings.phpfpm = {
      files = "/var/log/phpfpm/*.log";
      frequency = "daily";
      rotate = 14;
      compress = true;
      delaycompress = true;
      notifempty = true;
      missingok = true;
      create = "0644 wordpress nginx";
      postrotate = ''
        systemctl reload phpfpm-wordpress-*.service 2>/dev/null || true
      '';
    };

    # PHP-FPM pool monitoring service
    systemd.services.phpfpm-monitor = mkIf phpCfg.monitoring.enable {
      description = "PHP-FPM Pool Monitor";
      after = [ "phpfpm.target" ];
      wantedBy = [ "multi-user.target" ];
      
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeScript "phpfpm-monitor" ''
          #!${pkgs.bash}/bin/bash
          
          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          echo "   PHP-FPM Pool Status Check"
          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          
          ${concatStringsSep "\n" (mapAttrsToList (name: _: ''
            echo "Checking pool: wordpress-${name}"
            
            # Check if socket exists
            SOCKET="/run/phpfpm/wordpress-${name}.sock"
            if [ -S "$SOCKET" ]; then
              echo "  ✓ Socket exists: $SOCKET"
              
              # Try to get status (if web server is configured)
              if command -v curl >/dev/null 2>&1; then
                STATUS=$(curl -s --unix-socket "$SOCKET" \
                  -H "Host: ${name}" \
                  "http://localhost${phpCfg.monitoring.statusPath}" 2>/dev/null || echo "N/A")
                
                if [ "$STATUS" != "N/A" ]; then
                  echo "  ✓ Pool responding"
                  echo "$STATUS" | grep -E "^(pool|process manager|start time|accepted conn|listen queue|active processes|total processes)" | sed 's/^/    /'
                fi
              fi
            else
              echo "  ✗ Socket not found: $SOCKET"
            fi
            echo ""
          '') activeSites)}
          
          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        '';
      };
    };

    # Timer for monitoring
    systemd.timers.phpfpm-monitor = mkIf phpCfg.monitoring.enable {
      description = "PHP-FPM Pool Monitor Timer";
      wantedBy = [ "timers.target" ];
      
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = "30min";
        Persistent = true;
      };
    };

    # Activation script for information display
    system.activationScripts.wpbox-phpfpm-info = lib.mkAfter ''
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "   WPBox PHP-FPM Configuration"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "   System RAM:      ${toString poolSizes.systemRamMb}MB"
      echo "   System Cores:    ${toString poolSizes.systemCores}"
      echo "   Reserved RAM:    ${toString cfg.tuning.osRamHeadroom}MB"
      echo "   Available RAM:   ${toString poolSizes.availablePhpRamMb}MB"
      echo ""
      echo "   Active Sites:    ${toString numberOfSites}"
      echo "   Workers/Site:    ${toString poolSizes.maxChildren}"
      echo "   Total Workers:   ${toString (poolSizes.maxChildren * safeSiteCount)}"
      echo ""
      echo "   OPcache:         ${if phpCfg.opcache.enable then "✓ ENABLED (${toString phpCfg.opcache.memory}MB)" else "✗ DISABLED"}"
      echo "   Monitoring:      ${if phpCfg.monitoring.enable then "✓ ENABLED" else "✗ DISABLED"}"
      echo "   Auto-Tuning:     ${if cfg.tuning.enableAuto then "✓ ENABLED" else "✗ DISABLED"}"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    '';
  };
}
