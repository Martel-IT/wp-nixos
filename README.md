# WPBox - NixOS Optimized WordPress Infrastructure

WPBox is an **immutable, declarative, and auto-optimizing** infrastructure designed to host high-performance WordPress sites on NixOS.

Unlike traditional VPS setups (e.g., Ubuntu + apt-get), WPBox mathematically calculates the optimal configuration for all services (PHP-FPM, MariaDB, Redis, Nginx) at **build time**, strictly based on the declared hardware resources.

Check out our [Docs][docs] for more info and instructions.

## Core Features

- **Infrastructure as Code (IaC):** Everything, from firewall rules to PHP pools, is defined in `.nix` files.
- **Hardware-Aware Tuning:** Define your RAM and CPU, and the system automatically calculates:
  - `pm.max_children` for PHP-FPM.
  - `innodb_buffer_pool_size` for MariaDB.
  - `maxmemory` for Redis.
- **Security First:** Aggressive Systemd hardening ("Strict" level), integrated Fail2Ban, and Cloudflare-optimized Nginx.
- **Modern Stack:** PHP 8.2+ (optional JIT), MariaDB, Redis Object Cache, Nginx with Brotli/HTTP2.

## Project Structure

The project is a **Nix Flake** organized modularly:

- **`flake.nix`**: The entry point. Defines inputs (nixpkgs) and outputs (system configurations).
- **`modules/`**: The logic core. Contains service abstractions. It defines *how* services work together, agnostic of the specific server.
- **`nodes/`**: The actual instances (e.g., `x86_64-linux`, `devm`). This is where you import modules and define specific hardware.
- **`sites.json`**: A simple JSON configuration for hosted domains (site list, enabled status, PHP settings).

## Auto-Tuning Logic (The Magic)

The system uses a cascade approach to allocate resources and prevent OOM (Out Of Memory) errors:

1.  **Input:** Receives `runtimeMemoryMb` (e.g., 4096MB) and `runtimeCores`.
2.  **OS Reservation:** Subtracts a fixed quota for the OS and Nginx (default: ~1.5GB).
3.  **PHP Calculation:**
    - Estimates the average RAM usage per PHP worker (e.g., 50-70MB).
    - Calculates how many workers can safely run in the remaining RAM.
4.  **Database Budget:**
    - The remaining RAM is allocated to MariaDB and Redis.
    - InnoDB Buffer Pool is sized to ~70% of this budget.

All of this happens **before** the server starts (`nixos-rebuild`), ensuring static and stable configuration files.

[docs]: docs/README.md