{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.wpbox.hardware;
in
{
  config = mkIf config.services.wpbox.enable {
    

    systemd.tmpfiles.rules = [
      "d /run/wpbox 0755 root root - -"
    ];

    systemd.services.wpbox-hardware-detect = {
      description = "WPBox Hardware Detection";
      wantedBy = [ "multi-user.target" ];
      before = [ "mysql.service" "phpfpm.service" "redis-wpbox.service" "nginx.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        # 1. Detect RAM (MB)
        # Se l'utente ha forzato un valore nella config Nix, lo scriviamo nel file per coerenza
        ${if cfg.runtimeMemoryMb != null then ''
          echo "${toString cfg.runtimeMemoryMb}" > /run/wpbox/detected-ram-mb
        '' else ''
          # Altrimenti rileviamo dal sistema
          total_mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
          total_mem_mb=$(($total_mem_kb / 1024))
          echo "$total_mem_mb" > /run/wpbox/detected-ram-mb
        ''}

        # 2. Detect Cores
        ${if cfg.runtimeCores != null then ''
          echo "${toString cfg.runtimeCores}" > /run/wpbox/detected-cores
        '' else ''
          core_count=$(nproc)
          echo "$core_count" > /run/wpbox/detected-cores
        ''}
        
        chmod 644 /run/wpbox/detected-*
      '';
    };
  };
}