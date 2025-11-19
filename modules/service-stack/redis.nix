{ config, pkgs, lib, ... }:

with lib;

let 
  cfg = config.services.wpbox.redis;
  hwCfg = config.hardware;
  wpCfg = config.services.wpbox.wordpress;
  
  # Get system resources from hardware detection
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
      
      # Usiamo una stima semplificata della RAM "libera" per Redis (non ideale ma pragmatica)
      reservedRamMb = wpCfg.tuning.osRamHeadroom or 2048;
      availableForCache = lib.max 128 (systemRamMb - reservedRamMb);
      
      redisMemoryRatio = cfg.autoTune.memoryAllocationRatio;
      calculatedMaxMemoryMb = builtins.floor(availableForCache * redisMemoryRatio);
      
      # Clamp tra i limiti definiti dall'utente
      minMemoryMb = cfg.autoTune.minMemoryMb;
      maxMemoryMb = cfg.autoTune.maxMemoryMb;
      finalMaxMemoryMb = lib.max minMemoryMb (lib.min maxMemoryMb calculatedMaxMemoryMb);
      
      # Tuning di rete (solo se TCP è abilitato, altrimenti non serve ma non fa male)
      tcpBacklog = lib.min 2048 (512 * systemCores);
      
      # Max clients basato sulla memoria allocata
      availableForClientsMb = finalMaxMemoryMb * 0.8;
      maxClients = builtins.floor((availableForClientsMb * 1024) / 20); # 20KB per client
    in {
      maxmemory = "${toString finalMaxMemoryMb}mb";
      tcpBacklog = toString tcpBacklog;
      maxClients = toString (lib.min 10000 maxClients);
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
    
    # Assertions and Warnings (omitted for brevity)
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
        "WPBox Redis: Memory allocation is low (${toString redisSettings.finalMaxMemoryMb}MB). Consider increasing memory ratio or system RAM." ++
      optional (!cfg.persistence.enable)
        "WPBox Redis: Persistence is disabled. All cache data will be lost on restart (this is normal for object cache).";
    
    # Redis service configuration
    services.redis = {
      enable = true;
      package = cfg.package;
      
      servers.wpbox = { # Server-specific settings (multiple servers possible)
        enable = true;
        
        # Network configuration
        bind = cfg.bind;
        port = cfg.port;
        
        # Unix socket configuration
        unixSocket = cfg.unixSocket;
        unixSocketPerm = cfg.unixSocketPerm;
        
        # Memory and eviction settings
        settings = {
          # Memory management
          maxmemory = if cfg.autoTune.enable then redisSettings.maxmemory else "256mb"; 
          maxmemory-policy = cfg.maxmemoryPolicy;
          maxmemory-samples = "5";
          
          # Network tuning
          tcp-backlog = if cfg.autoTune.enable then redisSettings.tcpBacklog else "511";
          tcp-keepalive = "300";
          timeout = "300";
          
          # Client connections
          maxclients = if cfg.autoTune.enable then redisSettings.maxClients else "10000";
          
          # Persistence (disable for pure cache)
          save = if cfg.persistence.enable then [ "900 1" "300 10" "60 10000" ] else [ ];
          stop-writes-on-bgsave-error = if cfg.persistence.enable then "yes" else "no";
          rdbcompression = if cfg.persistence.enable then "yes" else "no";
          rdbchecksum = if cfg.persistence.enable then "yes" else "no";
          appendonly = if cfg.persistence.enable then "yes" else "no";
          
          # Performance optimizations
          lazyfree-lazy-eviction = "yes";
          lazyfree-lazy-expire = "yes";
          lazyfree-lazy-server-del = "yes";
          replica-lazy-flush = "yes";
          lazyfree-lazy-user-del = "yes";
          
          # Databases (WordPress uses only db 0)
          databases = "16";
          
          # Logging
          loglevel = "notice";
          syslog-enabled = "yes";
          syslog-ident = "redis-wpbox";
          syslog-facility = "local0";
          
          # Security: Rename commands
          protected-mode = "yes";
          rename-command = {
            FLUSHDB = "";
            FLUSHALL = "";
            KEYS = "";
            CONFIG = "";
            SHUTDOWN = "";
            BGREWRITEAOF = "";
            BGSAVE = "";
            SAVE = "";
            DEBUG = "";
          };
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
          
          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          echo "   Redis WPBox Status"
          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          
          # Connect via socket or TCP
          ${if cfg.unixSocket != null then
            ''REDIS_CLI="${pkgs.redis}/bin/redis-cli -s ${cfg.unixSocket}"''
          else
            ''REDIS_CLI="${pkgs.redis}/bin/redis-cli -h ${cfg.bind} -p ${toString cfg.port}"''
          }
          
          # Check if Redis is responding
          if $REDIS_CLI ping >/dev/null 2>&1; then
            echo "  ✓ Redis is responding"
            echo ""
            
            # Memory stats
            echo "Memory Stats:"
            $REDIS_CLI INFO memory | grep -E "^used_memory_human|^used_memory_peak_human|^maxmemory_human|^mem_fragmentation_ratio" | sed 's/^/  /' | sed 's/\r//g'
            echo ""
            
            # Client stats
            echo "Client Stats:"
            $REDIS_CLI INFO clients | grep -E "^connected_clients|^blocked_clients" | sed 's/^/  /' | sed 's/\r//g'
            echo ""
            
            # Performance stats
            echo "Performance Stats:"
            $REDIS_CLI INFO stats | grep -E "^total_commands_processed|^instantaneous_ops_per_sec|^keyspace_hits|^keyspace_misses" | sed 's/^/  /' | sed 's/\r//g'
            echo ""
            
            # Calculate hit rate
            HITS=$($REDIS_CLI INFO stats | grep "^keyspace_hits" | cut -d: -f2 | tr -d '\r')
            MISSES=$($REDIS_CLI INFO stats | grep "^keyspace_misses" | cut -d: -f2 | tr -d '\r')
            if [ -n "$HITS" ] && [ -n "$MISSES" ] && [ "$((HITS + MISSES))" -gt 0 ]; then
              HIT_RATE=$(awk "BEGIN {printf \"%.2f\", ($HITS / ($HITS + $MISSES)) * 100}")
              echo "  Hit Rate: $HIT_RATE%"
            fi
          else
            echo "  ✗ Redis is not responding"
          fi
          
          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        '';
      };
    };
    
    # Monitoring timer
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
      echo "   Max Clients:       ${redisSettings.maxClients}"
      echo "   TCP Backlog:       ${redisSettings.tcpBacklog}"
      echo "   Eviction Policy:   ${cfg.maxmemoryPolicy}"
      echo "   Persistence:       ${if cfg.persistence.enable then "✓ ENABLED" else "✗ DISABLED"}"
      echo "   Systemd Hardening: ${if config.services.wpbox.security.applyToRedis then "✓ ENABLED" else "✗ DISABLED"}"
      echo "   Auto-Tuning:       ${if cfg.autoTune.enable then "✓ ENABLED" else "✗ DISABLED"}"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    '');
  };
}