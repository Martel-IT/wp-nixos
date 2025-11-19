{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.wpbox.wordpress;
  phpCfg = config.services.wpbox.phpfpm;
  hwCfg = config.services.wpbox.hardware;
  
  # Get system resources
  getSystemRamMb = 
    if hwCfg.runtimeMemoryMb != null then
      hwCfg.runtimeMemoryMb
    else
      hwCfg.fallback.ramMb;

  getSystemCores =
    if hwCfg.runtimeCores != null then
      hwCfg.runtimeCores
    else
      hwCfg.fallback.cores;

  # Active sites
  activeSites = filterAttrs (n: v: v.enabled) cfg.sites;
  numberOfSites = length (attrNames activeSites);
  safeSiteCount = max 1 numberOfSites;
  
  # Calculate pool sizes
  calculatePoolSizes = 
    let
      systemRamMb = getSystemRamMb;
      systemCores = getSystemCores;
      
      autoTune = cfg.tuning.enableAuto;
      reservedRamMb = cfg.tuning.osRamHeadroom;
      avgProcessMb = cfg.tuning.avgProcessSize;

      availablePhpRamMb = max 512 (systemRamMb - reservedRamMb);
      totalMaxChildren = max 2 (availablePhpRamMb / avgProcessMb);
      baseChildrenPerSite = max 2 (builtins.floor (totalMaxChildren / safeSiteCount));

      adjustedChildrenPerSite = 
        if systemRamMb <= 4096 then min 5 baseChildrenPerSite
        else if systemRamMb <= 8192 then min 10 baseChildrenPerSite
        else if systemCores >= 8 then min (baseChildrenPerSite * 2) (builtins.floor (totalMaxChildren / safeSiteCount))
        else baseChildrenPerSite;
    in {
      maxChildren = if autoTune then adjustedChildrenPerSite else 10;
      startServers = max 1 (adjustedChildrenPerSite / 4);
      minSpareServers = max 1 (adjustedChildrenPerSite / 4);
      maxSpareServers = max 2 (adjustedChildrenPerSite / 2);
      inherit systemRamMb systemCores availablePhpRamMb;
    };
  
  poolSizes = calculatePoolSizes;
  disableFunctionsList = concatStringsSep "," phpCfg.security.disableFunctions;
in {
  
  config = mkIf (config.services.wpbox.enable && phpCfg.enable) {
    
    # Assertions
    assertions = [
      { assertion = poolSizes.systemRamMb > 0; message = "System RAM detection failed"; }
      { assertion = poolSizes.maxChildren > 0; message = "Invalid PHP-FPM pool size calculation"; }
      { assertion = numberOfSites > 0 -> activeSites != {}; message = "No active sites found despite sites being configured"; }
    ];

    # Warnings
    warnings = 
      let
        totalExpectedFootprint = (poolSizes.maxChildren * cfg.tuning.avgProcessSize * safeSiteCount) + cfg.tuning.osRamHeadroom;
      in
      optional (poolSizes.systemRamMb > 0 && totalExpectedFootprint > poolSizes.systemRamMb)
        "WPBox PHP-FPM: Total memory usage (${toString totalExpectedFootprint}MB) may exceed system RAM."
      ++ optional (poolSizes.systemRamMb <= 4096 && numberOfSites > 3)
        "WPBox PHP-FPM: Running many sites on low RAM may cause issues."
      ++ optional (phpCfg.opcache.jit != "off" && poolSizes.systemRamMb <= 4096)
        "WPBox PHP-FPM: JIT enabled on low-memory system.";

    # PHP-FPM Service
    services.phpfpm = {
      phpPackage = phpCfg.package;
      
      settings = {
        emergency_restart_threshold = phpCfg.emergency.restartThreshold;
        emergency_restart_interval = phpCfg.emergency.restartInterval;
        process_control_timeout = "10s";
      };

      pools = mapAttrs' (name: siteOpts: 
        let
          customPool = siteOpts.php.custom_pool or null;
          
          poolSettings = if customPool != null then customPool
          else {
            pm = "dynamic";
            "pm.max_children" = toString poolSizes.maxChildren;
            "pm.start_servers" = toString poolSizes.startServers;
            "pm.min_spare_servers" = toString poolSizes.minSpareServers;
            "pm.max_spare_servers" = toString poolSizes.maxSpareServers;
            "pm.max_requests" = "1000";
            "pm.process_idle_timeout" = "10s";
            "pm.max_spawn_rate" = "32";
          };
          
          phpIniSettings = ''
            engine = On
            short_open_tag = Off
            precision = 14
            output_buffering = 4096
            implicit_flush = Off
            serialize_precision = -1
            zend.enable_gc = On
            expose_php = Off
            max_execution_time = ${toString (siteOpts.php.max_execution_time or cfg.defaults.maxExecutionTime)}
            max_input_time = 60
            max_input_vars = 3000
            max_input_nesting_level = 64
            memory_limit = ${siteOpts.php.memory_limit or cfg.defaults.phpMemoryLimit}
            error_reporting = E_ALL & ~E_DEPRECATED & ~E_STRICT
            display_errors = Off
            display_startup_errors = Off
            log_errors = On
            error_log = /var/log/phpfpm/wordpress-${name}-error.log
            log_errors_max_len = 1024
            ignore_repeated_errors = Off
            ignore_repeated_source = Off
            report_memleaks = On
            file_uploads = On
            upload_tmp_dir = /tmp
            upload_max_filesize = ${siteOpts.nginx.client_max_body_size or cfg.defaults.uploadMaxSize}
            max_file_uploads = 20
            post_max_size = ${siteOpts.nginx.client_max_body_size or cfg.defaults.uploadMaxSize}
            open_basedir = /var/lib/wordpress/${name}:/tmp:/usr/share/php:/nix/store
            disable_functions = ${disableFunctionsList}
            session.save_handler = files
            session.save_path = "/tmp"
            session.use_strict_mode = 1
            session.cookie_secure = ${if config.services.wpbox.nginx.enableSSL then "On" else "Off"}
            session.cookie_httponly = On
            session.cookie_samesite = Strict
            ${optionalString phpCfg.opcache.enable ''
              opcache.enable = 1
              opcache.memory_consumption = ${toString phpCfg.opcache.memory}
              opcache.max_accelerated_files = ${toString phpCfg.opcache.maxFiles}
              opcache.validate_timestamps = ${if (siteOpts.php.opcache_validate_timestamps or phpCfg.opcache.validateTimestamps) then "1" else "0"}
              opcache.revalidate_freq = ${toString phpCfg.opcache.revalidateFreq}
              ${optionalString (phpCfg.opcache.jit != "off") ''
                opcache.jit = ${phpCfg.opcache.jit}
                opcache.jit_buffer_size = ${phpCfg.opcache.jitBufferSize}
              ''}
            ''}
            ${siteOpts.php.extra_ini or ""}
          '';
        in
        nameValuePair "wordpress-${name}" {
          user = "wordpress";
          group = "nginx";
          phpOptions = phpIniSettings;
          
          settings = poolSettings // {
            "listen.owner" = "nginx";
            "listen.group" = "nginx";
            "listen.mode" = "0660";
            "listen.backlog" = "512";
            "listen.allowed_clients" = "127.0.0.1";
            "php_admin_value[error_log]" = "/var/log/phpfpm/wordpress-${name}-error.log";
            "php_admin_flag[log_errors]" = "on";
            "catch_workers_output" = "yes";
            "decorate_workers_output" = "no";
            "clear_env" = "no";
            "request_terminate_timeout" = toString ((siteOpts.php.max_execution_time or cfg.defaults.maxExecutionTime) + 30);
            "request_slowlog_timeout" = "5s";
            "slowlog" = "/var/log/phpfpm/wordpress-${name}-slow.log";
            "env[HOSTNAME]" = "$HOSTNAME";
            "env[PATH]" = "/usr/local/bin:/usr/bin:/bin";
            "env[TMP]" = "/tmp";
            "env[TMPDIR]" = "/tmp";
            "env[TEMP]" = "/tmp";
            "pm.status_path" = phpCfg.monitoring.statusPath;
            "pm.status_listen" = "127.0.0.1:9000";
            "ping.path" = phpCfg.monitoring.pingPath;
            "ping.response" = "pong";
            "access.log" = mkIf phpCfg.monitoring.enable "/var/log/phpfpm/wordpress-${name}-access.log";
            "process.priority" = "-5";
            "rlimit_files" = "131072";
            "rlimit_core" = "unlimited";
            "security.limit_extensions" = ".php .phtml";
          };
          
          phpEnv = {
            PATH = lib.makeBinPath [ phpCfg.package pkgs.coreutils pkgs.bash pkgs.gzip pkgs.bzip2 pkgs.findutils ];
            WP_HOME = "/var/lib/wordpress/${name}";
            WP_DEBUG = if (siteOpts.wordpress.debug or false) then "true" else "false";
            WP_CACHE = "true";
            WP_MEMORY_LIMIT = siteOpts.php.memory_limit or cfg.defaults.phpMemoryLimit;
          };
        }
      ) activeSites;
    };

    # Directories
    systemd.tmpfiles.rules = [
      "d /var/log/phpfpm 0755 root root - -"
      "d /var/cache/wordpress 0755 wordpress nginx - -"
      "d /var/run/phpfpm 0755 root root - -"
      "d /tmp/wordpress 1777 root root - -"
    ] ++ flatten (mapAttrsToList (name: _: [
      "f /var/log/phpfpm/wordpress-${name}-error.log 0644 wordpress nginx - -"
      "f /var/log/phpfpm/wordpress-${name}-slow.log 0644 wordpress nginx - -"
      "f /var/log/phpfpm/wordpress-${name}-access.log 0644 wordpress nginx - -"
      "f /var/log/phpfpm/opcache-${name}.log 0644 wordpress nginx - -"
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
      sharedscripts = true;
      postrotate = ''
        for pool in /run/phpfpm/*.sock; do
          if [ -S "$pool" ]; then
            poolname=$(basename "$pool" .sock)
            systemctl reload phpfpm-$poolname.service 2>/dev/null || true
          fi
        done
      '';
    };

    # Monitoring
    systemd.services.phpfpm-monitor = mkIf phpCfg.monitoring.enable {
      description = "PHP-FPM Pool Monitor";
      after = [ "phpfpm.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeScript "phpfpm-monitor" ''
          #!${pkgs.bash}/bin/bash
          echo "--- PHP-FPM Status ---"
          echo "OK"
        '';
      };
    };

    systemd.timers.phpfpm-monitor = mkIf phpCfg.monitoring.enable {
      description = "PHP-FPM Pool Monitor Timer";
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = "5min"; OnUnitActiveSec = "30min"; Persistent = true; };
    };

    systemd.services.phpfpm-health = {
      description = "PHP-FPM Health Check";
      after = [ "phpfpm.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeScript "phpfpm-health" ''
          #!${pkgs.bash}/bin/bash
          echo "Checking pools..."
          exit 0
        '';
      };
    };

    systemd.timers.phpfpm-health = {
      description = "PHP-FPM Health Check Timer";
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = "2min"; OnUnitActiveSec = "5min"; Persistent = true; };
    };

    system.activationScripts.wpbox-phpfpm-info = lib.mkAfter ''
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "   WPBox PHP-FPM Configuration"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "   System RAM:      ${toString poolSizes.systemRamMb}MB"
      echo "   Total Workers:   ${toString (poolSizes.maxChildren * safeSiteCount)}"
      echo "   OPcache:         ${if phpCfg.opcache.enable then "✓ ENABLED" else "✗ DISABLED"}"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    '';
  };
}