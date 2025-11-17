{ config, pkgs, lib, ... }:

with lib;

{

  options.services.wpbox.phpfpm = {
     enable = mkEnableOption "WpBox PHP-FPM Manager";
  };
  
  config = mkIf config.services.wpbox.wordpress.enable (
    let
      cfg = config.services.wpbox.wordpress;

      # --- HARDWARE & TUNING CALCULATIONS ---
      
      detectedRamMb = config.hardware.memorySize or 4096; 
      detectedCores = config.nix.settings.cores or 2;

      autoTune = cfg.tuning.enableAuto;
      reservedRamMb = cfg.tuning.osRamHeadroom;
      avgProcessMb = cfg.tuning.avgProcessSize;

      # Filter only enabled sites
      activeSites = filterAttrs (n: v: v.enabled) cfg.sites;
      numberOfSites = length (attrNames activeSites);
      safeSiteCount = if numberOfSites > 0 then numberOfSites else 1;

      # RAM Calculation
      availablePhpRamMb = detectedRamMb - reservedRamMb;
      totalMaxChildren = max 2 (availablePhpRamMb / avgProcessMb);
      calculatedChildrenPerSite = max 2 (floor (totalMaxChildren / safeSiteCount));
      finalChildrenPerSite = if autoTune then calculatedChildrenPerSite else 5;

      # Dynamic Pool Configuration
      dynamicPoolConfig = {
        pm = "dynamic";
        "pm.max_children" = finalChildrenPerSite;
        "pm.start_servers" = max 1 (floor (finalChildrenPerSite * 0.25));
        "pm.min_spare_servers" = max 1 (floor (finalChildrenPerSite * 0.25));
        "pm.max_spare_servers" = max 2 (floor (finalChildrenPerSite * 0.50));
        "pm.max_requests" = 1000;
      };

    in
    {
      # --- SAFETY CHECKS ---
      warnings = 
        let 
          totalExpectedFootprint = (finalChildrenPerSite * avgProcessMb * safeSiteCount) + reservedRamMb;
        in
        optional (detectedRamMb > 0 && totalExpectedFootprint > detectedRamMb)
          "⚠️  WPBox PHP-FPM: Expected footprint (${toString totalExpectedFootprint}MB) exceeds detected RAM (${toString detectedRamMb}MB). Risk of OOM!";

      # --- PHP-FPM POOLS ---
      services.phpfpm.pools = mapAttrs' (name: siteOpts: 
        nameValuePair "wordpress-${name}" {
          
          user = "wordpress";
          group = "nginx";
          
          # PHP ini settings
          phpOptions = ''
            expose_php = Off
            allow_url_fopen = On
            display_errors = Off
            log_errors = On
            memory_limit = ${siteOpts.php.memory_limit}
            upload_max_filesize = ${siteOpts.nginx.client_max_body_size}
            post_max_size = ${siteOpts.nginx.client_max_body_size}
            max_execution_time = ${toString siteOpts.php.max_execution_time}
          '';
          
          # Pool configuration (auto-tuned or custom)
          settings = if siteOpts.php.custom_pool != null 
                     then siteOpts.php.custom_pool // {
                       "php_admin_value[error_log]" = "/var/log/phpfpm/wordpress-${name}-error.log";
                       "php_admin_flag[log_errors]" = "on";
                       "listen.owner" = "nginx";
                       "listen.group" = "nginx";
                     }
                     else dynamicPoolConfig // {
                       "php_admin_value[error_log]" = "/var/log/phpfpm/wordpress-${name}-error.log";
                       "php_admin_flag[log_errors]" = "on";
                       "listen.owner" = "nginx";
                       "listen.group" = "nginx";
                     };
          
          phpEnv = {
            PATH = lib.makeBinPath [ pkgs.php ];
          };
        }
      ) activeSites;

      # --- LOG DIRECTORIES ---
      systemd.tmpfiles.rules = [
        "d /var/log/phpfpm 0755 root root - -"
      ];

      # --- ACTIVATION INFO ---
      system.activationScripts.wpbox-phpfpm-info = ''
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "⚙️  WPBox PHP-FPM Auto-Tuning"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "   RAM Detected:    ${toString detectedRamMb}MB"
        echo "   RAM Reserved:    ${toString reservedRamMb}MB (OS/Nginx/MySQL)"
        echo "   RAM Available:   ${toString availablePhpRamMb}MB (for PHP)"
        echo "   Active Sites:    ${toString numberOfSites}"
        echo "   Workers/Site:    ${toString finalChildrenPerSite}"
        echo "   Auto-Tuning:     ${if autoTune then "✓ ENABLED" else "✗ DISABLED"}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      '';
    }
  );
}
