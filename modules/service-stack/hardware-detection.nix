{ config, lib, pkgs, ... }:

with lib;

let
  # Helper function to safely read runtime detected values
  readRuntimeValue = file: fallback:
    let
      script = pkgs.writeScript "read-runtime-value" ''
        #!${pkgs.bash}/bin/bash
        if [ -f "${file}" ]; then
          cat "${file}"
        else
          echo "${toString fallback}"
        fi
      '';
    in
      fallback; # During evaluation phase, use fallback
in
{
  options.hardware = {
    runtimeMemoryMb = mkOption {
      type = types.nullOr types.int;
      default = null;
      description = ''
        Override detected system RAM in MB. 
        If null, will be auto-detected at runtime from /proc/meminfo.
      '';
    };
    
    runtimeCores = mkOption {
      type = types.nullOr types.int;
      default = null;
      description = ''
        Override detected CPU cores.
        If null, will be auto-detected at runtime from /proc/cpuinfo.
      '';
    };

    # New options for better control
    detectionCache = {
      directory = mkOption {
        type = types.path;
        default = "/run/wpbox";
        description = "Directory where runtime detection values are cached";
      };

      ramFile = mkOption {
        type = types.str;
        default = "detected-ram-mb";
        description = "Filename for cached RAM value";
      };

      coresFile = mkOption {
        type = types.str;
        default = "detected-cores";
        description = "Filename for cached CPU cores value";
      };
    };

    fallback = {
      ramMb = mkOption {
        type = types.int;
        default = 4096;
        description = "Fallback RAM value in MB if detection fails";
      };

      cores = mkOption {
        type = types.int;
        default = 2;
        description = "Fallback CPU cores value if detection fails";
      };
    };
  };
  
  config = {
    # Create cache directory
    systemd.tmpfiles.rules = [
      "d ${config.hardware.detectionCache.directory} 0755 root root - -"
    ];

    # Detection script runs early in boot
    systemd.services.wpbox-hardware-detection = {
      description = "WPBox Hardware Detection";
      after = [ "local-fs.target" ];
      before = [ "multi-user.target" "mysql.service" "phpfpm.target" ];
      wantedBy = [ "multi-user.target" ];
      
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeScript "detect-hardware" ''
          #!${pkgs.bash}/bin/bash
          set -e
          
          echo "Detecting system hardware..."
          
          # Detect total RAM in MB
          if [ -f /proc/meminfo ]; then
            TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
            TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))
          else
            TOTAL_RAM_MB=${toString config.hardware.fallback.ramMb}
            echo "Using fallback RAM value"
          fi
          
          # Detect CPU cores
          if command -v nproc >/dev/null 2>&1; then
            CPU_CORES=$(nproc)
          elif [ -f /proc/cpuinfo ]; then
            CPU_CORES=$(grep -c ^processor /proc/cpuinfo)
          else
            CPU_CORES=${toString config.hardware.fallback.cores}
            echo "Using fallback CPU cores value"
          fi
          
          # Ensure cache directory exists
          mkdir -p ${config.hardware.detectionCache.directory}
          
          # Save to cache files
          echo "$TOTAL_RAM_MB" > ${config.hardware.detectionCache.directory}/${config.hardware.detectionCache.ramFile}
          echo "$CPU_CORES" > ${config.hardware.detectionCache.directory}/${config.hardware.detectionCache.coresFile}
          
          echo "   ✓ RAM: ''${TOTAL_RAM_MB}MB"
          echo "   ✓ CPU Cores: ''${CPU_CORES}"
          echo "   ✓ Cached to ${config.hardware.detectionCache.directory}/"
        '';
      };
    };

    # Activation script as backup (runs during nixos-rebuild)
    system.activationScripts.detectHardware = lib.mkAfter ''
      # Only run if cache files don't exist (fallback for activation)
      if [ ! -f ${config.hardware.detectionCache.directory}/${config.hardware.detectionCache.ramFile} ]; then
        echo "🔍 Running backup hardware detection during activation..."
        
        TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "$((${toString config.hardware.fallback.ramMb} * 1024))")
        TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))
        
        CPU_CORES=$(nproc 2>/dev/null || echo "${toString config.hardware.fallback.cores}")
        
        mkdir -p ${config.hardware.detectionCache.directory}
        echo "$TOTAL_RAM_MB" > ${config.hardware.detectionCache.directory}/${config.hardware.detectionCache.ramFile}
        echo "$CPU_CORES" > ${config.hardware.detectionCache.directory}/${config.hardware.detectionCache.coresFile}
        
        echo "   Detected RAM: ''${TOTAL_RAM_MB}MB"
        echo "   Detected CPU Cores: ''${CPU_CORES}"
      fi
    '';
  };
}
