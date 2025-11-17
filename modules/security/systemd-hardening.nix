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

in
{
  
  config = mkIf cfg.enableHardening {

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