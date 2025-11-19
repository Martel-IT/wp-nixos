# WPBox Modules

This directory contains the logic for the "Service Stack". These modules are designed to be **machine-agnostic**.

## interface.nix
This is the most critical file. It defines all configurable options (`services.wpbox.*`).
All hardware variables (`runtimeMemoryMb`, `runtimeCores`) and tuning parameters pass through here. It acts as a contract between the node configuration and the service implementation.

## Service Stack (`service-stack/`)

Contains the implementation of individual services.

- **`nginx.nix`**:
  - Manages automatic HTTPS VHosts via ACME.
  - Includes a systemd service to update Cloudflare IPs (`set_real_ip_from`) at boot.
  - Implements FastCGI caching and granular rate-limiting.

- **`php-fpm.nix`**:
  - Creates separate pools for each site defined in `sites.json`.
  - Applies auto-tuning by calculating `pm.max_children` based on available RAM.
  - Isolates processes with specific user/group permissions.

- **`mariadb.nix`**:
  - Dynamically calculates `innodb_buffer_pool_size`.
  - Configures `O_DIRECT` and `utf8mb4` by default.
  - Includes an activation script that prints allocated resources at boot for debugging.

- **`redis.nix`**:
  - Configured as an Object Cache for WordPress.
  - Auto-tuned to use a specific % of RAM (default 7.5%) with `allkeys-lru` policy.
  - Uses Unix Sockets for maximum performance (TCP optional).

- **`hardware-detection.nix`**:
  - A "oneshot" service that runs at boot.
  - Populates `/run/wpbox/` with real RAM/CPU info (used for informational scripts/logs; actual config is statically compiled).

- **`fail2ban.nix`**:
  - Protects `wp-login.php` and `xmlrpc.php`.
  - Monitors Nginx logs for rate-limit abuse and bad bots.

## Security (`security/`)

Manages system-level hardening via Systemd.

- **`systemd-hardening.nix`**:
  - Applies kernel restrictions (`ProtectSystem=strict`, `PrivateTmp`, `NoNewPrivileges`) to all services.
  - Defines "Strict" and "Paranoid" profiles.
  - *Note:* If a WP plugin fails to write to disk, check `ReadWritePaths` configuration here.