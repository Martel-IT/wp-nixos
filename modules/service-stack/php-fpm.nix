{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.wpbox.wordpress;
  phpCfg = config.services.wpbox.phpfpm;
  hwCfg = config.services.wpbox.hardware;  # Changed from config.hardware
  
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
  
  # Calculate pool sizes based on available resources
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
      baseChildrenPerSite = max 2 (builtins.floor (totalMaxChildren / safeSiteCount));
      
      # Adjust based on system cores and RAM
      adjustedChildrenPerSite = 
        if systemRamMb <= 4096 then
          # Small VPS: conservative settings
          min 5 baseChildrenPerSite
        else if systemRamMb <= 8192 then
          # Medium VPS: moderate settings
          min 10 baseChildrenPerSite
        else if systemCores >= 8 then
          # Large server: can handle more
          min (baseChildrenPerSite * 2) (builtins.floor (totalMaxChildren / safeSiteCount))
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
  
  # Build the complete disable_functions list from config
  disableFunctionsList = concatStringsSep "," phpCfg.security.disableFunctions;

in {
  
  config = mkIf (config.services.wpbox.enable && phpCfg.enable) {
    
    # Assertions for validation
    assertions = [
      {
        assertion = poolSizes.systemRamMb > 0;
        message = "System RAM detection failed";
      }
      {
        assertion = poolSizes.maxChildren > 0;
        message = "Invalid PHP-FPM pool size calculation";
      }
      {
        assertion = numberOfSites > 0 -> activeSites != {};
        message = "No active sites found despite sites being configured";
      }
    ];
    
    # Warnings for potential issues
    warnings = 
      let
        totalExpectedFootprint = 
          (poolSizes.maxChildren * cfg.tuning.avgProcessSize * safeSiteCount) + 
          cfg.tuning.osRamHeadroom;
      in
      optional (poolSizes.systemRamMb > 0 && totalExpectedFootprint > poolSizes.systemRamMb)
        "WPBox PHP-FPM: Total memory usage (${toString totalExpectedFootprint}MB) may exceed system RAM (${toString poolSizes.systemRamMb}MB). Consider reducing workers or sites."
      ++
      optional (poolSizes.systemRamMb <= 4096 && numberOfSites > 3)
        "WPBox PHP-FPM: Running ${toString numberOfSites} sites on ${toString poolSizes.systemRamMb}MB RAM may cause performance issues."
      ++
      optional (phpCfg.opcache.jit != "off" && poolSizes.systemRamMb <= 4096)
        "WPBox PHP-FPM: JIT is enabled on a low-memory system. Consider disabling to save RAM.";

    # PHP-FPM service configuration
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
            ; ==================================
            ; WPBox Optimized PHP Configuration
            ; ==================================
            
            ; --- Basic Settings ---
            engine = On
            short_open_tag = Off
            precision = 14
            output_buffering = 4096
            implicit_flush = Off
            serialize_precision = -1
            zend.enable_gc = On
            expose_php = Off
            
            ; --- Resource Limits ---
            max_execution_time = ${toString (siteOpts.php.max_execution_time or cfg.defaults.maxExecutionTime)}
            max_input_time = 60
            max_input_vars = 3000
            max_input_nesting_level = 64
            memory_limit = ${siteOpts.php.memory_limit or cfg.defaults.phpMemoryLimit}
            
            ; --- Error Handling ---
            error_reporting = E_ALL & ~E_DEPRECATED & ~E_STRICT
            display_errors = Off
            display_startup_errors = Off
            log_errors = On
            error_log = /var/log/phpfpm/wordpress-${name}-error.log
            log_errors_max_len = 1024
            ignore_repeated_errors = Off
            ignore_repeated_source = Off
            report_memleaks = On
            track_errors = Off
            xmlrpc_errors = Off
            
            ; --- File Uploads ---
            file_uploads = On
            upload_tmp_dir = /tmp
            upload_max_filesize = ${siteOpts.nginx.client_max_body_size or cfg.defaults.uploadMaxSize}
            max_file_uploads = 20
            
            ; --- POST Settings ---
            post_max_size = ${siteOpts.nginx.client_max_body_size or cfg.defaults.uploadMaxSize}
            always_populate_raw_post_data = -1
            
            ; --- Paths and Directories ---
            include_path = ".:/usr/share/php:/usr/share/pear"
            doc_root = /var/lib/wordpress/${name}
            user_dir =
            extension_dir = "${phpCfg.package}/lib/php/extensions/"
            enable_dl = Off
            
            ; --- File System ---
            realpath_cache_size = 4M
            realpath_cache_ttl = 120
            
            ; --- URL Settings ---
            allow_url_fopen = On
            allow_url_include = Off
            default_socket_timeout = 60
            
            ; --- Security Settings ---
            open_basedir = /var/lib/wordpress/${name}:/tmp:/usr/share/php:/nix/store
            disable_functions = ${disableFunctionsList}
            disable_classes =
            
            ; --- Session Settings ---
            session.save_handler = files
            session.save_path = "/tmp"
            session.use_strict_mode = 1
            session.use_cookies = 1
            session.use_only_cookies = 1
            session.name = PHPSESSID
            session.auto_start = 0
            session.cookie_lifetime = 0
            session.cookie_path = /
            session.cookie_domain =
            session.cookie_httponly = On
            session.cookie_secure = ${if config.services.wpbox.nginx.enableSSL then "On" else "Off"}
            session.cookie_samesite = Strict
            session.serialize_handler = php
            session.gc_probability = 1
            session.gc_divisor = 100
            session.gc_maxlifetime = 1440
            session.referer_check =
            session.cache_limiter = nocache
            session.cache_expire = 180
            session.use_trans_sid = 0
            session.sid_length = 48
            session.sid_bits_per_character = 6
            session.lazy_write = On
            
            ; --- OPcache Settings ---
            ${optionalString phpCfg.opcache.enable ''
              opcache.enable = 1
              opcache.enable_cli = 0
              opcache.memory_consumption = ${toString phpCfg.opcache.memory}
              opcache.interned_strings_buffer = 16
              opcache.max_accelerated_files = ${toString phpCfg.opcache.maxFiles}
              opcache.max_wasted_percentage = 5
              opcache.use_cwd = 1
              opcache.validate_timestamps = ${if (siteOpts.php.opcache_validate_timestamps or phpCfg.opcache.validateTimestamps) then "1" else "0"}
              opcache.revalidate_freq = ${toString phpCfg.opcache.revalidateFreq}
              opcache.revalidate_path = 0
              opcache.save_comments = 1
              opcache.enable_file_override = 0
              opcache.optimization_level = 0x7FFFBFFF
              opcache.dups_fix = 0
              opcache.blacklist_filename =
              opcache.max_file_size = 0
              opcache.consistency_checks = 0
              opcache.force_restart_timeout = 30
              opcache.error_log = /var/log/phpfpm/opcache-${name}.log
              opcache.log_verbosity_level = 1
              opcache.preferred_memory_model =
              opcache.protect_memory = 0
              opcache.restrict_api =
              opcache.file_cache =
              opcache.file_cache_only = 0
              opcache.file_cache_consistency_checks = 1
              opcache.file_update_protection = 2
              opcache.opt_debug_level = 0
              opcache.preload =
              opcache.preload_user =
              opcache.lockfile_path = /tmp
              opcache.huge_code_pages = 0
              
              ; JIT Settings (PHP 8+)
              ${optionalString (phpCfg.opcache.jit != "off") ''
                opcache.jit = ${phpCfg.opcache.jit}
                opcache.jit_buffer_size = ${phpCfg.opcache.jitBufferSize}
                opcache.jit_blacklist_root_trace = 16
                opcache.jit_blacklist_side_trace = 8
                opcache.jit_debug = 0
                opcache.jit_hot_func = 127
                opcache.jit_hot_loop = 64
                opcache.jit_hot_return = 8
                opcache.jit_hot_side_exit = 8
                opcache.jit_max_exit_counters = 8192
                opcache.jit_max_loop_unrolls = 8
                opcache.jit_max_polymorphic_calls = 2
                opcache.jit_max_recursive_calls = 2
                opcache.jit_max_recursive_returns = 2
                opcache.jit_max_root_traces = 1024
                opcache.jit_max_side_traces = 128
                opcache.jit_prof_threshold = 0.005
              ''}
            ''}
            
            ; --- Custom PHP Settings from Site Config ---
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
            "listen.allowed_clients" = "127.0.0.1";
            
            # Logging
            "php_admin_value[error_log]" = "/var/log/phpfpm/wordpress-${name}-error.log";
            "php_admin_flag[log_errors]" = "on";
            "catch_workers_output" = "yes";
            "decorate_workers_output" = "no";
            "clear_env" = "no";
            
            # Emergency restart
            "emergency_restart_threshold" = toString phpCfg.emergency.restartThreshold;
            "emergency_restart_interval" = phpCfg.emergency.restartInterval;
            "process_control_timeout" = "10s";
            
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
            "pm.status_listen" = "127.0.0.1:9000";
            "ping.path" = phpCfg.monitoring.pingPath;
            "ping.response" = "pong";
            "access.log" = mkIf phpCfg.monitoring.enable "/var/log/phpfpm/wordpress-${name}-access.log";
            "access.format" = mkIf phpCfg.monitoring.enable "%R - %u %t \"%m %r\" %s";
            
            # Process control
            "process.priority" = "-5";
            "rlimit_files" = "131072";
            "rlimit_core" = "unlimited";
            
            # Security
            "security.limit_extensions" = ".php .phtml";
          };
          
          phpEnv = {
            PATH = lib.makeBinPath [ 
              phpCfg.package 
              pkgs.coreutils
              pkgs.bash
              pkgs.gzip
              pkgs.bzip2
              pkgs.findutils
            ];
            WP_HOME = "/var/lib/wordpress/${name}";
            WP_DEBUG = if (siteOpts.wordpress.debug or false) then "true" else "false";
            WP_CACHE = "true";
            WP_MEMORY_LIMIT = siteOpts.php.memory_limit or cfg.defaults.phpMemoryLimit;
          };
        }
      ) activeSites;
    };

    # System directories and files
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
        # Signal all PHP-FPM pools to reopen log files
        for pool in /run/phpfpm/*.sock; do
          if [ -S "$pool" ]; then
            poolname=$(basename "$pool" .sock)
            systemctl reload phpfpm-$poolname.service 2>/dev/null || true
          fi
        done
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
          echo ""
          echo "System Resources:"
          echo "  RAM: ${toString poolSizes.systemRamMb}MB (${toString poolSizes.availablePhpRamMb}MB available for PHP)"
          echo "  CPU Cores: ${toString poolSizes.systemCores}"
          echo "  Sites: ${toString numberOfSites}"
          echo "  Workers per site: ${toString poolSizes.maxChildren}"
          echo ""
          
          ${concatStringsSep "\n" (mapAttrsToList (name: _: ''
            echo "Checking pool: wordpress-${name}"
            
            # Check if socket exists
            SOCKET="/run/phpfpm/wordpress-${name}.sock"
            if [ -S "$SOCKET" ]; then
              echo "  ✓ Socket exists: $SOCKET"
              
              # Get pool status via curl (if accessible)
              if command -v curl >/dev/null 2>&1; then
                STATUS=$(curl -s --unix-socket "$SOCKET" \
                  -H "Host: ${name}" \
                  "http://localhost${phpCfg.monitoring.statusPath}" 2>/dev/null || echo "N/A")
                
                if [ "$STATUS" != "N/A" ] && [ -n "$STATUS" ]; then
                  echo "  ✓ Pool responding"
                  echo "$STATUS" | grep -E "^(pool|process manager|start time|accepted conn|listen queue|active processes|total processes)" | sed 's/^/    /'
                  
                  # Check slow log
                  SLOW_LOG="/var/log/phpfpm/wordpress-${name}-slow.log"
                  if [ -f "$SLOW_LOG" ]; then
                    SLOW_COUNT=$(wc -l < "$SLOW_LOG" 2>/dev/null || echo 0)
                    if [ "$SLOW_COUNT" -gt 0 ]; then
                      echo "  ⚠ Slow requests logged: $SLOW_COUNT"
                    fi
                  fi
                else
                  echo "  ⚠ Pool not responding to status request"
                fi
              fi
            else
              echo "  ✗ Socket not found: $SOCKET"
            fi
            echo ""
          '') activeSites)}
          
          # Check OPcache status
          ${optionalString phpCfg.opcache.enable ''
            echo "OPcache Status:"
            echo "  Memory: ${toString phpCfg.opcache.memory}MB"
            echo "  Max Files: ${toString phpCfg.opcache.maxFiles}"
            echo "  JIT: ${phpCfg.opcache.jit}"
            ${optionalString (phpCfg.opcache.jit != "off") ''
              echo "  JIT Buffer: ${phpCfg.opcache.jitBufferSize}"
            ''}
            echo ""
          ''}
          
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

    # Health check service
    systemd.services.phpfpm-health = {
      description = "PHP-FPM Health Check";
      after = [ "phpfpm.target" ];
      
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeScript "phpfpm-health" ''
          #!${pkgs.bash}/bin/bash
          
          UNHEALTHY=0
          
          ${concatStringsSep "\n" (mapAttrsToList (name: _: ''
            # Check pool wordpress-${name}
            SOCKET="/run/phpfpm/wordpress-${name}.sock"
            if [ -S "$SOCKET" ]; then
              # Try to ping the pool
              RESPONSE=$(echo "GET ${phpCfg.monitoring.pingPath} HTTP/1.0\r\nHost: ${name}\r\n\r\n" | \
                ${pkgs.netcat}/bin/nc -U "$SOCKET" -w 2 2>/dev/null | grep -o "pong" || true)
              
              if [ "$RESPONSE" != "pong" ]; then
                echo "WARNING: Pool wordpress-${name} is not responding" | systemd-cat -p warning -t phpfpm-health
                UNHEALTHY=$((UNHEALTHY + 1))
              fi
            else
              echo "ERROR: Socket for wordpress-${name} does not exist" | systemd-cat -p err -t phpfpm-health
              UNHEALTHY=$((UNHEALTHY + 1))
            fi
          '') activeSites)}
          
          if [ $UNHEALTHY -gt 0 ]; then
            echo "ERROR: $UNHEALTHY pool(s) are unhealthy" | systemd-cat -p err -t phpfpm-health
            exit 1
          else
            echo "All PHP-FPM pools are healthy" | systemd-cat -p info -t phpfpm-health
          fi
        '';
      };
    };

    # Health check timer
    systemd.timers.phpfpm-health = {
      description = "PHP-FPM Health Check Timer";
      wantedBy = [ "timers.target" ];
      
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "5min";
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
      ${optionalString (phpCfg.opcache.jit != "off") ''
      echo "   JIT:             ✓ ${phpCfg.opcache.jit} (${phpCfg.opcache.jitBufferSize})"
      ''}
      echo "   Monitoring:      ${if phpCfg.monitoring.enable then "✓ ENABLED" else "✗ DISABLED"}"
      echo "   Auto-Tuning:     ${if cfg.tuning.enableAuto then "✓ ENABLED" else "✗ DISABLED"}"
      echo ""
      echo "   Security:"
      echo "     Functions disabled: ${toString (length phpCfg.security.disableFunctions)}"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    '';
  };
}
