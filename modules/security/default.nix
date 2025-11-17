{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.wordpress;
  
  # Importiamo le regole di hardening dal file separato
  hardeningRules = import ../security/systemd-hardening.nix { inherit lib; };
in
{
  # Opzioni custom extra
  options.services.wordpress = {
    enableHardening = mkEnableOption "Systemd security hardening for WP pools";
  };

  config = mkIf (cfg.sites != {}) {

    # 1. Default Webserver
    services.wordpress.webserver = mkDefault "nginx";

    # 2. Configurazione Globale Nginx
    services.nginx = {
      enable = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;
      recommendedOptimisation = true;
      recommendedGzipSettings = true;
    };

    # 3. Injection per "Hybrid Mode" (Path Mutabili)
    services.wordpress.sites = mapAttrs (hostName: siteCfg: {
      
      package = mkDefault pkgs.wordpress;

      # Override NGINX per mappare la cartella mutabile
      virtualHost = {
        locations."/wp-content/" = {
          alias = "/var/lib/wordpress/${hostName}/wp-content/";
          extraConfig = ''
            expires max;
            log_not_found off;
            access_log off;
          '';
        };
        
        # Security Nginx di base
        locations."~* /(?:uploads|files)/.*\\.php$".extraConfig = "deny all;";
        locations."~ /\\.".extraConfig = "deny all;";
      };

      # Injection WP-CONFIG
      extraConfig = ''
        /* --- HYBRID MODE CONFIGURATION --- */
        define( 'WP_CONTENT_DIR', '/var/lib/wordpress/${hostName}/wp-content' );
        define( 'WP_CONTENT_URL', 'https://${hostName}/wp-content' );
        define( 'WP_PLUGIN_DIR', '/var/lib/wordpress/${hostName}/wp-content/plugins' );
        define( 'WP_PLUGIN_URL', 'https://${hostName}/wp-content/plugins' );
        define( 'WP_THEME_DIR', '/var/lib/wordpress/${hostName}/wp-content/themes' );
        define( 'WP_THEME_URL', 'https://${hostName}/wp-content/themes' );
        define( 'FS_METHOD', 'direct' );
      '';

    }) cfg.sites;

    # 4. Applicazione Hardening Systemd
    services.phpfpm.pools = mkIf config.services.wordpress.enableHardening (
      mapAttrs' (hostName: siteCfg: 
        nameValuePair "wordpress-${hostName}" {
          phpOptions = ''
            expose_php = Off
            allow_url_fopen = On
            display_errors = Off
            log_errors = On
          '';
          
          # Mergia le regole esterne con i path specifici di WP
          serviceConfig = hardeningRules.php-fpm // {
             ReadWritePaths = [ 
               "/var/lib/wordpress/${hostName}" 
               "/run/phpfpm"
               "/run/mysqld" # Importante se usa socket locale
             ];
             BindReadOnlyPaths = [ 
               "/nix/store" 
               "/etc/ssl"
               "/run/secrets" # Se usi passwordFile
             ];
          };
        }
      ) cfg.sites
    );

    # 5. Creazione Directory Mutabili
    systemd.tmpfiles.rules = flatten (mapAttrsToList (hostName: siteCfg: [
      "d '/var/lib/wordpress/${hostName}/wp-content' 0755 wordpress nginx - -"
      "d '/var/lib/wordpress/${hostName}/wp-content/plugins' 0755 wordpress nginx - -"
      "d '/var/lib/wordpress/${hostName}/wp-content/themes' 0755 wordpress nginx - -"
      "d '/var/lib/wordpress/${hostName}/wp-content/uploads' 0755 wordpress nginx - -"
      "d '/var/lib/wordpress/${hostName}/wp-content/upgrade' 0755 wordpress nginx - -"
    ]) cfg.sites);
  };
}