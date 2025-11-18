{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.wpbox.nginx;
  wpCfg = config.services.wpbox.wordpress;
  secCfg = config.services.wpbox.security;
  
  # Cloudflare Real IP configuration
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
in
{
  config = mkIf (cfg.enable || wpCfg.enable) {
    
    # --- ACME CONFIGURATION (Global SSL Setup) ---
    security.acme = mkIf cfg.enableSSL {
      acceptTerms = true;
      defaults.email = cfg.acmeEmail;
    };
    
    # --- GLOBAL NGINX CONFIGURATION ---
    services.nginx = {
      enable = true;
      user = "nginx";
      group = "nginx";
      
      # Additional modules for enhanced functionality
      additionalModules = [ pkgs.nginxModules.moreheaders ];
      
      # Recommended settings
      recommendedProxySettings = true;
      recommendedTlsSettings = true;
      recommendedOptimisation = true;
      recommendedGzipSettings = true;
      recommendedBrotliSettings = mkIf cfg.enableBrotli true;
      
      # Enhanced TLS configuration
      sslCiphers = "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384";
      sslProtocols = "TLSv1.2 TLSv1.3";
      
      # Common HTTP configuration
      commonHttpConfig = ''
        # Proxy settings
        proxy_headers_hash_max_size 2048;
        proxy_headers_hash_bucket_size 128;
        
        ${optionalString cfg.enableCloudflareRealIP ''
        # Cloudflare Real IP detection
        ${realIpsFromList cfipv4}
        ${realIpsFromList cfipv6}
        real_ip_header CF-Connecting-IP;
        ''}
        
        # ====================================
        # MAP-BASED RATE LIMITING CONFIGURATION
        # ====================================
        
        # 1. MAP IP -> Limit key
        # Internal IPs get empty key (no limit), external get rate limited
        map $remote_addr $wp_limit_key {
            default $binary_remote_addr;     
            ~^100\.64\. "";                   # Tailscale CGNAT
            ~^127\.0\.0\. "";                 # Localhost
            ~^::1$ "";                        # IPv6 localhost
            ~^10\. "";                        # Private 10.x
            ~^172\.(1[6-9]|2[0-9]|3[01])\. ""; # Private 172.16-31.x
            ~^192\.168\. "";                  # Private 192.168.x
        }
        
        # 2. Login Map (more restrictive)
        map $remote_addr $wp_login_limit_key {
            default $binary_remote_addr;      # External: normal limit
            ~^100\.64\. "internal_net";       # Internal: higher limit
            ~^127\.0\.0\. "internal_net";
            ~^10\. "internal_net";
            ~^172\.(1[6-9]|2[0-9]|3[01])\. "internal_net";
            ~^192\.168\. "internal_net";
        }
        
        # 3. Bot detection map
        map $http_user_agent $is_bot {
            default 0;
            ~*bot 1;
            ~*crawler 1;
            ~*spider 1;
            ~*scraper 1;
            ~*wget 1;
            ~*curl 1;
            ~*python 1;
        }
        
        # 4. Combined key: BOT + IP
        map "$is_bot:$remote_addr" $bot_limit_key {
            default "";                       # Non-bot: no special limit
            ~^1: $binary_remote_addr;         # Bot: apply limit
        }
        
        # 5. WordPress API detection (REST API, AJAX)
        map $request_uri $is_wp_api {
            default 0;
            ~^/wp-json/ 1;
            ~^/wp-admin/admin-ajax\.php 1;
        }
        
        # API limit key (conditional)
        map "$is_wp_api:$wp_limit_key" $wp_api_limit_key {
            default "";                       # Non-API or internal: no limit
            ~^1:(.+)$ $1;                     # API from external: use IP
        }
        
        # ====================================
        # RATE LIMIT ZONES DEFINITION
        # ====================================
        
        # General zone (20 req/s per external IP)
        limit_req_zone $wp_limit_key zone=wp_general:10m rate=20r/s;
        
        # Login zone (5 req/min external, 20 req/min internal)
        limit_req_zone $wp_login_limit_key zone=wp_login:10m rate=5r/m;
        
        # Bot zone (2 req/s for identified bots)
        limit_req_zone $bot_limit_key zone=wp_bots:10m rate=2r/s;
        
        # Static files zone (100 req/s)
        limit_req_zone $wp_limit_key zone=wp_static:10m rate=100r/s;
        
        # XMLRPC zone (1 req/s - very restrictive)
        limit_req_zone $binary_remote_addr zone=wp_xmlrpc:10m rate=1r/s;
        
        # WordPress API zone (30 req/s for external only)
        limit_req_zone $wp_api_limit_key zone=wp_api:10m rate=30r/s;
        
        # Admin area zone (10 req/s)
        limit_req_zone $wp_limit_key zone=wp_admin:10m rate=10r/s;
        
        # ====================================
        # HSTS HEADER MAP
        # ====================================
        
        # HSTS header (only on HTTPS)
        map $scheme $hsts_header {
            ${if cfg.enableHSTSPreload 
              then ''https "max-age=31536000; includeSubDomains; preload";''
              else ''https "max-age=31536000; includeSubDomains";''}
            default "";
        }
        
        # ====================================
        # LOGGING FORMAT
        # ====================================
        
        log_format wpbox_enhanced '$remote_addr - $remote_user [$time_local] '
                                  '"$request" $status $body_bytes_sent '
                                  '"$http_referer" "$http_user_agent" '
                                  'rt=$request_time '
                                  'uct="$upstream_connect_time" '
                                  'uht="$upstream_header_time" '
                                  'urt="$upstream_response_time" '
                                  ${optionalString cfg.enableCloudflareRealIP ''"cf_ip=\"$http_cf_connecting_ip\" "''}
                                  'real_ip="$remote_addr"';
      '';

      # Global security headers
      appendHttpConfig = ''
        # Enhanced security headers
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-XSS-Protection "1; mode=block" always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;
        add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;
        ${optionalString cfg.enableSSL ''add_header Strict-Transport-Security $hsts_header always;''}
        
        # Content Security Policy for WordPress (adjust as needed)
        add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self' data:; connect-src 'self';" always;
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
          
          # SSL Configuration (Global)
          forceSSL = cfg.enableSSL;
          enableACME = cfg.enableSSL;
          
          # Root points to the Nix store (immutable WordPress core)
          root = "${config.services.wordpress.sites.${name}.package}/share/wordpress";
          
          # Per-site configuration
          extraConfig = ''
            # Enhanced logging per site
            access_log /var/log/nginx/${name}-access.log wpbox_enhanced;
            error_log /var/log/nginx/${name}-error.log warn;
            
            # Upload limits
            client_max_body_size ${siteOpts.nginx.client_max_body_size};
            client_body_buffer_size 128k;
            
            # Timeouts
            client_body_timeout 12s;
            client_header_timeout 12s;
            send_timeout 10s;
            
            # FastCGI tuning
            fastcgi_buffers 16 16k;
            fastcgi_buffer_size 32k;
            fastcgi_connect_timeout 60s;
            fastcgi_send_timeout 180s;
            fastcgi_read_timeout 180s;
          '';
          
          locations = {
            
            # --- ROOT: PHP HANDLER ---
            "/" = {
              index = "index.php index.html";
              tryFiles = "$uri $uri/ /index.php?$args";
              extraConfig = ''
                # General rate limiting
                limit_req zone=wp_general burst=40 nodelay;
                limit_req zone=wp_bots burst=5 nodelay;
                limit_req_status 429;
                
                # Rate limit headers for debugging
                more_set_headers "X-RateLimit-Zone: general";
                more_set_headers "X-RateLimit-Limit: 20r/s";
              '';
            };
            
            # --- PHP EXECUTION ---
            "~ \\.php$" = {
              extraConfig = ''
                # Security: Block access to any other .php files in root
                try_files $uri =404;
                
                fastcgi_split_path_info ^(.+\.php)(/.+)$;
                fastcgi_pass ${phpfpmSocket name};
                fastcgi_index index.php;
                include ${pkgs.nginx}/conf/fastcgi.conf;
                fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
                fastcgi_param PATH_INFO $fastcgi_path_info;
                
                # Enhanced FastCGI params for WordPress
                fastcgi_param HTTP_PROXY "";  # HTTPoxy mitigation
                fastcgi_intercept_errors off;
                
                # Timeouts
                fastcgi_read_timeout ${toString siteOpts.php.max_execution_time}s;
                fastcgi_send_timeout ${toString siteOpts.php.max_execution_time}s;
                
                # Buffering
                fastcgi_buffering on;
                fastcgi_buffers 16 16k;
                fastcgi_buffer_size 32k;
                
                # Rate limiting for PHP execution
                limit_req zone=wp_general burst=20 nodelay;
                limit_req_status 429;
              '';
            };
            
            # --- WORDPRESS ADMIN AREA ---
            "~ ^/wp-admin/" = {
              index = "index.php";
              tryFiles = "$uri $uri/ /wp-admin/index.php?$args";
              extraConfig = ''
                # Stricter rate limiting for admin area
                limit_req zone=wp_admin burst=20 nodelay;
                limit_req_status 429;
                
                more_set_headers "X-RateLimit-Zone: wp-admin";
              '';
            };
            
            # --- WORDPRESS REST API ---
            "~ ^/wp-json/" = {
              extraConfig = ''
                # API rate limiting
                limit_req zone=wp_api burst=60 nodelay;
                limit_req_status 429;
                
                more_set_headers "X-RateLimit-Zone: wp-api";
                more_set_headers "X-RateLimit-Limit: 30r/s";
                
                try_files $uri $uri/ /index.php?$args;
              '';
            };
            
            # --- WORDPRESS AJAX ---
            "= /wp-admin/admin-ajax.php" = {
              extraConfig = ''
                # API rate limiting for AJAX
                limit_req zone=wp_api burst=60 nodelay;
                limit_req_status 429;
                
                fastcgi_pass ${phpfpmSocket name};
                include ${pkgs.nginx}/conf/fastcgi.conf;
                fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
                fastcgi_param HTTP_PROXY "";
              '';
            };
            
            # --- MUTABLE WP-CONTENT (outside Nix Store) ---
            "/wp-content/" = {
              alias = "/var/lib/wordpress/${name}/wp-content/";
              extraConfig = ''
                # Static file rate limiting (generous)
                limit_req zone=wp_static burst=200 nodelay;
                
                expires 7d;
                log_not_found off;
                access_log off;
                
                # Security: Deny PHP execution in wp-content
                location ~* ^/wp-content/.*\.php$ {
                  deny all;
                }
                
                # Extra protection for uploads
                location ~* ^/wp-content/uploads/.*\.(php|phtml|php3|php4|php5|php7|phar|exe|pl|sh|py)$ {
                  deny all;
                }
              '';
            };

            # --- STATIC ASSETS CACHING ---
            "~* \\.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot|webp|avif)$" = {
              extraConfig = ''
                # Generous rate limit for static files
                limit_req zone=wp_static burst=200 nodelay;
                
                expires 1y;
                add_header Cache-Control "public, immutable";
                log_not_found off;
                access_log off;
                
                # CORS for fonts (if needed)
                location ~* \.(woff|woff2|ttf|eot)$ {
                  add_header Access-Control-Allow-Origin "*";
                }
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
            
            # --- SECURITY: BLOCK SENSITIVE FILES ---
            "~* \\.(bak|config|sql|fla|psd|ini|log|sh|inc|swp|dist|md|txt)$" = {
              extraConfig = "deny all;";
            };
            
            # --- WORDPRESS XMLRPC (disabled by default) ---
            "= /xmlrpc.php" = {
              extraConfig = ''
                # Completely disable XMLRPC (recommended)
                deny all;
              '';
            };

            # --- WORDPRESS LOGIN (heavily rate limited) ---
            "= /wp-login.php" = {
              extraConfig = ''
                # Strict rate limiting for login
                limit_req zone=wp_login burst=3 nodelay;
                limit_req_status 429;
                
                # Log all login attempts
                access_log /var/log/nginx/${name}-login.log wpbox_enhanced;
                
                more_set_headers "X-RateLimit-Zone: login";
                more_set_headers "X-RateLimit-Limit: 5r/m";
                
                fastcgi_pass ${phpfpmSocket name};
                include ${pkgs.nginx}/conf/fastcgi.conf;
                fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
                fastcgi_param HTTP_PROXY "";
              '';
            };
            
            # --- WORDPRESS CRON (internal only) ---
            "= /wp-cron.php" = {
              extraConfig = ''
                # Allow only from localhost (if using system cron)
                allow 127.0.0.1;
                deny all;
              '';
            };
            
            # --- BLOCK WORDPRESS INSTALL/UPGRADE ---
            "~* ^/(install|upgrade)\\.php$" = {
              extraConfig = "deny all;";
            };
            
            # --- BLOCK ACCESS TO SENSITIVE WORDPRESS DIRECTORIES ---
            "~* ^/wp-includes/.*\\.php$" = {
              extraConfig = ''
                # Block direct access to PHP files in wp-includes
                deny all;
              '';
            };
            
            # --- README AND LICENSE FILES ---
            "~* ^/(readme|license|changelog)\\.(html|txt)$" = {
              extraConfig = "deny all;";
            };
            
          } // siteOpts.nginx.custom_locations;
          
        }) activeSites;
    };

    # --- LOG ROTATION ---
    services.logrotate = {
      enable = true;
      settings = {
        "/var/log/nginx/*.log" = {
          frequency = "daily";
          rotate = 14;
          compress = true;
          delaycompress = true;
          notifempty = true;
          missingok = true;
          sharedscripts = true;
          postrotate = ''
            ${pkgs.systemd}/bin/systemctl reload nginx.service > /dev/null 2>&1 || true
          '';
        };
      };
    };

    # --- CREATE LOG DIRECTORIES ---
    systemd.tmpfiles.rules = [
      "d /var/log/nginx 0755 nginx nginx - -"
      "d /var/spool/nginx 0750 nginx nginx -"
    ];
  };
}
