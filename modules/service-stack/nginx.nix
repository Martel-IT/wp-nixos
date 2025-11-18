{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.wpbox.nginx;
  wpCfg = config.services.wpbox.wordpress;
  secCfg = config.services.wpbox.security;
  
  realIpsFromList = lib.strings.concatMapStringsSep "\n" (x: "set_real_ip_from  ${x};");
  fileToList = x: lib.strings.splitString "\n" (builtins.readFile x);
  
  cfipv4 = fileToList (pkgs.fetchurl {
    url = "https://www.cloudflare.com/ips-v4";
    sha256 = "0ywy9sg7spafi3gm9q5wb59lbiq0swvf0q3iazl0maq1pj1nsb7h";
  });
  
  cfipv6 = fileToList (pkgs.fetchurl {
    url = "https://www.cloudflare.com/ips-v6";
    sha256 = "1ad09hijignj6zlqvdjxv7rjj8567z357zfavv201b9vx3ikk7cy";
  });
  
  # Cache skip conditions string
  cacheSkipDirectives = ''
    set $skip_cache 0;

    if ($request_method = POST) {
      set $skip_cache 1;
    }
    
    if ($query_string != "") {
      set $skip_cache 1;
    }

    if ($request_uri ~* "/wp-admin/|/xmlrpc.php|wp-.*.php|^/feed/*|/tag/.*/feed/*|index.php|/.*sitemap.*\.(xml|xsl)") {
      set $skip_cache 1;
    }

    if ($http_cookie ~* "comment_author|wordpress_[a-f0-9]+|wp-postpass|wordpress_no_cache|wordpress_logged_in") {
      set $skip_cache 1;
    }
  '';
in
{
  config = mkIf (cfg.enable || wpCfg.enable) {
    
    # Redirect http->https if SSL is enabled
    server."http_redirect" = if cfg.enableSSL then {
      listen = [ { addr = "0.0.0.0"; port = 80; } ];
      serverName = builtins.concatSep " " (attrNames (filterAttrs (n: v: v.enabled) wpCfg.sites));
      extraConfig = ''
        return 301 https://$host$request_uri;
      '';
    } else null;

    security.acme = mkIf cfg.enableSSL {
      acceptTerms = true;
      defaults.email = cfg.acmeEmail;
    };
    
    services.nginx = {
      enable = true;
      user = "nginx";
      group = "nginx";
      
      additionalModules = [ pkgs.nginxModules.moreheaders ];

      recommendedProxySettings = true;
      recommendedTlsSettings = true;
      recommendedOptimisation = true;
      recommendedGzipSettings = true;
      recommendedBrotliSettings = mkIf cfg.enableBrotli true;
      
      sslCiphers = "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384";
      sslProtocols = "TLSv1.2 TLSv1.3";

      commonHttpConfig = ''
        proxy_headers_hash_max_size 2048;
        proxy_headers_hash_bucket_size 128;
        
        ${optionalString cfg.enableCloudflareRealIP ''
        ${realIpsFromList cfipv4}
        ${realIpsFromList cfipv6}
        real_ip_header CF-Connecting-IP;
        ''}
        
        ${cacheSkipDirectives}
        
        # Logging for debug cache
        add_header X-Cache-Status $upstream_cache_status;
        
        limit_req_zone $binary_remote_addr zone=wp_general:10m rate=20r/s;
        limit_req_zone $binary_remote_addr zone=wp_bots:10m rate=5r/s;
        limit_req_zone $binary_remote_addr zone=wp_admin:10m rate=5r/m; # Nota: rate basso per admin
        limit_req_zone $binary_remote_addr zone=wp_api:10m rate=30r/s;
        limit_req_zone $binary_remote_addr zone=wp_login:10m rate=5r/m;
        limit_req_zone $binary_remote_addr zone=wp_static:10m rate=100r/s;
      '';
      
      appendHttpConfig = ''
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-XSS-Protection "1; mode=block" always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;
        add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;
        ${optionalString cfg.enableSSL ''add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;''}
        add_header Content-Security-Policy "upgrade-insecure-requests" always;
      '';
      
      virtualHosts = let
        activeSites = filterAttrs (n: v: v.enabled) wpCfg.sites;
        phpfpmSocket = name: "unix:${config.services.phpfpm.pools."wordpress-${name}".socket}";
      in
      mapAttrs (name: siteOpts: {
        serverName = name;
        forceSSL = cfg.enableSSL;
        enableACME = cfg.enableSSL;
        root = "/var/lib/wordpress/${name}/";
        
        extraConfig = ''
          access_log /var/log/nginx/${name}-access.log wpbox_enhanced;
          error_log /var/log/nginx/${name}-error.log warn;
          client_max_body_size ${siteOpts.nginx.client_max_body_size};
          client_body_buffer_size 128k;
          client_body_timeout 12s;
          client_header_timeout 12s;
          send_timeout 10s;
          fastcgi_buffers 16 16k;
          fastcgi_buffer_size 32k;
          fastcgi_connect_timeout 60s;
          fastcgi_send_timeout 180s;
          fastcgi_read_timeout 180s;
        '';
        
        locations = {
          
          "/" = {
            index = "index.php index.html";
            tryFiles = "$uri $uri/ /index.php?$args";
            extraConfig = ''
              limit_req zone=wp_general burst=40 nodelay;
              limit_req zone=wp_bots burst=5 nodelay;
              limit_req_status 429;
              more_set_headers "X-RateLimit-Zone: general";
              more_set_headers "X-RateLimit-Limit: 20r/s";
            '';
          };
          
          "~ \\.php$" = {
            extraConfig = ''
              try_files $uri =404;
              fastcgi_split_path_info ^(.+\.php)(/.+)$;
              fastcgi_pass ${phpfpmSocket name};
              fastcgi_index index.php;
              include ${pkgs.nginx}/conf/fastcgi.conf;
              fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
              fastcgi_param PATH_INFO $fastcgi_path_info;
              fastcgi_param HTTP_PROXY "";
              fastcgi_intercept_errors off;
              fastcgi_read_timeout ${toString siteOpts.php.max_execution_time}s;
              fastcgi_send_timeout ${toString siteOpts.php.max_execution_time}s;
              fastcgi_buffering on;
              fastcgi_buffers 16 16k;
              fastcgi_buffer_size 32k;
              limit_req zone=wp_general burst=20 nodelay;
              limit_req_status 429;
            '';
          };
          
          "~ ^/wp-admin/" = {
            index = "index.php";
            tryFiles = "$uri $uri/ /wp-admin/index.php?$args";
            extraConfig = ''
              limit_req zone=wp_admin burst=20 nodelay;
              limit_req_status 429;
              more_set_headers "X-RateLimit-Zone: wp-admin";
            '';
          };
          
          "~ ^/wp-json/" = {
            extraConfig = ''
              limit_req zone=wp_api burst=60 nodelay;
              limit_req_status 429;
              more_set_headers "X-RateLimit-Zone: wp-api";
              more_set_headers "X-RateLimit-Limit: 30r/s";
              try_files $uri $uri/ /index.php?$args;
            '';
          };
          
          "= /wp-admin/admin-ajax.php" = {
            extraConfig = ''
              limit_req zone=wp_api burst=60 nodelay;
              limit_req_status 429;
              fastcgi_pass ${phpfpmSocket name};
              include ${pkgs.nginx}/conf/fastcgi.conf;
              fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
              fastcgi_param HTTP_PROXY "";
            '';
          };
          
          "/wp-content/" = {
            alias = "/var/lib/wordpress/${name}/wp-content/";
            extraConfig = ''
              limit_req zone=wp_static burst=200 nodelay;
              expires 7d;
              log_not_found off;
              access_log off;
              location ~* ^/wp-content/.*\.php$ {
                deny all;
              }
              location ~* ^/wp-content/uploads/.*\.(php|phtml|php3|php4|php5|php7|phar|exe|pl|sh|py)$ {
                deny all;
              }
            '';
          };
          
          "~* \\.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot|webp|avif)$" = {
            extraConfig = ''
              limit_req zone=wp_static burst=200 nodelay;
              expires 1y;
              add_header Cache-Control "public, immutable";
              log_not_found off;
              access_log off;
              location ~* \.(woff|woff2|ttf|eot)$ {
                add_header Access-Control-Allow-Origin "*";
              }
            '';
          };
          
          "~ /\\." = {
            extraConfig = "deny all;";
          };
          
          "~ wp-config\\.php" = {
            extraConfig = "deny all;";
          };
          
          "~* \\.(bak|config|sql|fla|psd|ini|log|sh|inc|swp|dist|md|txt)$" = {
            extraConfig = "deny all;";
          };
          
          "= /xmlrpc.php" = {
            extraConfig = ''
              deny all;
            '';
          };
          
          "= /wp-login.php" = {
            extraConfig = ''
              limit_req zone=wp_login burst=3 nodelay;
              limit_req_status 429;
              access_log /var/log/nginx/${name}-login.log wpbox_enhanced;
              more_set_headers "X-RateLimit-Zone: login";
              more_set_headers "X-RateLimit-Limit: 5r/m";
              fastcgi_pass ${phpfpmSocket name};
              include ${pkgs.nginx}/conf/fastcgi.conf;
              fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
              fastcgi_param HTTP_PROXY "";
            '';
          };
          
          "= /wp-cron.php" = {
            extraConfig = ''
              allow 127.0.0.1;
              deny all;
            '';
          };
          
          "~* ^/(install|upgrade)\\.php$" = {
            extraConfig = "deny all;";
          };
          
          "~* ^/wp-includes/.*\\.php$" = {
            extraConfig = "deny all;";
          };
          
          "~* ^/(readme|license|changelog)\\.(html|txt)$" = {
            extraConfig = "deny all;";
          };
        } // siteOpts.nginx.custom_locations;
        
      }) activeSites;

      log_format = {
        wpbox_enhanced = '$remote_addr - $remote_user [$time_local] "$request" $status $body_bytes_sent "$http_referer" "$http_user_agent" rt=$request_time uct="$upstream_connect_time" uht="$upstream_header_time" urt="$upstream_response_time" cf_ip="$http_cf_connecting_ip" real_ip="$remote_addr"';
      };

      # Logrotate settings
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

      systemd.tmpfiles.rules = [
        "d /var/log/nginx 0755 nginx nginx - -"
        "d /var/spool/nginx 0750 nginx nginx -"
      ];
    };
  };
}
