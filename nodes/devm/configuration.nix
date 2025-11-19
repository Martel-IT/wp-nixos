{ config, pkgs, ... }:

{

  imports = [./hardware-configuration.nix];

  # ################################################
  # ##              SYSTEM INFO                   ##
  # ################################################

  networking.hostName = "wpbox-dev";
  networking.hosts = {
    "127.0.0.1" = [ 
      "site1.martel-innovate.com" 
      "site2.martel-innovate.com" 
      "site3.martel-innovate.com" 
    ];
  };

  time.timeZone = "Europe/Amsterdam";
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  system.stateVersion = "25.05";

  # ################################################
  # ##         SYSTEM CONFIGURATION               ##
  # ################################################

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # System packages (minimal)
  environment.systemPackages = with pkgs; [
    git
    curl
    htop
    ncdu  # Disk usage analyzer
    iotop # IO monitoring
    awscli2
    eza
    bat
    wget
    zip
    unzip
    jq
  ];

  swapDevices = [{
    device = "/swapfile";
    size = 2048;  # 2GB swap
  }];

  # Automatic security updates
  system.autoUpgrade = {
    enable = true;
    allowReboot = false;  # Don't auto-reboot production
    dates = "04:00";
    flags = [
      "--update-input"
      "nixpkgs"
      "-L" # print build logs
    ];
  };

  # Automatic garbage collection (aggressive for small disk)
  nix.gc = {
    automatic = true;
    dates = "daily";
    options = "--delete-older-than 7d";  # Keep only 7 days
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

  hardware = {
    runtimeMemoryMb = 4096;  # Force 4GB for consistent tuning
    runtimeCores = 2;        # Force 2 cores
    };
  
  wordpress = {
    enable = true;
    sitesFile = ../../sites.json;
    
    tuning = {
      enableAuto = true;
      osRamHeadroom = 1536;  # 1.5GB for OS (reduced from 2GB)
      avgProcessSize = 50;   # Reduced from 70MB (optimistic with OPcache)
    };

    defaults = {
      phpMemoryLimit = "128M";  # Reduced from 256M
      maxExecutionTime = 60;    # Reduced from 300s
      uploadMaxSize = "32M";    # Reduced from 64M
    };
  };

  mariadb = {
    enable = true;

    autoTune = {
      enable = true;
      ramAllocationRatio = 0.20;  # Only 20% for MariaDB (reduced from 30%)
    };
      
    security = {
      requireSecureTransport = false;  # Save CPU on small VPS
        auditLogging = false;  # Save disk I/O
        localInfile = false;
      };
    };


  
  # Disabled on devm since runs locally
  nginx = {
    enable = true;
    enableSSL = false;
    enableCloudflareRealIP = false;
    enableBrotli = false;  # Disable Brotli to save CPU
    enableHSTSPreload = false;
    acmeEmail = "sys-admin@martel-innovate.com";
      
    # Performance tuning
    workerProcesses = 2;  # Match CPU cores
    workerConnections = 512;  # Reduced for memory savings
      
      # FastCGI cache to reduce PHP load
    fastcgiCache = {
      enable = true;
      size = "50m";  # Smaller cache
      maxSize = "200m";  # Reduced max size
      inactive = "30m";
    };
  };

  phpfpm = {
    enable = true;
      
    opcache = {
      enable = true;
      memory = 64;  # Reduced from 128MB
      jit = "off";  # Disable JIT on small VPS (saves memory)
    };
      
    monitoring = {
      enable = false;  # Disable to save resources
    };
      
    emergency = {
      restartThreshold = 5;  # More aggressive restart
      restartInterval = "30s";
    };
      
    security = {
      disableFunctions = [
        "exec" "passthru" "shell_exec" "system" 
        "proc_open" "popen" "curl_exec" "curl_multi_exec"
        "parse_ini_file" "show_source" "phpinfo"
      ];
    };
  };

  redis = {
    enable = true;
    bind = null;  # Unix socket only (faster)
    port = 0;     # Disable TCP
      
    autoTune = {
      enable = true;
      memoryAllocationRatio = 0.05;  # Only 5% of RAM (~200MB)
      minMemoryMb = 128;
      maxMemoryMb = 256;  # Cap at 256MB
    };
      
    persistence = {
      enable = false;  # Pure cache mode (no disk I/O)
    };
      
    maxmemoryPolicy = "allkeys-lru";  # Best for cache
      
    monitoring = {
      enable = false;  # Save resources
    };
  };

  # Fail2ban - Disabled on devm since runs locally
  # fail2ban = {
  #   enable = true;
  #   banTime = "4h";  # Longer bans
  #   findTime = "10m";
  #   maxRetry = 3;  # Stricter
  #   ignoreIP = [
  #     "127.0.0.1/8"
  #     "::1"
  #     "100.64.0.0/10"  # Tailscale
  #     ];
  #   };

  security = {
    enableHardening = true;
    level = "strict";
    # applyToPhpFpm = true;
    applyToNginx = true;
    applyToMariadb = true;
    applyToRedis = true;
    applyToTailscale = false;  # Tailscale not enabled
  };
  
  monitoring = {
    enable = false;
  };
};

# ################################################
# ##         RESOURCE MONITORING                ##
# ################################################

  # Simple monitoring with systemd
  systemd.services.resource-monitor = {
    description = "Log system resources";
    after = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeScript "resource-monitor" ''
        #!${pkgs.bash}/bin/bash
        echo "=== Resource Usage at $(date) ===" | systemd-cat -t resource-monitor
        free -h | systemd-cat -t resource-monitor
        df -h | systemd-cat -t resource-monitor
        systemctl status --no-pager nginx mariadb redis-wpbox | systemd-cat -t resource-monitor
      '';
    };
  };

  systemd.timers.resource-monitor = {
    description = "Resource monitoring timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10min";
      OnUnitActiveSec = "1h";
    };
  };

  # OOM killer adjustment for critical services
  systemd.services.nginx.serviceConfig.OOMScoreAdjust = -500;
  systemd.services.mariadb.serviceConfig.OOMScoreAdjust = -500;
  systemd.services.redis-wpbox.serviceConfig.OOMScoreAdjust = -200;

}
