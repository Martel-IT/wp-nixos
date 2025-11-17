{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.wpbox.security;
  wpCfg = config.services.wpbox.wordpress;
in
{

  options.services.wpbox.security = {
    enableHardening = mkEnableOption "Systemd security hardening for WP pools";
    level = mkOption {
      type = types.enum [ "basic" "strict" "paranoid" ];
      default = "strict";
      description = "Hardening level intensity";
    };
  };
};

{

  config = mkIf config.services.wpbox.security.enableSystemdHardening {
    
    # PHP systemd hardening
    systemd.services.php-fpm = {
      serviceConfig = {
        # Filesystem protection
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        
        # Security restrictions
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        
        # Syscall filtering
        SystemCallFilter = [ 
          "@system-service"
          "~@privileged"
          "~@resources"
          "setpriority"
        ];
        SystemCallErrorNumber = "EPERM";
        SystemCallArchitectures = "native";
        
        # Network restrictions
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        
        # Capabilities (drop all)
        CapabilityBoundingSet = "";
        
        # Memory protection
        # NOTE: Disabled for Python JIT compatibility
        # MemoryDenyWriteExecute = true;
      };
    };

    # Nginx systemd hardening
    systemd.services.nginx = {
      serviceConfig = {
        # Filesystem protection
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        
        # Writable paths
        ReadWritePaths = [
          "/var/log/nginx"
          "/var/cache/nginx"
          "/var/spool/nginx"
        
        ] ++ config.services.odbox.security.nginx.additionalWritablePaths;
        
        # Security restrictions
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        
        # Syscall filtering
        SystemCallFilter = [ 
          "@system-service"
          "~@privileged"
        ];
        SystemCallErrorNumber = "EPERM";
        SystemCallArchitectures = "native";
        
        # Network restrictions
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        
        # Capabilities (nginx needs CAP_NET_BIND_SERVICE for ports < 1024)
        CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
        AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
      };
    };
  };
}