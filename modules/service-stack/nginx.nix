{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.wpbox.nginx;
  wpCfg = config.services.wpbox.wordpress;
  secCfg = config.services.wpbox.security;
in
{
  # No options defined here (see interface.nix)

  config = mkIf (cfg.enable || wpCfg.enable) {
    
    # --- GLOBAL NGINX CONFIGURATION ---
    services.nginx = {
      enable = true;
      user = "nginx";
      group = "nginx";
      
      # Recommended settings
      recommendedProxySettings = true;
      recommendedTlsSettings = true;
      recommendedOptimisation = true;
      recommendedGzipSettings = true;
      
      # Global tuning
      appendHttpConfig = ''
        # Performance
        sendfile on;
        tcp_nopush on;
        tcp_nodelay on;
        keepalive_timeout 65;
        types_hash_max_size 2048;
        
        # Security headers (global)
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-XSS-Protection "1; mode=block" always;
        add_header Referrer-Policy "no-referrer-when-downgrade" always;

        # Rate limiting zones
        limit_req_zone $binary_remote_addr zone=xmlrpc:10m rate=1r/s;
        limit_req_zone $binary_remote_addr zone=wplogin:10m rate=5r/m;

        # Logging
        log_format wpbox '$remote_addr - $remote_user [$time_local] '
                         '"$request" $status $body_bytes_sent '
                         '"$http_referer" "$http_user_agent" '
                         'rt=$request_time uct="$upstream_connect_time" '
                         'uht="$upstream_header_time" urt="$upstream_response_time"';
      '';

      # --- PER-SITE VIRTUAL HOSTS ---
      virtualHosts = 
        let
          # Get active WordPress sites from the central wpbox config
          activeSites = filterAttrs (n: v: v.enabled) config.services.wpbox.wordpress.sites;
          # Helper to get PHP-FPM socket path
          phpfpmSocket = name: "unix:${config.services.phpfpm.pools."wordpress-${name}".socket}";
        in
        mapAttrs (name: siteOpts: {
          
          serverName = name;
          
          # SSL Configuration
          forceSSL = siteOpts.ssl.forceSSL;
          enableACME = siteOpts.ssl.enabled;
          
          # Root points to the Nix store (immutable WordPress core)
          root = "${config.services.wordpress.sites.${name}.package}/share/wordpress";
          
          # Access logs per-site
          extraConfig = ''
            access_log /var/log/nginx/${name}-access.log wpbox;
            error_log /var/log/nginx/${name}-error.log warn;
            client_max_body_size ${siteOpts.nginx.client_max_body_size};
          '';
          
          locations = {
            
            # --- ROOT: PHP HANDLER ---
            "/" = {
              index = "index.php index.html";
              tryFiles = "$uri $uri/ /index.php?$args";
            };
            
            # --- PHP EXECUTION ---
            "~ \\.php$" = {
              extraConfig = ''
                fastcgi_split_path_info ^(.+\.php)(/.+)$;
                fastcgi_pass ${phpfpmSocket name};
                fastcgi_index index.php;
                include ${pkgs.nginx}/conf/fastcgi.conf;
                fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
                fastcgi_param PATH_INFO $fastcgi_path_info;
                
                # Timeouts
                fastcgi_read_timeout ${toString siteOpts.php.max_execution_time}s;
                fastcgi_send_timeout ${toString siteOpts.php.max_execution_time}s;
                
                # Buffering
                fastcgi_buffering on;
                fastcgi_buffers 16 16k;
                fastcgi_buffer_size 32k;
              '';
            };
            
            # --- MUTABLE WP-CONTENT (outside Nix Store) ---
            "/wp-content/" = {
              alias = "/var/lib/wordpress/${name}/wp-content/";
              extraConfig = ''
                expires max;
                log_not_found off;
                access_log off;
                
                # Security: Deny PHP in uploads
                location ~* ^/wp-content/uploads/.*\.php$ {
                  deny all;
                }
              '';
            };

            # --- STATIC ASSETS CACHING ---
            "~* \\.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$" = {
              extraConfig = ''
                expires 1y;
                add_header Cache-Control "public, immutable";
                log_not_found off;
                access_log off;
              '';
            };

            # --- SECURITY: DENY DOTFILES ---
            "~ /\\." = {
              extraConfig = "deny all;";
            };

            # --- SECURITY: PROTECT WP-CONFIG ---
            "~ wp-config\\.php" = {
              extraConfig = "deny all;";
            };
            
            # --- SECURITY: DENY PHP IN UPLOADS ---
            "~* /(?:uploads|files)/.*\\.php$" = {
              extraConfig = "deny all;";
            };
            
            # --- SECURITY: BLOCK SENSITIVE FILES ---
            "~* \\.(bak|config|sql|fla|psd|ini|log|sh|inc|swp|dist)$" = {
              extraConfig = "deny all;";
            };
            
            # --- WORDPRESS XMLRPC (rate limited) ---
            "= /xmlrpc.php" = {
              extraConfig = ''
                # Uncomment to completely disable XMLRPC
                # deny all;
                # Rate-limit XMLRPC to prevent attacks
                limit_req zone=xmlrpc burst=5 nodelay;
                fastcgi_pass ${phpfpmSocket name};
                include ${pkgs.nginx}/conf/fastcgi.conf;
                fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
              '';
            };

            # --- WORDPRESS LOGIN (rate limited) ---
            "= /wp-login.php" = {
              extraConfig = ''
                # Rate-limit login attempts
                limit_req zone=wplogin burst=2 nodelay;
                fastcgi_pass ${phpfpmSocket name};
                include ${pkgs.nginx}/conf/fastcgi.conf;
                fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
              '';
            };
            
          } // siteOpts.nginx.custom_locations;
          
        }) activeSites;
    };

    # --- LOG ROTATION ---
    services.logrotate.settings.nginx = {
      files = "/var/log/nginx/*.log";
      frequency = "daily";
      rotate = 14;
      compress = true;
      delaycompress = true;
      notifempty = true;
      sharedscripts = true;
      postrotate = ''
        [ -f /var/run/nginx/nginx.pid ] && kill -USR1 $(cat /var/run/nginx/nginx.pid)
      '';
    };

    # --- CREATE LOG DIRECTORIES ---
    systemd.tmpfiles.rules = [
      "d /var/log/nginx 0755 nginx nginx - -"
    ];

    # --- ACME SECURITY ---
    security.acme = {
      acceptTerms = mkDefault true;
      defaults.email = mkDefault "admin@example.com"; # CHANGE THIS!
    };
  };
}