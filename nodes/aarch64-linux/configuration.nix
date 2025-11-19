{ config, lib, pkgs, ... }:

{
  #############################
  ##   GENERAL OS SETTINGS   ##
  #############################

  imports = [./hardware-configuration.nix];

  networking.hostName = "wp-box-aarch64";
  time.timeZone = "Europe/Amsterdam";
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  system.stateVersion = "25.05";

  environment.systemPackages = with pkgs; [
    awscli2
    git
    eza
    bat
    wget
    zip
    unzip
    curl
    jq
  ];

  fileSystems."/" = {
    device = "/dev/disk/by-partlabel/disk-main-root";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-partlabel/disk-main-ESP";
    fsType = "vfat";
  };

  fileSystems."/backup" = {
    device = "/dev/disk/by-partlabel/disk-main-backup";
    fsType = "ext4";
  };

  boot.loader.grub = {
    enable = true;
    devices = [ "/dev/sda" ];
  }; 

  swapDevices = [{
    device = "/swapfile";
    size = 4096;  # 4GB
  }];

  boot.kernel.sysctl = {
    "vm.swappiness" = 10;
    "vm.vfs_cache_pressure" = 50;
  };

  #############################
  ##   SECURITY HARDENING    ##
  #############################

  users.users.root.hashedPassword = "!";

  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    hashedPassword = "!";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE3Ozoyo+Eday4ke3ddwv+CqXRh+ib3HE4CGKqNO1U5U"
    ];
    shell = pkgs.bash;
  };

  security.sudo.wheelNeedsPassword = false;

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PubkeyAuthentication = true;
      PermitRootLogin = "no";
      X11Forwarding = false;
      MaxAuthTries = 3;
    };
    extraConfig = ''
      AllowTcpForwarding yes
      AllowAgentForwarding no
      AllowStreamLocalForwarding no
    '';
  };

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 80 443 ];
    trustedInterfaces = [ "tailscale0" ];
  };

  #############################
  ##    SERVICES SETTINGS    ##
  #############################

  # Limit Nix daemon usage to wheel group
  nix.settings.allowed-users = [ "@wheel" ];

  # ################################################
  # ##           WPBOX CONFIGURATION              ##
  # ################################################

services.wpbox = {
  enable = true;
  
  wordpress = {
    enable = true;
    sitesFile = ../../sites.json;
    tuning = {
      enableAuto = true;
    };
  };

  redis = {
    enable = true;
    bind = null; # Disable TCP (socket only)
    port = 0;    # Disable TCP port
    autoTune.enable = true;
  };

  mariadb = {
      enable = true;
      package = pkgs.mariadb;
      autoTune.enable = true;
    };
  
  nginx = {
      enable = true;
      enableSSL = true;
      enableCloudflareRealIP = true;
      enableHSTSPreload = true;
      enableBrotli = true;
      acmeEmail = "sys-admin@martel-innovate.com";
    };
  
  # Fail2ban - Disabled on devm since runs locally
    fail2ban = {
      enable = true;
      banTime = "2h";
      maxRetry = 3;
      ignoreIP = [
        "127.0.0.1/8"
        "::1"
        "100.64.0.0/10"  # Tailscale
      ];
    };

    # tailscale = {
    #   enable = true;
    # };

  security = {
    enableHardening = true;
    level = "strict";
    applyToPhpFpm = true;
    applyToNginx = true;
    applyToMariadb = true;
    applyToRedis = true;
  };
};
}
