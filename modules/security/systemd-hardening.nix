{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.wpbox.security;
  wpCfg = config.services.wpbox.wordpress;

  
  commonHardening = {
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    PrivateDevices = true;
    NoNewPrivileges = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
    SystemCallArchitectures = "native";
    RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
  };

  phpHardening = commonHardening // {
    ProtectKernelLogs = true;
    # Syscall filtering
    SystemCallFilter = [ 
      "@system-service"
      "~@privileged"
      "~@resources"
      "setpriority"
    ];
    SystemCallErrorNumber = "EPERM";
    CapabilityBoundingSet = "";
  };

  nginxHardening = commonHardening // {
    ProtectKernelLogs = true;
    SystemCallFilter = [ 
      "@system-service"
      "~@privileged"
    ];
    SystemCallErrorNumber = "EPERM";
    CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
    AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
    ReadWritePaths = [
      "/var/log/nginx"
      "/var/cache/nginx"
      "/var/spool/nginx"
    ];
  };

  tailscaleHardening = {
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    PrivateDevices = true;
    NoNewPrivileges = true;
    RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
    CapabilityBoundingSet = [
      "CAP_NET_ADMIN"
      "CAP_NET_BIND_SERVICE"
      "CAP_NET_RAW"
      "CAP_DAC_READ_SEARCH"
    ];
  };

in
{
  
  config = mkIf cfg.enableHardening {

    systemd.services.tailscaled = mkIf cfg.applyToTailscale tailscaleHardening;

    systemd.services.tailscale-autoconnect = mkIf cfg.applyToTailscale (
      tailscaleHardening // {
        User = "root";
        Type = "oneshot";
      }
    );

    services.phpfpm.pools = mkIf cfg.applyToPhpFpm (
      mapAttrs' (hostName: siteCfg: 
        nameValuePair "wordpress-${hostName}" {
          serviceConfig = phpHardening // {
             ReadWritePaths = [ 
               "/var/lib/wordpress/${hostName}" 
               "/run/phpfpm"
               "/run/mysqld"
             ];
             BindReadOnlyPaths = [ 
               "/nix/store" 
               "/etc/ssl"
             ];
          };
        }
      ) wpCfg.sites
    );

    systemd.services.nginx = mkIf cfg.applyToNginx {
      serviceConfig = nginxHardening;
    };

    systemd.services.mariadb = mkIf cfg.applyToMariadb {
      serviceConfig = {
         NoNewPrivileges = true;
         PrivateTmp = true;
         ProtectSystem = "full";
      };
    };
  };
}