{ config, pkgs, ... }:

{

  imports = [./hardware-configuration.nix];

  # ################################################
  # ##              SYSTEM INFO                   ##
  # ################################################

  networking.hostName = "wpbox-dev";
  time.timeZone = "Europe/Amsterdam";
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  system.stateVersion = "25.05";

  # ################################################
  # ##         SYSTEM CONFIGURATION               ##
  # ################################################

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

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

  boot.kernel.sysctl = {
    "vm.swappiness" = 10;
    "vm.vfs_cache_pressure" = 50;
  };

  swapDevices = [{
    device = "/swapfile";
    size = 8192;  # 8GB
  }];

    # Automatic security updates
  system.autoUpgrade = {
    enable = true;
    allowReboot = false;
    dates = "04:00";
  };

  # Garbage collection
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  #############################
  ##   SECURITY HARDENING    ##
  #############################

  nix.settings.allowed-users = [ "@wheel" ];

  # SSH
  services.openssh.enable = true;
  services.openssh.settings.PermitRootLogin = "yes";

  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [ 22 80 443 ];


  # ################################################
  # ##           WPBOX CONFIGURATION              ##
  # ################################################

services.wpbox = {
  enable = true;
  
  wordpress = {
    enable = true;
    sites = ../../sites.json;
    tuning = {
      enableAuto = true;
    };
  };

  mariadb = {
      enable = true;
      package = pkgs.mariadb;
      autoTune.enable = true;
    };
  
  # Disabled on devm since runs locally
  # nginx = {
  #     enable = true;
  #     enableSSL = true;
  #     enableCloudflareRealIP = true;
  #     enableHSTSPreload = true;
  #     enableBrotli = true;
  #     acmeEmail = "sys-admin@martel-innovate.com";
  #   };
  
  # Fail2ban - Disabled on devm since runs locally
    # fail2ban = {
    #   enable = true;
    #   banTime = "2h";
    #   maxRetry = 3;
    #   ignoreIP = [
    #     "127.0.0.1/8"
    #     "::1"
    #     "100.64.0.0/10"  # Tailscale
    #   ];
    # };

  security = {
      enableHardening = true;
      level = "strict";
      applyToPhpFpm = true;
      applyToNginx = true;
      applyToMariadb = true;
    };
};

}
