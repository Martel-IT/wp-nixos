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

    # --- HARDWARE DETECTION (moved from hardware-detection.nix) ---
    hardware = {
      runtimeMemoryMb = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = ''
          Override detected system RAM in MB. 
          If null, will be auto-detected at runtime from /proc/meminfo.
        '';
      };
      
      runtimeCores = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = ''
          Override detected CPU cores.
          If null, will be auto-detected at runtime from /proc/cpuinfo.
        '';
      };

      detectionCache = {
        directory = mkOption {
          type = types.path;
          default = "/run/wpbox";
          description = "Directory where runtime detection values are cached";
        };

        ramFile = mkOption {
          type = types.str;
          default = "detected-ram-mb";
          description = "Filename for cached RAM value";
        };

        coresFile = mkOption {
          type = types.str;
          default = "detected-cores";
          description = "Filename for cached CPU cores value";
        };
      };

      fallback = {
        ramMb = mkOption {
          type = types.int;
          default = 4096;
          description = "Fallback RAM value in MB if detection fails";
        };
        
        cores = mkOption {
          type = types.int;
          default = 2;
          description = "Fallback CPU cores value if detection fails";
        };
      };
    };

    # --- WORDPRESS ---
    wordpress = {
      enable = mkEnableOption "WordPress hosting with auto-configuration";
      
      package = mkOption {
        type = package;
        default = pkgs.wordpress;
        description = "The WordPress package to use.";
      };
      
      sitesFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path to sites.json configuration file";
      };

      # Complete sites definition with all submodules
      sites = mkOption {
        type = types.attrsOf (types.submodule {
          options = {
            domain = mkOption {
              type = types.str;
              description = "Domain name for the site";
            };
            
            enabled = mkOption {
              type = types.bool;
              default = true;
              description = "Whether this site is enabled";
            };
            
            php = mkOption {
              type = types.submodule {
                options = {
                  memory_limit = mkOption {
                    type = types.str;
                    default = "256M";
                    description = "PHP memory limit";
                  };
                  max_execution_time = mkOption {
                    type = types.int;
                    default = 300;
                    description = "PHP max execution time in seconds";
                  };
                  opcache_validate_timestamps = mkOption {
                    type = types.bool;
                    default = true;
                    description = "Whether to validate OPcache timestamps";
                  };
                  extra_ini = mkOption {
                    type = types.str;
                    default = "";
                    description = "Extra PHP ini settings";
                  };
                  custom_pool = mkOption {
                    type = types.nullOr types.attrs;
                    default = null;
                    description = "Custom PHP-FPM pool settings";
                  };
                };
              };
              default = {};
              description = "PHP configuration for this site";
            };
            
            nginx = mkOption {
              type = types.submodule {
                options = {
                  client_max_body_size = mkOption {
                    type = types.str;
                    default = "64M";
                    description = "Maximum client body size";
                  };
                  custom_locations = mkOption {
                    type = types.attrsOf types.attrs;
                    default = {};
                    description = "Custom Nginx location blocks";
                  };
                };
              };
              default = {};
              description = "Nginx configuration for this site";
            };
            
            wordpress = mkOption {
              type = types.submodule {
                options = {
                  debug = mkOption {
                    type = types.bool;
                    default = false;
                    description = "Enable WordPress debug mode";
                  };
                  auto_update = mkOption {
                    type = types.bool;
                    default = false;
                    description = "Enable WordPress auto updates";
                  };
                  extra_config = mkOption {
                    type = types.str;
                    default = "";
                    description = "Extra WordPress configuration";
                  };
                };
              };
              default = {};
              description = "WordPress configuration for this site";
            };
            
            ssl = mkOption {
              type = types.submodule {
                options = {
                  enabled = mkOption {
                    type = types.bool;
                    default = true;
                    description = "Enable SSL for this site";
                  };
                  forceSSL = mkOption {
                    type = types.bool;
                    default = true;
                    description = "Force SSL redirect";
                  };
                };
              };
              default = {};
              description = "SSL configuration for this site";
            };
          };
        });
        default = {};
        description = "WordPress sites configuration";
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
      enable = mkEnableOption "Managed MariaDB";
      
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
      
      # Security options
      security = {
        requireSecureTransport = mkOption {
          type = bool;
          default = false;
          description = "Require SSL/TLS for all connections";
        };
        auditLogging = mkOption {
          type = bool;
          default = true;
          description = "Enable audit logging";
        };
        localInfile = mkOption {
          type = bool;
          default = false;
          description = "Allow LOAD DATA LOCAL INFILE";
        };
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
      
      # Performance tuning
      workerProcesses = mkOption {
        type = types.either types.str types.int;
        default = "auto";
        description = "Number of Nginx worker processes";
      };
      
      workerConnections = mkOption {
        type = types.int;
        default = 1024;
        description = "Maximum number of connections per worker";
      };
      
      # Caching
      fastcgiCache = {
        enable = mkOption {
          type = bool;
          default = true;
          description = "Enable FastCGI caching for WordPress";
        };
        
        size = mkOption {
          type = str;
          default = "100m";
          description = "FastCGI cache size";
        };
        
        maxSize = mkOption {
          type = str;
          default = "1g";
          description = "Maximum FastCGI cache size on disk";
        };
        
        inactive = mkOption {
          type = str;
          default = "60m";
          description = "Time to keep inactive cache entries";
        };
      };
    };

    # --- PHP-FPM (complete options moved here) ---
    phpfpm = {
      enable = mkOption {
        type = bool;
        default = true;
        description = "Managed PHP-FPM Pools";
      };
      
      package = mkOption {
        type = types.package;
        default = pkgs.php82.withExtensions ({ enabled, all }: enabled ++ (with all; [
          imagick redis memcached apcu opcache zip gd mbstring intl bcmath soap exif
        ]));
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
        
        jit = mkOption {
          type = types.enum [ "off" "tracing" "function" ];
          default = "off";
          description = "JIT compilation mode (PHP 8+)";
        };
        
        jitBufferSize = mkOption {
          type = types.str;
          default = "64M";
          description = "JIT buffer size";
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
      
      security = {
        disableFunctions = mkOption {
          type = types.listOf types.str;
          default = [
            "exec" "passthru" "shell_exec" "system" "proc_open" "popen"
            "parse_ini_file" "show_source" "phpinfo" "eval" "assert"
          ];
          description = "PHP functions to disable for security";
        };
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
        description = "Address to bind Redis to (set to null for Unix socket only)";
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
          default = 0.075;
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
          "noeviction" "allkeys-lru" "allkeys-lfu" "allkeys-random"
          "volatile-lru" "volatile-lfu" "volatile-random" "volatile-ttl"
        ];
        default = "allkeys-lru";
        description = "Eviction policy when maxmemory is reached";
      };
      
      monitoring = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Enable Redis monitoring and info logging";
        };
      };
    };

    # --- TAILSCALE ---
    tailscale = {
      enable = mkEnableOption "Tailscale VPN";
      
      authKeyFile = mkOption {
        type = types.nullOr types.path;
        default = "/run/secrets/tailscale-authkey";
        description = "Path to file containing Tailscale auth key";
      };
      
      hostname = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Custom hostname for Tailscale (defaults to system hostname)";
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
      
      # Additional security options
      forceStrongPasswords = mkOption {
        type = bool;
        default = true;
        description = "Enforce strong password policy for database users";
      };
      
      enableSelinux = mkOption {
        type = bool;
        default = false;
        description = "Enable SELinux (requires kernel support)";
      };
      
      enableApparmor = mkOption {
        type = bool;
        default = false;
        description = "Enable AppArmor profiles";
      };
    };

    # --- MONITORING ---
    monitoring = {
      enable = mkEnableOption "System monitoring and alerting";
      
      prometheus = {
        enable = mkOption {
          type = bool;
          default = false;
          description = "Enable Prometheus metrics collection";
        };
        
        port = mkOption {
          type = types.port;
          default = 9090;
          description = "Prometheus server port";
        };
      };
      
      grafana = {
        enable = mkOption {
          type = bool;
          default = false;
          description = "Enable Grafana dashboards";
        };
        
        port = mkOption {
          type = types.port;
          default = 3000;
          description = "Grafana server port";
        };
      };
    };

    # --- BACKUP ---
    backup = {
      enable = mkEnableOption "Automated backup system";
      
      schedule = mkOption {
        type = types.str;
        default = "daily";
        description = "Backup schedule (systemd timer format)";
      };
      
      retention = {
        daily = mkOption {
          type = types.int;
          default = 7;
          description = "Number of daily backups to keep";
        };
        
        weekly = mkOption {
          type = types.int;
          default = 4;
          description = "Number of weekly backups to keep";
        };
        
        monthly = mkOption {
          type = types.int;
          default = 3;
          description = "Number of monthly backups to keep";
        };
      };
      
      destination = mkOption {
        type = types.str;
        default = "/backup";
        description = "Backup destination path";
      };
      
      includeDatabase = mkOption {
        type = bool;
        default = true;
        description = "Include database dumps in backups";
      };
      
      includeFiles = mkOption {
        type = bool;
        default = true;
        description = "Include WordPress files in backups";
      };
    };
  };
}
