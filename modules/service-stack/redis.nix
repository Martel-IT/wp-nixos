{ config, pkgs, lib, ... }:

let 
  
  cfg = config.services.wpbox.redis;

in {
  config = mkIf cfg.enable {
    services.redis = {
      enable = true;
      package = cfg.package;
      bind = cfg.bind;
      port = cfg.port;
      maxmemory = cfg.maxmemory;
    };
  };
}
