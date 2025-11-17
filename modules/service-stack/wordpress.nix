{ config, pkgs, lib, ... }:

with lib;

let

  cfg = config.services.wpbox;

  # Load sites from JSON
  sitesJson = builtins.fromJSON (builtins.readFile ./sites.json);
  globalConfig = sitesJson.global;
  
  # Convert JSON sites array to attrset keyed by domain
  sitesFromJson = listToAttrs (map (site: {
    name = site.domain;
    value = {
      enabled = site.enabled;
      ssl = site.ssl;
      php = site.php;
      nginx = site.nginx;
      wordpress = site.wordpress;
    };
  }) sitesJson.sites);

  activeSites = filterAttrs (n: v: v.enabled) cfg.wordpress.sites;

in
{
  

  # ################################################
  # ##             CONFIGURATION                  ##
  # ################################################

  config.services.wpbox.wordpress.sites = sitesFromJson;

  config = mkIf cfg.enable {


    # --- WORDPRESS CORE CONFIG ---
    # IMPORTANT: Set webserver to "none" because nginx.nix manages it
    services.wordpress.webserver = "none";

    services.wordpress.sites = mapAttrs (name: siteOpts: {
        package = mkDefault cfg.package;
          
          # --- DATABASE CONFIGURATION ---
        database = {
          createLocally = true;
          name = "wp_${replaceStrings ["."] ["_"] name}";
          user = "wp_${replaceStrings ["."] ["_"] name}";
        };

        # --- PHP POOL CONFIGURATION ---
        # Pool settings are managed by php-fpm.nix
        # We just specify the pool name here
        poolConfig = {
          # Minimal config - actual pool managed by php-fpm.nix
          "listen.owner" = "nginx";
          "listen.group" = "nginx";
        };

        # --- WP-CONFIG ---
        extraConfig = ''
          /* --- WPBOX HYBRID CONFIG --- */
          define( 'WP_CONTENT_DIR', '/var/lib/wordpress/${name}/wp-content' );
          define( 'WP_CONTENT_URL', 'https://${name}/wp-content' );
          define( 'WP_PLUGIN_DIR', '/var/lib/wordpress/${name}/wp-content/plugins' );
          define( 'WP_PLUGIN_URL', 'https://${name}/wp-content/plugins' );
          define( 'FS_METHOD', 'direct' );
          
          /* Memory Tuning */
          define( 'WP_MEMORY_LIMIT', '${siteOpts.php.memory_limit}' );
          define( 'WP_MAX_MEMORY_LIMIT', '512M' );

          /* Security */
          define( 'DISALLOW_FILE_EDIT', true );
          define( 'FORCE_SSL_ADMIN', ${if siteOpts.ssl.forceSSL then "true" else "false"} );

          /* Debug Mode */
          define( 'WP_DEBUG', ${if siteOpts.wordpress.debug then "true" else "false"} );
          ${optionalString siteOpts.wordpress.debug ''
            define( 'WP_DEBUG_LOG', true );
            define( 'WP_DEBUG_DISPLAY', false );
          ''}

          /* Auto-Updates */
          define( 'AUTOMATIC_UPDATER_DISABLED', ${if siteOpts.wordpress.auto_update then "false" else "true"} );

          /* User Extra Config */
          ${siteOpts.wordpress.extra_config}
        '';

      }) activeSites;

      # --- MUTABLE DIRECTORIES ---
      systemd.tmpfiles.rules = flatten (
        mapAttrsToList (name: siteOpts: [
          "d '/var/lib/wordpress/${name}' 0755 wordpress nginx - -"
          "d '/var/lib/wordpress/${name}/wp-content' 0755 wordpress nginx - -"
          "d '/var/lib/wordpress/${name}/wp-content/plugins' 0755 wordpress nginx - -"
          "d '/var/lib/wordpress/${name}/wp-content/themes' 0755 wordpress nginx - -"
          "d '/var/lib/wordpress/${name}/wp-content/uploads' 0755 wordpress nginx - -"
          "d '/var/lib/wordpress/${name}/wp-content/upgrade' 0755 wordpress nginx - -"
        ]) activeSites
      );

      # --- MYSQL AUTO-CONFIGURATION ---
      services.mysql = {
        enable = mkDefault true;
        package = mkDefault pkgs.mysql;
      };
    }
}
