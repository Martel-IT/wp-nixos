{ config, lib, pkgs, ... }:

with lib;

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
  };
  
  config = {
    system.activationScripts.detectHardware = lib.mkAfter ''
      echo "🔍 Detecting system hardware..."
      
      # Rileva RAM totale in MB
      TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
      TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))
      
      # Rileva CPU cores
      CPU_CORES=$(nproc)
      
      # Salva in file cache
      mkdir -p /run/wpbox
      echo "$TOTAL_RAM_MB" > /run/wpbox/detected-ram-mb
      echo "$CPU_CORES" > /run/wpbox/detected-cores
      
      echo "   RAM: ''${TOTAL_RAM_MB}MB"
      echo "   CPU Cores: ''${CPU_CORES}"
    '';
  };
}
