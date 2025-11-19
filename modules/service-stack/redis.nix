{ config, pkgs, lib, ... }:

with lib;

let 
  cfg = config.services.wpbox.redis;
  hwCfg = config.services.wpbox.hardware;
  wpCfg = config.services.wpbox.wordpress;

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

  # Calculate optimal Redis settings
  calculateRedisSettings = 
    let
      systemRamMb = getSystemRamMb;
      systemCores = getSystemCores;
      
      reservedRamMb = wpCfg.tuning.osRamHeadroom or 2048;
      availableForCache = lib.max 128 (systemRamMb - reservedRamMb);
      
      redisMemoryRatio = cfg.autoTune.memoryAllocationRatio;
      calculatedMaxMemoryMb = builtins.floor(availableForCache * redisMemoryRatio);
      
      minMemoryMb = cfg.autoTune.minMemoryMb;
      maxMemoryMb = cfg.autoTune.maxMemoryMb;
      finalMaxMemoryMb = lib.max minMemoryMb (lib.min maxMemoryMb calculatedMaxMemoryMb);
      
      tcpBacklog = lib.min 2048 (512 * systemCores);
      
      availableForClientsMb = finalMaxMemoryMb * 0.8;
      maxClients = builtins.floor((availableForClientsMb * 1024) / 20); 
    in {
      maxmemory = "${toString finalMaxMemoryMb}mb";
      tcpBacklog = tcpBacklog;
      maxClients = lib.min 10000 maxClients;
      inherit systemRamMb systemCores finalMaxMemoryMb;
    };
  
  redisSettings = calculateRedisSettings;

  users.users.redis = {
    isSystemUser = true;
    group = "redis";
    description = "Redis database user";
  };

  users.groups.redis = {};

in {
  config = mkIf (config.services.wpbox.enable && cfg.enable) {
    
    assertions = [
      {
        assertion = cfg.autoTune.memoryAllocationRatio > 0 && cfg.autoTune.memoryAllocationRatio < 0.5;
        message = "Redis memory allocation ratio must be between 0 and 0.5 (0-50%)";
      }
      {
        assertion = redisSettings.finalMaxMemoryMb >= cfg.autoTune.minMemoryMb;
        message = "Calculated Redis memory is below minimum threshold";
      }
    ];

    warnings = 
      optional (redisSettings.finalMaxMemoryMb < 256)
        "WPBox Redis: Memory allocation is low (${toString redisSettings.finalMaxMemoryMb}MB)."
      ++
      optional (!cfg.persistence.enable)
        "WPBox Redis: Persistence is disabled. Data loss on restart is expected.";

    services.redis = {
      package = cfg.package;
      
      servers.wpbox = { 
        enable = true;
        bind = cfg.bind;
        port = cfg.port;
        unixSocket = cfg.unixSocket;
        unixSocketPerm = cfg.unixSocketPerm;
        
        settings = {
          # Memory settings
          maxmemory = if cfg.autoTune.enable then redisSettings.maxmemory else "256mb";
          maxmemory-policy = cfg.maxmemoryPolicy;
          maxmemory-samples = 5;
          
          # Network tuning
          # FIX: mkForce sulla singola opzione vince contro il default upstream (511)
          tcp-backlog = mkForce (if cfg.autoTune.enable then redisSettings.tcpBacklog else 511);
          tcp-keepalive = 300;
          timeout = 300;
          
          # Client connections
          # FIX: mkForce sulla singola opzione vince contro il default upstream (10000)
          maxclients = mkForce (if cfg.autoTune.enable then redisSettings.maxClients else 10000);
          
          # Persistence
          save = if cfg.persistence.enable then [ "900 1" "300 10" "60 10000" ] else [ ];
          stop-writes-on-bgsave-error = cfg.persistence.enable;
          rdbcompression = cfg.persistence.enable;
          rdbchecksum = cfg.persistence.enable;
          appendonly = cfg.persistence.enable;
          
          # Performance optimizations
          lazyfree-lazy-eviction = true;
          lazyfree-lazy-expire = true;
          lazyfree-lazy-server-del = true;
          replica-lazy-flush = true;
          lazyfree-lazy-user-del = true;
          
          # Logging
          loglevel = "notice";
          syslog-enabled = true;
          syslog-ident = "redis-wpbox";
          syslog-facility = "local0";
          
          # Security
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
    
    # Directories
    systemd.tmpfiles.rules = [
      "d /var/lib/redis-wpbox 0750 redis redis - -"
      "d /run/redis-wpbox 0750 redis redis - -"
      "d /var/log/redis 0755 redis redis - -"
    ];

    # Monitoring service
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
            $REDIS_CLI INFO clients | grep connected
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
    
    # Activation info
    system.activationScripts.wpbox-redis-info = lib.mkAfter (lib.mkIf cfg.autoTune.enable ''
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "   WPBox Redis Configuration"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "   System RAM:        ${toString redisSettings.systemRamMb}MB"
      echo "   Redis Memory:      ${toString redisSettings.finalMaxMemoryMb}MB (${toString (builtins.floor (cfg.autoTune.memoryAllocationRatio * 100))}%)"
      echo "   Max Clients:       ${toString redisSettings.maxClients}"
      echo "   TCP Backlog:       ${toString redisSettings.tcpBacklog}"
      echo "   Eviction Policy:   ${cfg.maxmemoryPolicy}"
      echo "   Persistence:       ${if cfg.persistence.enable then "✓ ENABLED" else "✗ DISABLED"}"
      echo "   Systemd Hardening: ${if config.services.wpbox.security.applyToRedis then "✓ ENABLED" else "✗ DISABLED"}"
      echo "   Auto-Tuning:       ${if cfg.autoTune.enable then "✓ ENABLED" else "✗ DISABLED"}"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    '');
  };
}