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

    # --- mariadb ---
    mariadb = {
      enable = mkEnableOption "Managed mariadb 8.0";
      
      package = mkOption {
        type = package;
        default = pkgs.mariadb80;
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
      # Add extra Nginx-specific options here if needed
    };

    # --- PHP-FPM ---
    phpfpm = {
      enable = mkEnableOption "Managed PHP-FPM Pools";
    };

    # --- SECURITY ---
    security = {
      enableHardening = mkEnableOption "Systemd security hardening features";
      
      level = mkOption {
        type = enum [ "basic" "strict" "paranoid" ];
        default = "strict";
        description = "Hardening level intensity.";
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

      applyTomariadb = mkOption {
        type = bool;
        default = true;
        description = "Apply hardening to mariadb service.";
      };
    };
  };
}