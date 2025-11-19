# WPBox Architecture

This document explains the core design principles, the directory structure, and the auto-tuning logic of the WPBox infrastructure.


## 1. The Nix Flake Structure

The project is a self-contained **Nix Flake**.
- **Inputs:** We track `nixos-unstable` to ensure access to the latest PHP versions and performance improvements.
- **Outputs:** We export pre-configured system closures for our specific nodes defined in the `nodes/` directory.

## 2. The Interface Wrapper (`services.wpbox`)

We do not configure services like Nginx or MariaDB individually in the server configuration. Instead, we use a central abstraction layer: **The Interface**.

- **Definition:** Located in `modules/service-stack/interface.nix`.
- **Role:** It defines the API surface (options like `services.wpbox.hardware`, `services.wpbox.wordpress.sites`).
- **Function:** It takes high-level inputs (Hardware Specs, Domain Names) and generates low-level configurations (Nginx VHosts, PHP Pools, My.cnf).

## 3. Build-Time Auto-Tuning (The Core Logic)

The defining feature of WPBox is that it calculates configuration values using Nix mathematics *before* the deployment happens.

### The Calculation Flow
When you run `nixos-rebuild`, the following logic is applied:

1.  **Hardware Input:** The system reads `services.wpbox.hardware.runtimeMemoryMb` (e.g., 4096MB).
2.  **OS Reservation:** A fixed amount of RAM (default ~1.5GB) is subtracted for the Kernel, Systemd, and Nginx.
3.  **PHP-FPM Allocation:**
    - The system estimates ~60-70MB per PHP Worker.
    - It calculates the maximum safe `pm.max_children` for the available RAM.
4.  **Database Budgeting:**
    - The remaining RAM is allocated to **MariaDB** (~30% ratio) and **Redis** (~7.5% ratio).
    - **InnoDB Buffer Pool** is strictly sized to 70% of the MariaDB budget.

### Why Build-Time?
Unlike runtime scripts that try to tune a server on boot, our approach ensures **Immutable Infrastructure**. The `my.cnf` or `php-fpm.conf` files are generated in the Nix Store and cannot drift or change unexpectedly. To change the tuning, you must change the code and re-deploy.

## 4. Security Hardening

Security is applied via `modules/security/systemd-hardening.nix`. We use a "Strict" profile by default:

- **ReadWritePaths:** Services can only write to specific directories (e.g., `/var/lib/wordpress`).
- **ProtectSystem:** The rest of the filesystem is Read-Only or completely invisible to the service.
- **Capabilities:** We drop all Linux capabilities not strictly required (e.g., `CAP_NET_ADMIN` is dropped for PHP).