{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.wpbox.fail2ban;
  wpCfg = config.services.wpbox.wordpress;
in
{
  
  config = mkIf (cfg.enable && wpCfg.enable) {
    services.fail2ban = {
      enable = true;
      maxretry = cfg.maxRetry;
      bantime = cfg.banTime;
      ignoreIP = cfg.ignoreIP;
      
      jails = {
        # WordPress login attempts
        wordpress-auth = ''
          enabled = true
          filter = wordpress-auth
          logpath = /var/log/nginx/*-login.log
          maxretry = ${toString cfg.maxRetry}
          findtime = ${cfg.findTime}
          bantime = ${cfg.banTime}
          action = iptables-multiport[name=wp-auth, port="http,https", protocol=tcp]
        '';

        # WordPress XMLRPC attacks
        wordpress-xmlrpc = ''
          enabled = true
          filter = wordpress-xmlrpc
          logpath = /var/log/nginx/*-access.log
          maxretry = 3
          findtime = 1m
          bantime = 24h
          action = iptables-multiport[name=wp-xmlrpc, port="http,https", protocol=tcp]
        '';

        # Nginx rate limit violations
        nginx-ratelimit = ''
          enabled = true
          filter = nginx-ratelimit
          logpath = /var/log/nginx/*-error.log
          maxretry = 10
          findtime = 2m
          bantime = 30m
          action = iptables-multiport[name=nginx-limit, port="http,https", protocol=tcp]
        '';

        # Nginx bad bots / exploits
        nginx-badbots = ''
          enabled = true
          filter = nginx-badbots
          logpath = /var/log/nginx/*-access.log
          maxretry = 2
          findtime = 1m
          bantime = 48h
          action = iptables-multiport[name=nginx-badbots, port="http,https", protocol=tcp]
        '';
      };
    };

    environment.etc = {
      "fail2ban/filter.d/wordpress-auth.conf".text = ''
        [Definition]
        failregex = ^<HOST> .* "POST /wp-login\.php HTTP/.*" (403|401)
                    ^<HOST> .* "POST /xmlrpc\.php HTTP/.*" 200
        ignoreregex =
      '';
      "fail2ban/filter.d/wordpress-xmlrpc.conf".text = ''
        [Definition]
        failregex = ^<HOST> .* "POST /xmlrpc\.php HTTP/.*" 200
        ignoreregex =
      '';
      "fail2ban/filter.d/nginx-ratelimit.conf".text = ''
        [Definition]
        failregex = limiting requests, excess:.* by zone.*client: <HOST>
        ignoreregex =
      '';
      "fail2ban/filter.d/nginx-badbots.conf".text = ''
        [Definition]
        failregex = ^<HOST> .* "(GET|POST|HEAD).*(\.php\?|SELECT |UNION |INSERT |eval\(|base64_).*" \d+ \d+
                    ^<HOST> .* "(GET|POST).*/wp-config\.php.*" \d+ \d+
                    ^<HOST> .* "(GET|POST).*(/\.\.|\.\./).*" \d+ \d+
        ignoreregex =
      '';
    };

    systemd.tmpfiles.rules = 
    [
      "f /var/log/nginx/fail2ban.log 0644 nginx nginx - -"
    ];
  };
}