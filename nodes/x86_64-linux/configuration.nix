{ config, pkgs, lib, modulesPath, ... }:

with lib;

{
  imports = [ "${modulesPath}/virtualisation/amazon-image.nix" ];
  ec2.efi = true;

  # ################################################
  # ##              SYSTEM INFO                   ##
  # ################################################

  networking.hostName = "wpbox-x86_64";  # Hostname for the system
  time.timeZone = "Europe/Amsterdam";
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  system.stateVersion = "25.05";

  # ################################################
  # ##         OPTIMIZED FOR SMALL VPS            ##
  # ##         (2 vCPU, 4GB RAM)                  ##
  # ################################################


  # Swap configuration for small VPS
  swapDevices = [{
    device = "/swapfile";
    size = 2048;  # 2GB swap for 4GB RAM system
    priority = 10;
  }];

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

  # Automatic garbage collection (aggressive for small disk)
  nix.gc = {
    automatic = true;
    dates = "daily";
    options = "--delete-older-than 7d";  # Keep only 7 days
  };

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

  #############################
  ##   SECURITY HARDENING    ##
  #############################

  # Disable root login
  users.users.root.hashedPassword = "!";

  # Admin user
  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" "systemd-journal" ];
    hashedPassword = "!";  # Set with passwd after deployment
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE3Ozoyo+Eday4ke3ddwv+CqXRh+ib3HE4CGKqNO1U5U"
    ];
  };

  # SSH hardening
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PubkeyAuthentication = true;
      PermitRootLogin = lib.mkForce "no";
      X11Forwarding = false;
      MaxAuthTries = 3;
      ClientAliveInterval = 300;
      ClientAliveCountMax = 2;
    };
    extraConfig = ''
      AllowUsers admin
      Protocol 2
      LoginGraceTime 30
      MaxSessions 10
      MaxStartups 10:30:60
    '';
  };

  # Firewall
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 80 443 ];
  };

  # Security limits
  security.pam.loginLimits = [
    {
      domain = "*";
      type = "soft";
      item = "nofile";
      value = "65536";
    }
    {
      domain = "*";
      type = "hard";
      item = "nofile";
      value = "65536";
    }
  ];

  # ################################################
  # ##    WPBOX OPTIMIZED CONFIGURATION           ##
  # ##    FOR SMALL VPS (2vCPU, 4GB RAM)          ##
  # ################################################

  services.wpbox = {
    enable = true;
    
    # Override hardware detection for consistent tuning
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
    
    nginx = {
      enable = true;
      enableSSL = true;
      enableCloudflareRealIP = true;
      enableBrotli = false;  # Disable Brotli to save CPU
      enableHSTSPreload = true;
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
    
    fail2ban = {
      enable = true;
      banTime = "4h";  # Longer bans
      findTime = "10m";
      maxRetry = 3;  # Stricter
      ignoreIP = [
        "127.0.0.1/8"
        "::1"
        # Add your monitoring service IPs here
      ];
    };
    
    security = {
      enableHardening = true;
      level = "strict";
      applyToPhpFpm = true;
      applyToNginx = true;
      applyToMariadb = true;
      applyToRedis = true;
      applyToTailscale = false;  # Tailscale not enabled
    };
    
    # Monitoring disabled to save resources
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
