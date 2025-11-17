{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.wpbox;
  # ... parsing logic remains same (omitted for brevity, assume sitesFromJson exists) ...
  # Load sites from JSON
  sitesJson = builtins.fromJSON (builtins.readFile cfg.sitesFile);
  sitesFromJson = listToAttrs (map (site: {
    name = site.domain;
    value = site;
  }) sitesJson.sites);

  activeSites = filterAttrs (n: v: v.enabled) cfg.wordpress.sites;
in
{
  # Inject parsed sites into config
  config.services.wpbox.wordpress.sites = sitesFromJson;

  config = mkIf cfg.enable {
    
    services.wordpress.webserver = "none";

    services.wordpress.sites = mapAttrs (name: siteOpts: {
        package = mkDefault cfg.wordpress.package;
        
        # --- DATABASE CONFIGURATION ---
        database = {
          createLocally = true;
          name = "wp_${replaceStrings ["."] ["_"] name}";
          user = "wp_${replaceStrings ["."] ["_"] name}";
          # Socket auth works out of the box with MariaDB local
        };

        # ... poolConfig, extraConfig etc. remain same ...
        poolConfig = {
          "listen.owner" = "nginx";
          "listen.group" = "nginx";
        };

        extraConfig = ''
          /* --- WPBOX HYBRID CONFIG --- */
          define( 'WP_CONTENT_DIR', '/var/lib/wordpress/${name}/wp-content' );
          define( 'WP_CONTENT_URL', 'https://${name}/wp-content' );
          define( 'WP_PLUGIN_DIR', '/var/lib/wordpress/${name}/wp-content/plugins' );
          define( 'WP_PLUGIN_URL', 'https://${name}/wp-content/plugins' );
          define( 'FS_METHOD', 'direct' );
          
          define( 'WP_MEMORY_LIMIT', '${siteOpts.php.memory_limit}' );
          define( 'WP_MAX_MEMORY_LIMIT', '512M' );
          define( 'DISALLOW_FILE_EDIT', true );
          define( 'FORCE_SSL_ADMIN', ${if siteOpts.ssl.forceSSL then "true" else "false"} );
          define( 'WP_DEBUG', ${if siteOpts.wordpress.debug then "true" else "false"} );
          ${optionalString siteOpts.wordpress.debug ''
            define( 'WP_DEBUG_LOG', true );
            define( 'WP_DEBUG_DISPLAY', false );
          ''}
          define( 'AUTOMATIC_UPDATER_DISABLED', ${if siteOpts.wordpress.auto_update then "false" else "true"} );
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

    # --- MARIADB AUTO-INIT ---
    # If WPBox is enabled, we default enable MariaDB unless explicitly disabled
    services.wpbox.mariadb = {
      enable = mkDefault true;
      package = mkDefault pkgs.mariadb;
    };
  };
}