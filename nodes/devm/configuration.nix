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

  # Enable WPBox WordPress
  services.wpbox.wordpress = {
    enable = true;
    # sitesFile points to sites.json (default: ./sites.json)
    sitesFile = ./sites.json;
  };

  # Enable auto-tuned MySQL
  services.wpbox.mysql = {
    enable = true;
    autoTune.enable = true;
  };

  # Enable systemd hardening
  services.wpbox.security = {
    enableHardening = true;
    level = "strict";
    applyToPhpFpm = true;
    applyToNginx = true;
    applyToMysql = true;
  };

  services.wpbox.nginx.enable = true;

  # ACME / Let's Encrypt (⚠️ CHANGE THE EMAIL!)
  security.acme = {
    acceptTerms = true;
    defaults.email = "admin@example.com"; # ⚠️ CHANGE THIS!
  };

}
