{ config, lib, pkgs, ... }:

with lib;

{
  options.services.wpbox.tailscale = {
    enable = mkEnableOption "Tailscale VPN";
  };

  config = mkIf config.services.wpbox.tailscale.enable {
    
    # Enable the base Tailscale service
    services.tailscale.enable = true;
    
    # Custom service to auto-connect on boot
    systemd.services.tailscale-autoconnect = {
      description = "Tailscale autoconnect";
      after = [ "network-online.target" "tailscaled.service" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        
        # Authkey from /run/secrets (as requested)
        ExecStart = ''
          ${pkgs.bash}/bin/bash -c 'sleep 2 && ${pkgs.tailscale}/bin/tailscale up --authkey=$(cat /run/secrets/tailscale-authkey 2>/dev/null) --hostname=$(hostname)'
        '';
      };
    };
  };
}