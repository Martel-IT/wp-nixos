{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.wpbox.security;
  wpCfg = config.services.wpbox.wordpress;

  # Base hardening applicable to all services
  commonHardening = {
    # Filesystem Protection
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    ProtectProc = "invisible";  # Hide /proc from other users
    ProtectHostname = true;
    ProtectClock = true;
    
    # Capabilities
    NoNewPrivileges = true;
    RestrictSUIDSGID = true;
    RemoveIPC = true;  # Clean IPC on service stop
    
    # System Calls
    LockPersonality = true;
    MemoryDenyWriteExecute = true;
    SystemCallArchitectures = "native";
    SystemCallFilter = [
      "@system-service"
      "~@privileged"
      "~@resources"
      "~@mount"
      "~@reboot"
      "~@swap"
      "~@obsolete"
      "~@debug"
    ];
    SystemCallErrorNumber = "EPERM";
    
    # Real-time
    RestrictRealtime = true;
    
    # Namespaces
    RestrictNamespaces = true;
    PrivateUsers = mkDefault true;  # Can be overridden if needed
    
    # Network (will be overridden for network services)
    RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
    IPAddressDeny = mkDefault "any";  # Deny by default
    IPAddressAllow = mkDefault "";    # Allow nothing by default
    
    # Resource Limits
    LimitNOFILE = 65536;
    LimitNPROC = 512;
    TasksMax = 512;
    
    # Security
    SecureBits = "keep-caps";
  };

  # Level-based hardening additions
  strictHardening = commonHardening // {
    # Even stricter filesystem protection
    ProcSubset = "pid";
    BindReadOnlyPaths = [
      "/etc/ssl"
      "/etc/pki"
      "/etc/ca-certificates"
    ];
    
    # More restrictive capabilities
    CapabilityBoundingSet = "";
    AmbientCapabilities = "";
    
    # Stricter resource limits
    LimitNPROC = 256;
    TasksMax = 256;
    
    # Additional restrictions
    KeyringMode = "private";
    ProtectKernelPerformance = true;
    RestrictFileSystems = [ "ext4" "tmpfs" "proc" ];
  };

  paranoidHardening = strictHardening // {
    # Maximum isolation
    PrivateNetwork = mkDefault true;  # Will break network services
    PrivateMounts = true;
    PrivateIPC = true;
    
    # Extreme resource limits
    LimitNPROC = 64;
    TasksMax = 64;
    CPUQuota = "50%";  # Limit CPU usage
    MemoryMax = "512M";  # Hard memory limit
    
    # Complete lockdown
    MountFlags = "slave";
    SystemCallFilter = [ "@system-service" "~@privileged" ];
  };

  # Select hardening level
  selectedHardening = 
    if cfg.level == "paranoid" then paranoidHardening
    else if cfg.level == "strict" then strictHardening
    else commonHardening;

  # Service-specific hardening
  phpHardening = selectedHardening // {
    # PHP-specific adjustments
    PrivateUsers = false;  # PHP needs to switch users
    SystemCallFilter = [ 
      "@system-service"
      "~@privileged"
      "~@resources"
      "setpriority"  # PHP uses this
      "kill"         # For process management
    ];
    
    # PHP needs these capabilities
    CapabilityBoundingSet = [ "CAP_SETGID" "CAP_SETUID" ];
    AmbientCapabilities = [];
    
    # Network access for MySQL/Redis connections
    IPAddressDeny = "";
    IPAddressAllow = "";
    RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
    
    # Resource limits appropriate for PHP
    MemoryMax = mkDefault "512M";  # Per pool
    CPUQuota = mkDefault "";  # No CPU limit by default
  };

  nginxHardening = selectedHardening // {
    # Nginx-specific adjustments
    PrivateUsers = false;  # Needs to bind to ports
    SystemCallFilter = [ 
      "@system-service"
      "@network-io"
      "~@privileged"
      "~@resources"
    ];
    
    # Nginx needs network capabilities
    CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ]; 
    AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
    
    # Network access required
    IPAddressDeny = "";
    IPAddressAllow = "";
    PrivateNetwork = false;
    RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" "AF_NETLINK" ];
    
    # Writable paths for Nginx
    ReadWritePaths = [
      "/var/log/nginx"
      "/var/cache/nginx"
      "/var/spool/nginx"
      "/run/nginx"
      "/run/phpfpm"  # For PHP-FPM sockets
    ];
    
    # Resource limits
    LimitNOFILE = 131072;  # Higher for web server
    TasksMax = 4096;
  };

  mariadbHardening = {
    # MariaDB needs less isolation
    NoNewPrivileges = true;
    PrivateTmp = true;
    ProtectSystem = "full";
    ProtectHome = true;
    
    # MariaDB-specific paths
    ReadWritePaths = [
      "/var/lib/mysql"
      "/run/mysqld"
      "/var/log/mysql"
    ];
    
    # Resource limits for database
    LimitNOFILE = 65536;
    LimitNPROC = 512;
    
    # Basic restrictions
    PrivateDevices = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    RestrictRealtime = true;
    
    # Network required for connections
    RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
  };

  redisHardening = selectedHardening // {
    # Redis-specific adjustments
    PrivateUsers = false;  # Redis user management
    
    # Filesystem access
    ReadWritePaths = [
      "/var/lib/redis-wpbox"
      "/run/redis-wpbox"
      "/var/log/redis"
    ];
    
    # Network configuration
    PrivateNetwork = mkIf (config.services.wpbox.redis.bind == null && 
                          config.services.wpbox.redis.port == 0) true;
    RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
    IPAddressDeny = mkIf (config.services.wpbox.redis.bind == null) "any";
    IPAddressAllow = mkIf (config.services.wpbox.redis.bind == null) "";
    
    # Memory settings for cache
    MemoryDenyWriteExecute = true;
    MemoryMax = mkDefault "1G";  # Cap Redis memory
    
    # Resource limits
    LimitNOFILE = 65536;
    LimitNPROC = 512;
    TasksMax = 512;
  };

  tailscaleHardening = selectedHardening // {
    # Tailscale needs network access
    PrivateNetwork = false;
    PrivateUsers = false;
    
    # Required capabilities
    CapabilityBoundingSet = [
      "CAP_NET_ADMIN"
      "CAP_NET_BIND_SERVICE"
      "CAP_NET_RAW"
      "CAP_DAC_READ_SEARCH"
      "CAP_SYS_MODULE"  # For TUN/TAP
    ];
    AmbientCapabilities = [
      "CAP_NET_ADMIN"
      "CAP_NET_BIND_SERVICE"
    ];
    
    # Network access
    RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" "AF_NETLINK" "AF_PACKET" ];
    IPAddressDeny = "";
    IPAddressAllow = "";
    
    # Writable paths
    ReadWritePaths = [
      "/var/lib/tailscale"
      "/run/tailscale"
      "/dev/net/tun"  # TUN device access
    ];
    
    # Device access for TUN
    PrivateDevices = false;
    DeviceAllow = [ "/dev/net/tun rw" ];
  };

in
{
  config = mkIf cfg.enableHardening {
    
    # PHP-FPM pools hardening
    systemd.services = mkMerge [
      # PHP-FPM services
      (mkIf cfg.applyToPhpFpm (
        mapAttrs' (hostName: siteCfg: 
          nameValuePair "phpfpm-wordpress-${hostName}" {
            serviceConfig = phpHardening // {
              # Site-specific paths
              ReadWritePaths = [ 
                "/var/lib/wordpress/${hostName}" 
                "/run/phpfpm"
                "/tmp"  # PHP temp files
              ];
              BindReadOnlyPaths = [ 
                "/nix/store" 
                "/etc/ssl"
                "/usr/share/zoneinfo"
              ];
              
              # Per-site memory limit
              MemoryMax = mkDefault (
                if config.services.wpbox.hardware.runtimeMemoryMb <= 4096 
                then "256M" 
                else "512M"
              );
            };
          }
        ) wpCfg.sites
      ))
      
      # Nginx hardening
      (mkIf cfg.applyToNginx {
        nginx.serviceConfig = nginxHardening;
      })
      
      # MariaDB hardening
      (mkIf cfg.applyToMariadb {
        mariadb.serviceConfig = mariadbHardening;
      })
      
      # Redis hardening
      (mkIf (config.services.wpbox.redis.enable && cfg.applyToRedis) {
        redis-wpbox.serviceConfig = redisHardening;
      })
      
      # Tailscale hardening
      (mkIf (config.services.wpbox.tailscale.enable && cfg.applyToTailscale) {
        tailscaled.serviceConfig = tailscaleHardening;
        tailscale-autoconnect.serviceConfig = tailscaleHardening // {
          Type = "oneshot";  # Keep original type
        };
      })
    ];

    # AppArmor profiles (optional)
    security.apparmor = mkIf cfg.enableApparmor {
      enable = true;
      packages = with pkgs; [ apparmor-profiles ];
    };

    # Additional kernel hardening
    boot.kernel.sysctl = mkIf (cfg.level == "strict" || cfg.level == "paranoid") {
      # Kernel hardening
      "kernel.dmesg_restrict" = 1;
      "kernel.kptr_restrict" = 2;
      "kernel.yama.ptrace_scope" = 1;
      "kernel.unprivileged_userns_clone" = 0;
      "kernel.unprivileged_bpf_disabled" = 1;
      "net.core.bpf_jit_harden" = 2;
      
      # Network hardening
      "net.ipv4.conf.all.accept_redirects" = 0;
      "net.ipv4.conf.all.accept_source_route" = 0;
      "net.ipv4.conf.all.log_martians" = 1;
      "net.ipv4.conf.all.rp_filter" = 1;
      "net.ipv4.conf.all.send_redirects" = 0;
      "net.ipv4.conf.default.accept_redirects" = 0;
      "net.ipv4.conf.default.accept_source_route" = 0;
      "net.ipv4.conf.default.log_martians" = 1;
      "net.ipv4.conf.default.rp_filter" = 1;
      "net.ipv4.icmp_echo_ignore_broadcasts" = 1;
      "net.ipv4.icmp_ignore_bogus_error_responses" = 1;
      "net.ipv4.tcp_syncookies" = 1;
      "net.ipv6.conf.all.accept_ra" = 0;
      "net.ipv6.conf.all.accept_redirects" = 0;
      "net.ipv6.conf.default.accept_ra" = 0;
      "net.ipv6.conf.default.accept_redirects" = 0;
    };
  };
}
