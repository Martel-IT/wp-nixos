{ config, pkgs, lib, ... }:

with lib;
with types;

{
  options.services.wpbox = {
    
    # --- GLOBAL ---
    enable = mkEnableOption "WPBox Stack (WP + MySQL + Nginx + PHP-FPM)";

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
      
      # Internal option to hold parsed sites, populated by implementation
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
          description = "RAM (MB) reserved for OS/Nginx/MySQL.";
        };
        avgProcessSize = mkOption {
          type = int;
          default = 70;
          description = "Estimated RAM (MB) per PHP worker.";
        };
      };
    };

    # --- MYSQL ---
    mysql = {
      enable = mkEnableOption "Managed MySQL 8.0";
      
      package = mkOption {
        type = package;
        default = pkgs.mysql80;
        description = "MySQL package to use.";
      };

      autoTune = {
        enable = mkOption {
          type = bool;
          default = true;
          description = "Enable MySQL auto-tuning logic.";
        };
        ramAllocationRatio = mkOption {
          type = float;
          default = 0.30;
          description = "Ratio of free RAM to allocate to MySQL (0.30 = 30%).";
        };
      };
      
      dataDir = mkOption {
        type = path;
        default = "/var/lib/mysql";
        description = "Data directory for MySQL.";
      };
    };

    # --- NGINX ---
    nginx = {
      enable = mkEnableOption "Managed Nginx Proxy";
      # Qui potrai aggiungere opzioni future tipo 'enableModSecurity' etc.
    };

    # --- SECURITY ---
    security = {
      hardeningLevel = mkOption {
        type = enum [ "basic" "strict" "paranoid" ];
        default = "strict";
        description = "Systemd hardening level for services.";
      };
      
      enableSystemdHardening = mkEnableOption "Enable Systemd hardening features";
    };
  };
}