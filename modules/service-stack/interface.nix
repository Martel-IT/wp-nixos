{ config, pkgs, lib, ... }:

with lib;
with types;

{
  options.services.wpbox = {
    
    # --- GLOBAL ---
    enable = mkEnableOption "WPBox Stack (WP + mariadb + Nginx + PHP-FPM)";

    sitesFile = mkOption {
      type = path;
      default = ./sites.json;
      description = "Path to the sites.json configuration file.";
    };

    # --- WORDPRESS ---
    wordpress = {
      package = mkOption {
        type = package;
        default = pkgs.wordpress;
        description = "The WordPress package to use.";
      };
      
      # Internal option to hold parsed sites
      sites = mkOption {
        type = attrsOf anything;
        default = {}; 
        internal = true;
        description = "Parsed sites configuration (internal).";
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
          description = "RAM (MB) reserved for OS/Nginx/mariadb.";
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
      enable = mkEnableOption "Managed mariadb 8.0";
      
      package = mkOption {
        type = package;
        default = pkgs.mariadb;
        description = "mariadb package to use.";
      };

      autoTune = {
        enable = mkOption {
          type = bool;
          default = true;
          description = "Enable mariadb auto-tuning logic.";
        };
        ramAllocationRatio = mkOption {
          type = float;
          default = 0.30;
          description = "Ratio of free RAM to allocate to mariadb (0.30 = 30%).";
        };
      };
      
      dataDir = mkOption {
        type = path;
        default = "/var/lib/mariadb";
        description = "Data directory for mariadb.";
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
      enable = mkEnableOption "Managed PHP-FPM Pools";
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
    };
  };
}
