{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.wpbox;
  wpCfg = config.services.wpbox.wordpress;

  parseSitesFromFile = filePath:
    if filePath != null && builtins.pathExists filePath then
      let
        jsonContent = builtins.fromJSON (builtins.readFile filePath);
      in
        listToAttrs (map (site: {
          name = site.domain;
          value = site // {
            ssl = site.ssl or {
              forceSSL = cfg.nginx.enableSSL;
              enabled = cfg.nginx.enableSSL;
            };
          };
        }) jsonContent.sites)
    else
      {};

  sitesFromConfig = 
    if wpCfg.sitesFile != null then
      parseSitesFromFile wpCfg.sitesFile
    else
      wpCfg.sites;

  activeSites = filterAttrs (n: v: v.enabled) sitesFromConfig;
  sanitizeName = name: replaceStrings ["." "-"] ["_" "_"] name;
in
{
  config = mkIf (cfg.enable && wpCfg.enable) {
    
    services.wpbox.wordpress.sites = mkDefault sitesFromConfig;

    assertions = [
      {
        assertion = wpCfg.sitesFile != null -> builtins.pathExists wpCfg.sitesFile;
        message = "services.wpbox.wordpress.sitesFile must point to an existing file";
      }
      {
        assertion = (wpCfg.sitesFile == null) -> (wpCfg.sites != {});
        message = "Either services.wpbox.wordpress.sitesFile or services.wpbox.wordpress.sites must be configured";
      }
    ];

    services.wordpress = {
      webserver = "nginx";
      sites = mapAttrs (name: siteOpts: {
        package = mkDefault wpCfg.package;
        database = {
          createLocally = true;
          name = "wp_${sanitizeName name}";
          user = "wordpress";
          passwordFile = mkDefault null;
          host = "localhost";
        };
        poolConfig = {
          "listen.owner" = "nginx";
          "listen.group" = "nginx";
        };
        extraConfig = ''
          define( 'WP_CONTENT_DIR', '/var/lib/wordpress/${name}/wp-content' );
          define( 'WP_CONTENT_URL', 'https://${name}/wp-content' );
          define( 'UPLOADS', 'wp-content/uploads' );
          define( 'FS_METHOD', 'direct' );
          define( 'WP_MEMORY_LIMIT', '${siteOpts.php.memory_limit or wpCfg.defaults.phpMemoryLimit}' );
          define( 'WP_MAX_MEMORY_LIMIT', '512M' );
          define( 'WP_CACHE', true );
          define( 'WP_DEBUG', ${if (siteOpts.wordpress.debug or false) then "true" else "false"} );
          ${siteOpts.wordpress.extra_config or ""}
        '';
      }) activeSites;
    };

    users.groups.wordpress = {
      members = [ "wordpress" "nginx" ];
    };

    systemd.tmpfiles.rules = 
      [ "d /var/lib/wordpress 0755 wordpress wordpress - -" ] ++
      flatten (mapAttrsToList (name: _: [
        "d '/var/lib/wordpress/${name}' 0750 wordpress nginx - -"
        "d '/var/lib/wordpress/${name}/wp-content' 0750 wordpress nginx - -"
        "d '/var/lib/wordpress/${name}/wp-content/uploads' 0770 wordpress nginx - -"
        "d '/var/lib/wordpress/${name}/wp-content/cache' 0770 wordpress nginx - -"
        "f '/var/lib/wordpress/${name}/wp-content/debug.log' 0660 wordpress nginx - -"
      ]) activeSites);

    systemd.services = mapAttrs' (name: siteOpts:
    let
      protocol = if (siteOpts.ssl.enabled or cfg.nginx.enableSSL) then "https" else "http";
    in
      nameValuePair "wordpress-cron-${name}" {
        description = "WordPress Cron for ${name}";
        after = [ "network.target" "mysql.service" ];
        serviceConfig = {
          Type = "oneshot";
          User = "wordpress";
          Group = "wordpress";
          ExecStart = "${pkgs.curl}/bin/curl -s -o /dev/null ${protocol}://${name}/wp-cron.php?doing_wp_cron";
        };
      }
    ) activeSites;

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

    services.wpbox.mariadb.enable = mkDefault true;
    services.wpbox.nginx.enable = mkDefault true;
    services.wpbox.phpfpm.enable = mkDefault true;
  };
}