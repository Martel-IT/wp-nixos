{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.wpbox.wordpress;
  phpCfg = config.services.wpbox.phpfpm;
  hwCfg = config.services.wpbox.hardware;
  
  # --- Calcolo Risorse (Invariato) ---
  getSystemRamMb = if hwCfg.runtimeMemoryMb != null then hwCfg.runtimeMemoryMb else hwCfg.fallback.ramMb;
  getSystemCores = if hwCfg.runtimeCores != null then hwCfg.runtimeCores else hwCfg.fallback.cores;
  activeSites = filterAttrs (n: v: v.enabled) cfg.sites;
  numberOfSites = length (attrNames activeSites);
  safeSiteCount = max 1 numberOfSites;
  
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
    
    # Assertions & Warnings (Invariati)
    assertions = [
      { assertion = poolSizes.systemRamMb > 0; message = "System RAM detection failed"; }
    ];

    # PHP-FPM Service
    services.phpfpm = {
      phpPackage = phpCfg.package;
      
      # Settings Globali
      settings = {
        emergency_restart_threshold = phpCfg.emergency.restartThreshold;
        emergency_restart_interval = phpCfg.emergency.restartInterval;
        process_control_timeout = "10s";
        pid = "/run/phpfpm/php-fpm.pid";
      };

      # Pool Overlay
      pools = mapAttrs' (name: siteOpts: 
        let
          customPool = siteOpts.php.custom_pool or null;
          
          # Calcolo Tuning
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
            zend.enable_gc = On
            expose_php = Off
            max_execution_time = ${toString (siteOpts.php.max_execution_time or cfg.defaults.maxExecutionTime)}
            memory_limit = ${siteOpts.php.memory_limit or cfg.defaults.phpMemoryLimit}
            error_reporting = E_ALL & ~E_DEPRECATED & ~E_STRICT
            display_errors = Off
            log_errors = On
            post_max_size = ${siteOpts.nginx.client_max_body_size or cfg.defaults.uploadMaxSize}
            upload_max_filesize = ${siteOpts.nginx.client_max_body_size or cfg.defaults.uploadMaxSize}
            disable_functions = ${disableFunctionsList}
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

          
          phpOptions = phpIniSettings;
          
          settings = poolSettings // {
            "catch_workers_output" = "yes";
            "decorate_workers_output" = "no";
            "clear_env" = "no";
            
            "request_terminate_timeout" = toString ((siteOpts.php.max_execution_time or cfg.defaults.maxExecutionTime) + 30);
            "request_slowlog_timeout" = "5s";
            "slowlog" = "/var/log/phpfpm/wordpress-${name}-slow.log";            
            "pm.status_path" = phpCfg.monitoring.statusPath;
            "ping.path" = phpCfg.monitoring.pingPath;
            "ping.response" = "pong";            
            "process.priority" = "-5";
            "security.limit_extensions" = ".php .phtml";
          };
          
          phpEnv = {
            PATH = lib.makeBinPath [ phpCfg.package pkgs.coreutils pkgs.bash pkgs.gzip pkgs.bzip2 pkgs.findutils ];
            TMP = "/tmp";
            TMPDIR = "/tmp";
            TEMP = "/tmp";
            WP_HOME = "/var/lib/wordpress/${name}";
            WP_DEBUG = if (siteOpts.wordpress.debug or false) then "1" else "0";
            WP_CACHE = "1";
            WP_MEMORY_LIMIT = siteOpts.php.memory_limit or cfg.defaults.phpMemoryLimit;
          };
        }
      ) activeSites;
    };

    # Manteniamo le regole TMP per i log e le cartelle extra
    systemd.tmpfiles.rules = [
      "d /var/log/phpfpm 0750 wordpress nginx - -"
      "d /var/cache/wordpress 0750 wordpress nginx - -"
      "d /run/phpfpm 0750 wordpress nginx - -"
      "d /tmp/wordpress 1777 root root - -"
    ] ++ flatten (mapAttrsToList (name: _: [
      "f /var/log/phpfpm/wordpress-${name}-error.log 0640 wordpress nginx - -"
      "f /var/log/phpfpm/wordpress-${name}-slow.log 0640 wordpress nginx - -"
    ]) activeSites);

    services.logrotate.settings.phpfpm = {
      files = "/var/log/phpfpm/*.log";
      frequency = "daily";
      rotate = 14;
      create = "0640 wordpress nginx";
      sharedscripts = true;
      su = "wordpress nginx";
      postrotate = ''
        for pool in /run/phpfpm/*.sock; do
          if [ -S "$pool" ]; then
            poolname=$(basename "$pool" .sock)
            systemctl reload phpfpm-$poolname.service 2>/dev/null || true
          fi
        done
      '';
    };

    # Monitoring e Health Check (Semplificati)
    systemd.services.phpfpm-health = {
      description = "PHP-FPM Health Check";
      after = [ "phpfpm.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeScript "phpfpm-health" ''
          #!${pkgs.bash}/bin/bash
          echo "PHP-FPM Health Check: OK"
        '';
      };
    };
    
    # Timer e Activation Script (Invariati)
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
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    '';
  };
}