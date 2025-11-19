{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.wpbox;
  wpCfg = config.services.wpbox.wordpress;

  # Parse sites from JSON file
  parseSitesFromFile = filePath:
    if filePath != null && builtins.pathExists filePath then
      let
        jsonContent = builtins.fromJSON (builtins.readFile filePath);
      in
        listToAttrs (map (site: {
          name = site.domain;
          value = site // {
            # Add default SSL config if missing
            ssl = site.ssl or {
              forceSSL = cfg.nginx.enableSSL;
              enabled = cfg.nginx.enableSSL;
            };
          };
        }) jsonContent.sites)
    else
      {};

  # Get sites either from file or from direct config
  sitesFromConfig = 
    if wpCfg.sitesFile != null then
      parseSitesFromFile wpCfg.sitesFile
    else
      wpCfg.sites; # Questa opzione è ora definita e usata da interface.nix

  # Filter only enabled sites
  activeSites = filterAttrs (n: v: v.enabled) sitesFromConfig;

  # Helper to sanitize domain names for database names
  sanitizeName = name: replaceStrings ["." "-"] ["_" "_"] name;
in
{

  config = mkIf (cfg.enable && wpCfg.enable) {
    # Set parsed sites to the sites option for use by other modules
    services.wpbox.wordpress.sites = mkDefault sitesFromConfig;

    # Assertions for configuration validation
    assertions = [
      {
        assertion = wpCfg.sitesFile != null -> builtins.pathExists wpCfg.sitesFile;
        message = "services.wpbox.wordpress.sitesFile must point to an existing file";
      }
      {
        assertion = (wpCfg.sitesFile == null) -> (wpCfg.sites != {});
        message = "Either services.wpbox.wordpress.sitesFile or services.wpbox.wordpress.sites must be configured";
      }
      {
        assertion = all (site: site ? domain && site ? enabled) (attrValues sitesFromConfig);
        message = "All sites in configuration must have 'domain' and 'enabled' fields";
      }
      {
        assertion = all (site: site ? php) (attrValues sitesFromConfig);
        message = "All sites must have 'php' configuration block";
      }
    ];

    # WordPress service configuration
    services.wordpress = {
      webserver = "nginx"; 
      
      sites = mapAttrs (name: siteOpts: {
        package = mkDefault wpCfg.package;
        
        database = {
          createLocally = true;
          name = "wp_${sanitizeName name}";
          user = "wp_${sanitizeName name}";
          passwordFile = mkDefault null; # Uses socket auth
          host = "localhost";
        };

        poolConfig = {
          "listen.owner" = "nginx";
          "listen.group" = "nginx";
        };

        extraConfig = ''
          /* === WPBox Managed WordPress Configuration === */
          
          /* Content Directories */
          define( 'WP_CONTENT_DIR', '/var/lib/wordpress/${name}/wp-content' );
          define( 'WP_CONTENT_URL', 'https://${name}/wp-content' );
          define( 'WP_PLUGIN_DIR', '/var/lib/wordpress/${name}/wp-content/plugins' );
          define( 'WP_PLUGIN_URL', 'https://${name}/wp-content/plugins' );
          define( 'UPLOADS', 'wp-content/uploads' );
          
          /* File System */
          define( 'FS_METHOD', 'direct' );
          define( 'FS_CHMOD_DIR', 0755 );
          define( 'FS_CHMOD_FILE', 0644 );
          
          /* Memory Limits */
          define( 'WP_MEMORY_LIMIT', '${siteOpts.php.memory_limit or wpCfg.defaults.phpMemoryLimit}' );
          define( 'WP_MAX_MEMORY_LIMIT', '512M' );
          
          /* Security */
          define( 'DISALLOW_FILE_EDIT', true );
          define( 'DISALLOW_FILE_MODS', false );
          define( 'FORCE_SSL_ADMIN', ${if (siteOpts.ssl.forceSSL or cfg.nginx.enableSSL) then "true" else "false"} );
          define( 'COOKIE_SECURE', ${if cfg.nginx.enableSSL then "true" else "false"} );
          
          /* Performance */
          define( 'WP_CACHE', true );
          define( 'COMPRESS_CSS', true );
          define( 'COMPRESS_SCRIPTS', true );
          define( 'CONCATENATE_SCRIPTS', false );
          define( 'EMPTY_TRASH_DAYS', 30 );
          
          /* Debug Settings */
          define( 'WP_DEBUG', ${if (siteOpts.wordpress.debug or false) then "true" else "false"} );
          ${optionalString (siteOpts.wordpress.debug or false) ''
            define( 'WP_DEBUG_LOG', true );
            define( 'WP_DEBUG_DISPLAY', false );
            define( 'SCRIPT_DEBUG', true );
            define( 'SAVEQUERIES', true );
            @ini_set( 'log_errors', 'On' );
            @ini_set( 'display_errors', 'Off' );
            @ini_set( 'error_log', '/var/lib/wordpress/${name}/wp-content/debug.log' );
          ''}
          
          /* Updates */
          define( 'AUTOMATIC_UPDATER_DISABLED', ${if (siteOpts.wordpress.auto_update or false) then "false" else "true"} );
          define( 'WP_AUTO_UPDATE_CORE', ${if (siteOpts.wordpress.auto_update or false) then "'minor'" else "false"} );
          
          /* Misc */
          define( 'WP_POST_REVISIONS', 10 );
          define( 'AUTOSAVE_INTERVAL', 60 );
          define( 'WP_CRON_LOCK_TIMEOUT', 60 );
          
          /* Custom Configuration */
          ${siteOpts.wordpress.extra_config or ""}
        '';
      }) activeSites;
    };

    # System users and groups
    users.users.wordpress = {
      isSystemUser = true;
      group = "wordpress";
      home = "/var/lib/wordpress";
      createHome = false;
    };
    users.groups.wordpress = {
      members = [ "wordpress" "nginx" ];
    };

    # Directory structure and permissions
    systemd.tmpfiles.rules = 
      [ "d /var/lib/wordpress 0755 wordpress wordpress - -" ] ++
      flatten (mapAttrsToList (name: _: [
        "d '/var/lib/wordpress/${name}' 0750 wordpress nginx - -"
        "d '/var/lib/wordpress/${name}/wp-content' 0750 wordpress nginx - -"
        "d '/var/lib/wordpress/${name}/wp-content/plugins' 0750 wordpress nginx - -"
        "d '/var/lib/wordpress/${name}/wp-content/themes' 0750 wordpress nginx - -"
        "d '/var/lib/wordpress/${name}/wp-content/uploads' 0770 wordpress nginx - -"
        "d '/var/lib/wordpress/${name}/wp-content/upgrade' 0770 wordpress nginx - -"
        "d '/var/lib/wordpress/${name}/wp-content/cache' 0770 wordpress nginx - -"
        "d '/var/lib/wordpress/${name}/wp-content/w3tc-config' 0770 wordpress nginx - -"
        "f '/var/lib/wordpress/${name}/wp-content/debug.log' 0660 wordpress nginx - -"
      ]) activeSites);

    # WordPress cron jobs (real cron instead of wp-cron.php)
    systemd.services = mapAttrs' (name: siteOpts:
      nameValuePair "wordpress-cron-${name}" {
        description = "WordPress Cron for ${name}";
        after = [ "network.target" "mysql.service" ];
        serviceConfig = {
          Type = "oneshot";
          User = "wordpress";
          Group = "wordpress";
          ExecStart = "${pkgs.curl}/bin/curl -s -o /dev/null https://${name}/wp-cron.php?doing_wp_cron";
        };
      }
    ) activeSites;

    # Cron timers
    systemd.timers = mapAttrs' (name: _:
      nameValuePair "wordpress-cron-${name}" {
        description = "WordPress Cron Timer for ${name}";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "5min";
          OnUnitActiveSec = "5min";
          Persistent = true;
        };
      }
    ) activeSites;

    # Enable required services
    services.wpbox.mariadb = {
      enable = mkDefault true;
    };

    services.wpbox.nginx = {
      enable = mkDefault true;
    };

    services.wpbox.phpfpm = {
      enable = mkDefault true;
    };
  };
}