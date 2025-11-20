{ config, pkgs, lib, ... }:

with lib;

let 
  cfg = config.services.wpbox.redis;
  hwCfg = config.services.wpbox.hardware;
  wpCfg = config.services.wpbox.wordpress;

  calculateRedisSettings = 
    let
      # Direct access to hardware config
      systemRamMb = hwCfg.ramMb;
      
      # Redis lives in the reserve
      reservedRamMb = wpCfg.tuning.osRamHeadroom or 2048;
      osOverheadMb = 1024;
      availableInReserveMb = lib.max 512 (reservedRamMb - osOverheadMb);
      
      # 20% of reserve space to Redis
      calculatedMaxMemoryMb = builtins.floor(availableInReserveMb * 0.20);
      
      minMemoryMb = cfg.autoTune.minMemoryMb;
      maxMemoryMb = cfg.autoTune.maxMemoryMb;
      finalMaxMemoryMb = lib.max minMemoryMb (lib.min maxMemoryMb calculatedMaxMemoryMb);
    in {
      maxmemory = "${toString finalMaxMemoryMb}mb";
      inherit systemRamMb finalMaxMemoryMb;
    };
  
  redisSettings = calculateRedisSettings;

in {
  config = mkIf (config.services.wpbox.enable && cfg.enable) {
    
    warnings = 
      optional (redisSettings.finalMaxMemoryMb < 64)
        "WPBox Redis: Memory allocation is critically low (${toString redisSettings.finalMaxMemoryMb}MB)."
      ++
      optional (!cfg.persistence.enable)
        "WPBox Redis: Persistence is disabled. Data loss on restart is expected.";

    users.users.redis = {
      isSystemUser = true;
      group = "redis";
      description = "Redis database user";
    };

    users.groups.redis = {};

    services.redis = {
      package = cfg.package;
      
      servers.wpbox = { 
        enable = true;
        bind = cfg.bind;
        port = cfg.port;
        unixSocket = cfg.unixSocket;
        unixSocketPerm = cfg.unixSocketPerm;
        
        settings = {
          maxmemory = if cfg.autoTune.enable then redisSettings.maxmemory else "256mb";
          maxmemory-policy = cfg.maxmemoryPolicy;
          maxmemory-samples = 5;
          
          tcp-keepalive = 300;
          timeout = 300;
          
          save = if cfg.persistence.enable then [ "900 1" "300 10" "60 10000" ] else [ ];
          stop-writes-on-bgsave-error = cfg.persistence.enable;
          rdbcompression = cfg.persistence.enable;
          rdbchecksum = cfg.persistence.enable;
          appendonly = cfg.persistence.enable;
          
          lazyfree-lazy-eviction = true;
          lazyfree-lazy-expire = true;
          lazyfree-lazy-server-del = true;
          replica-lazy-flush = true;
          lazyfree-lazy-user-del = true;
          
          databases = 16;
          loglevel = "notice";
          syslog-enabled = true;
          syslog-ident = "redis-wpbox";
          syslog-facility = "local0";
          
          protected-mode = true;
          rename-command = [
            "FLUSHDB \"\""
            "FLUSHALL \"\""
            "KEYS \"\""
            "CONFIG \"\""
            "SHUTDOWN \"\""
            "BGREWRITEAOF \"\""
            "BGSAVE \"\""
            "SAVE \"\""
            "DEBUG \"\""
          ];
        };
      };
    };
    
    systemd.tmpfiles.rules = [
      "d /var/lib/redis-wpbox 0750 redis redis - -"
      "d /run/redis-wpbox 0750 redis redis - -"
      "d /var/log/redis 0755 redis redis - -"
    ];

    systemd.services.redis-wpbox-monitor = mkIf cfg.monitoring.enable {
      description = "Redis WPBox Monitoring";
      after = [ "redis-wpbox.service" ];
      requires = [ "redis-wpbox.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = "redis";
        Group = "redis";
        ExecStart = pkgs.writeScript "redis-monitor" ''
          #!${pkgs.bash}/bin/bash
          echo "--- Redis WPBox Status ---"
          ${if cfg.unixSocket != null then
            ''REDIS_CLI="${pkgs.redis}/bin/redis-cli -s ${cfg.unixSocket}"''
          else
            ''REDIS_CLI="${pkgs.redis}/bin/redis-cli -h ${cfg.bind} -p ${toString cfg.port}"''
          }
          if $REDIS_CLI ping >/dev/null 2>&1; then
            echo "Redis is UP"
            $REDIS_CLI INFO memory | grep human
          else
            echo "Redis is DOWN"
          fi
        '';
      };
    };
    
    systemd.timers.redis-wpbox-monitor = mkIf cfg.monitoring.enable {
      description = "Redis WPBox Monitor Timer";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = "1h";
        Persistent = true;
      };
    };
    
    system.activationScripts.wpbox-redis-info = lib.mkIf cfg.autoTune.enable (lib.mkAfter ''
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "   WPBox Redis Build-Time Configuration"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "   Configured RAM:     ${toString redisSettings.systemRamMb}MB"
      echo "   Redis Memory:       ${toString redisSettings.finalMaxMemoryMb}MB"
      echo "   Persistence:        ${if cfg.persistence.enable then "✓ ENABLED" else "✗ DISABLED"}"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    '');
  };
}