{ config, pkgs, lib, ... }:

with lib;
with types;

{
  options.services.wpbox = {
    
    # --- GLOBAL ---
    enable = mkEnableOption "WPBox Stack (WP + MariaDB + Nginx + PHP-FPM)";
    sitesFile = mkOption {
      type = path;
      default = ./sites.json;
      description = "Path to the sites.json configuration file.";
    };

    # --- WORDPRESS ---
    wordpress = {
      enable = mkEnableOption "WordPress hosting with auto-configuration";
      package = mkOption {
        type = package;
        default = pkgs.wordpress;
        description = "The WordPress package to use.";
      };
      
      # Internal option to hold parsed sites
      sitesFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path to sites.json configuration file";
      };

      defaults = {
        phpMemoryLimit = mkOption {
          type = str;
          default = "256M";
          description = "Default PHP memory limit";
        };
        maxExecutionTime = mkOption {
          type = int;
          default = 300;
          description = "Default PHP max execution time";
        };
        uploadMaxSize = mkOption {
          type = str;
          default = "64M";
          description = "Default max upload size";
        };
      };

      tuning = {
        enableAuto = mkOption {
          type = bool;
          default = true;
          description = "Enable auto-tuning based on System RAM.";
        };
        osRamHeadroom = mkOption {
          type = int;
          default = 2048;
          description = "RAM (MB) reserved for OS/Nginx/MariaDB.";
        };
        avgProcessSize = mkOption {
          type = int;
          default = 70;
          description = "Estimated RAM (MB) per PHP worker.";
        };
      };
    };

    # --- MARIADB ---
    mariadb = {
      enable = mkEnableOption "Managed MariaDB 8.0";
      package = mkOption {
        type = package;
        default = pkgs.mariadb;
        description = "MariaDB package to use.";
      };

      autoTune = {
        enable = mkOption {
          type = bool;
          default = true;
          description = "Enable MariaDB auto-tuning logic.";
        };
        ramAllocationRatio = mkOption {
          type = float;
          default = 0.30;
          description = "Ratio of free RAM to allocate to MariaDB (0.30 = 30%).";
        };
      };
      dataDir = mkOption {
        type = path;
        default = "/var/lib/mysql";
        description = "Data directory for MariaDB.";
      };
    };

    # --- NGINX ---
    nginx = {
      enable = mkEnableOption "Managed Nginx Proxy";
      enableSSL = mkOption {
        type = bool;
        default = true;
        description = "Enable SSL/TLS with ACME for all sites";
      };
      enableCloudflareRealIP = mkOption {
        type = bool;
        default = true;
        description = "Enable Cloudflare Real IP detection";
      };
      enableBrotli = mkOption {
        type = bool;
        default = true;
        description = "Enable Brotli compression";
      };
      enableHSTSPreload = mkOption {
        type = bool;
        default = true;
        description = "Enable HSTS preload directive";
      };
      acmeEmail = mkOption {
        type = str;
        default = "sys-admin@martel-innovate.com";
        description = "Email for ACME/Let's Encrypt notifications";
      };
    };

    # --- PHP-FPM ---
    phpfpm = {
      enable = mkOption {
        type = bool;
        default = true;
        description = "Managed PHP-FPM Pools";
      };
    };

    # --- FAIL2BAN ---
    fail2ban = {
      enable = mkEnableOption "Fail2ban WordPress protection";
      banTime = mkOption {
        type = str;
        default = "1h";
        description = "Ban duration";
      };
      findTime = mkOption {
        type = str;
        default = "10m";
        description = "Time window to count failures";
      };
      maxRetry = mkOption {
        type = int;
        default = 5;
        description = "Max failures before ban";
      };
      ignoreIP = mkOption {
        type = listOf str;
        default = [ "127.0.0.1/8" "::1" "100.64.0.0/10" ];
        description = "IPs to never ban (Tailscale, localhost, etc)";
      };
    };

    # --- REDIS ---
    redis = {
      enable = mkEnableOption "Managed Redis for WordPress Object Cache";
      
      package = mkOption {
        type = package;
        default = pkgs.redis;
        description = "Redis package to use";
      };
      
      bind = mkOption {
        type = types.nullOr types.str;
        default = "127.0.0.1";
        description = "Address to bind Redis to (set to null per Unix socket only)";
      };
      
      port = mkOption {
        type = types.port;
        default = 6379;
        description = "Port for Redis to listen on (set to 0 to disable TCP)";
      };
      
      unixSocket = mkOption {
        type = types.nullOr types.path;
        default = "/run/redis-wpbox/redis.sock";
        description = "Unix socket path (null to disable)";
      };
      
      unixSocketPerm = mkOption {
        type = types.int;
        default = 660;
        description = "Unix socket permissions";
      };
      
      autoTune = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Enable automatic tuning based on system resources";
        };
        
        memoryAllocationRatio = mkOption {
          type = types.float;
          default = 0.075; # 7.5% della RAM disponibile (ottimo default)
          description = "Percentage of system RAM to allocate to Redis (0.075 = 7.5%)";
        };
        
        minMemoryMb = mkOption {
          type = types.int;
          default = 128;
          description = "Minimum Redis memory in MB";
        };
        
        maxMemoryMb = mkOption {
          type = types.int;
          default = 1024;
          description = "Maximum Redis memory in MB for object cache";
        };
      };
      
      persistence = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = "Enable RDB/AOF persistence (disable for pure cache)";
        };
      };
      
      maxmemoryPolicy = mkOption {
        type = types.enum [
          "noeviction"
          "allkeys-lru"
          "allkeys-lfu"
          "allkeys-random"
          "volatile-lru"
          "volatile-lfu"
          "volatile-random"
          "volatile-ttl"
        ];
        default = "allkeys-lru";
        description = "Eviction policy when maxmemory is reached (LRU è ideale per object cache)";
      };
      
      hardening = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Enable systemd hardening for Redis service";
        };
      };
      
      monitoring = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Enable Redis monitoring and info logging";
        };
      };
    };

    # --- SECURITY ---
    security = {
      enableHardening = mkEnableOption "Systemd security hardening features";
      level = mkOption {
        type = enum [ "basic" "strict" "paranoid" ];
        default = "strict";
        description = "Hardening level intensity.";
      };

      applyToTailscale = mkOption {
        type = bool;
        default = true;
        description = "Apply hardening to Tailscale service.";
      };
      applyToPhpFpm = mkOption {
        type = bool;
        default = true;
        description = "Apply hardening to PHP-FPM pools.";
      };
      applyToNginx = mkOption {
        type = bool;
        default = true;
        description = "Apply hardening to Nginx service.";
      };
      applyToMariadb = mkOption {
        type = bool;
        default = true;
        description = "Apply hardening to MariaDB service.";
      };

      applyToRedis = mkOption {
        type = bool;
        default = true;
        description = "Apply hardening to Redis service.";
      };
    };
  };
}