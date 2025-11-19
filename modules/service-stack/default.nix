{
  imports = [
    ./hardware-detection.nix
    ./interface.nix
    ./mariadb.nix
    ./nginx.nix
    ./php-fpm.nix
    ./wordpress.nix
    ./fail2ban.nix
    # ./tailscale.nix
    ./redis.nix
  ];
}