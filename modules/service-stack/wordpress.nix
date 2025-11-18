{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.wpbox;

  # Usa il path custom passato o errore esplicativo
  sitesFilePath =
    if cfg.sitesFile != null && builtins.pathExists cfg.sitesFile 
    then cfg.sitesFile
    else throw "Error: services.wpbox.sitesFile non esiste o non è configurato correttamente";

  sitesJson = builtins.fromJSON (builtins.readFile sitesFilePath);
  sitesFromJson = listToAttrs (map (site: {
    name = site.domain;
    value = site;
  }) sitesJson.sites);

  activeSites = filterAttrs (n: v: v.enabled) sitesFromJson;
in
{
  config = mkIf cfg.enable {

    # Propaga l’attributo custom che potresti voler usare in altri moduli
    services.wpbox.wordpress.sites = sitesFromJson;

    services.wordpress.webserver = "none";

    services.wordpress.sites = mapAttrs (name: siteOpts: {
      package = mkDefault cfg.wordpress.package;

      database = {
        createLocally = true;
        name = "wp_${replaceStrings ["."] ["_"] name}";
        user = "wp_${replaceStrings ["."] ["_"] name}";
        # socket auth locale
      };

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

    # MUTABLE DIRECTORIES/GESTIONE OWNER/GROUP
    systemd.tmpfiles.rules = flatten (
      mapAttrsToList (name: _: [
        "d '/var/lib/wordpress/${name}' 0755 wordpress nginx - -"
        "d '/var/lib/wordpress/${name}/wp-content' 0755 wordpress nginx - -"
        "d '/var/lib/wordpress/${name}/wp-content/plugins' 0755 wordpress nginx - -"
        "d '/var/lib/wordpress/${name}/wp-content/themes' 0755 wordpress nginx - -"
        "d '/var/lib/wordpress/${name}/wp-content/uploads' 0755 wordpress nginx - -"
        "d '/var/lib/wordpress/${name}/wp-content/upgrade' 0755 wordpress nginx - -"
      ]) activeSites
    );

    # MARIADB AUTO-ENABLE fallback se nessun altro modulo la abilita
    services.wpbox.mariadb = {
      enable = mkDefault true;
      package = mkDefault pkgs.mariadb;
    };
  };
}
