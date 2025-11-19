{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.wpbox.security;
  wpCfg = config.services.wpbox.wordpress;

  commonHardening = {
    ProtectSystem = mkForce "strict";
    ProtectHome = mkForce true;
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    ProtectProc = "invisible";
    ProtectHostname = true;
    ProtectClock = true;
    NoNewPrivileges = true;
    RestrictSUIDSGID = true;
    RemoveIPC = true;
    LockPersonality = true;
    MemoryDenyWriteExecute = true;
    SystemCallArchitectures = "native";
    SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" "~@mount" "~@reboot" "~@swap" "~@obsolete" "~@debug" ];
    SystemCallErrorNumber = "EPERM";
    RestrictRealtime = true;
    RestrictNamespaces = true;
    PrivateUsers = true; 
    RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
    IPAddressDeny = "any";
    IPAddressAllow = "";
    LimitNOFILE = mkForce 65536;
    LimitNPROC = mkForce 512;
    TasksMax = mkForce 512;
    SecureBits = "keep-caps";
  };

  strictHardening = commonHardening // {
    ProcSubset = "pid";
    BindReadOnlyPaths = [
      "-/etc/ssl"
      "-/etc/pki"
      "-/etc/ca-certificates"
    ];
    CapabilityBoundingSet = "";
    AmbientCapabilities = "";
    LimitNPROC = mkForce 256;
    TasksMax = mkForce 256;
    KeyringMode = "private";
    ProtectKernelPerformance = true;
    # RestrictFileSystems = [ "ext4" "tmpfs" "proc" ]; # Commentato per evitare errori BPF
  };

  paranoidHardening = strictHardening // {
    PrivateNetwork = true;
    PrivateMounts = true;
    PrivateIPC = true;
    LimitNPROC = mkForce 64;
    TasksMax = mkForce 64;
    CPUQuota = "50%";
    MemoryMax = "512M";
    MountFlags = "slave";
    SystemCallFilter = [ "@system-service" "~@privileged" ];
  };

  selectedHardening = 
    if cfg.level == "paranoid" then paranoidHardening
    else if cfg.level == "strict" then strictHardening
    else commonHardening;

  phpHardening = selectedHardening // {
    PrivateUsers = false; 
    SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" "setpriority" "kill" ];
    CapabilityBoundingSet = [ "CAP_SETGID" "CAP_SETUID" ];
    AmbientCapabilities = [];
    IPAddressDeny = "";
    IPAddressAllow = "";
    RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
    MemoryMax = "512M";
    CPUQuota = "";
    
    BindReadOnlyPaths = [ 
      "/nix/store" 
      "-/etc/ssl" 
      "-/etc/pki" 
      "-/etc/ca-certificates"
      "-/usr/share/zoneinfo"
    ];
  };

  nginxHardening = selectedHardening // {
    PrivateUsers = false;
    SystemCallFilter = [ "@system-service" "@network-io" "~@privileged" "~@resources" ];
    CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ]; 
    AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
    IPAddressDeny = "";
    IPAddressAllow = "";
    PrivateNetwork = false;
    RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" "AF_NETLINK" ];
    ReadWritePaths = [ "/var/log/nginx" "/var/cache/nginx" "/var/spool/nginx" "/run/nginx" "/run/phpfpm" ];
    LimitNOFILE = mkForce 131072;
    TasksMax = mkForce 4096;
  };

  mariadbHardening = {
    NoNewPrivileges = true;
    PrivateTmp = true;
    ProtectSystem = "full";
    ProtectHome = true;
    ReadWritePaths = [ "/var/lib/mysql" "/run/mysqld" "/var/log/mysql" ];
    LimitNOFILE = mkForce 65536;
    LimitNPROC = mkForce 512;
    PrivateDevices = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    RestrictRealtime = true;
    RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
  };

  redisHardening = selectedHardening // {
    ReadWritePaths = [ "/var/lib/redis-wpbox" "/run/redis-wpbox" "-/var/log/redis" ];
    PrivateNetwork = if (config.services.wpbox.redis.bind == null && config.services.wpbox.redis.port == 0) then true else false;
    RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
    IPAddressDeny = if (config.services.wpbox.redis.bind == null) then "any" else "";
    IPAddressAllow = if (config.services.wpbox.redis.bind == null) then "" else "";
    MemoryDenyWriteExecute = true;
    MemoryMax = "1G";
    LimitNOFILE = mkForce 65536;
    LimitNPROC = mkForce 512;
    TasksMax = mkForce 512;
  };

  tailscaleHardening = selectedHardening // {
    PrivateNetwork = false;
    PrivateUsers = false;
    CapabilityBoundingSet = [ "CAP_NET_ADMIN" "CAP_NET_BIND_SERVICE" "CAP_NET_RAW" "CAP_DAC_READ_SEARCH" "CAP_SYS_MODULE" ];
    AmbientCapabilities = [ "CAP_NET_ADMIN" "CAP_NET_BIND_SERVICE" ];
    RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" "AF_NETLINK" "AF_PACKET" ];
    IPAddressDeny = "";
    IPAddressAllow = "";
    ReadWritePaths = [ "/var/lib/tailscale" "/run/tailscale" "/dev/net/tun" ];
    PrivateDevices = false;
    DeviceAllow = [ "/dev/net/tun rw" ];
  };

in
{
  config = mkIf cfg.enableHardening {
    systemd.services = mkMerge [
      (mkIf cfg.applyToPhpFpm (
        mapAttrs' (hostName: siteCfg: 
          nameValuePair "phpfpm-wordpress-${hostName}" {
            serviceConfig = phpHardening // {
              ReadWritePaths = [ 
                "/var/lib/wordpress/${hostName}" 
                "/run/phpfpm"
                "/tmp"
                "/var/log/phpfpm"
              ];
              # Usa la definizione locale sovrascrivendo se necessario, ma phpHardening ha già quella corretta
              MemoryMax = if config.services.wpbox.hardware.runtimeMemoryMb <= 4096 then "256M" else "512M";
            };
          }
        ) wpCfg.sites
      ))
      (mkIf cfg.applyToNginx { nginx.serviceConfig = nginxHardening; })
      (mkIf cfg.applyToMariadb { mariadb.serviceConfig = mariadbHardening; })
      (mkIf (config.services.wpbox.redis.enable && cfg.applyToRedis) { redis-wpbox.serviceConfig = redisHardening; })
      (mkIf (config.services.wpbox.tailscale.enable && cfg.applyToTailscale) {
        tailscaled.serviceConfig = tailscaleHardening;
        tailscale-autoconnect.serviceConfig = tailscaleHardening // { Type = "oneshot"; };
      })
    ];

    security.apparmor = mkIf cfg.enableApparmor {
      enable = true;
      packages = with pkgs; [ apparmor-profiles ];
    };

    boot.kernel.sysctl = mkIf (cfg.level == "strict" || cfg.level == "paranoid") {
      "kernel.dmesg_restrict" = 1;
      "kernel.kptr_restrict" = 2;
      "kernel.yama.ptrace_scope" = 1;
      "kernel.unprivileged_userns_clone" = 0;
      "kernel.unprivileged_bpf_disabled" = 1;
      "net.core.bpf_jit_harden" = 2;
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