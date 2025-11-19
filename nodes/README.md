# Nodes Configuration

This directory contains specific configurations for each environment (Host).
Each `configuration.nix` file here represents a physical or virtual machine.

## Environments

### 1. `devm` (Development VM)
- **Architecture:** aarch64-linux (Apple Silicon / ARM).
- **Purpose:** Local testing via QEMU.
- **Specifics:**
  - SSL disabled or self-signed.
  - Permissive firewall.
  - Monitoring services disabled to save resources.

### 2. `x86_64-linux` (Standard VPS)
- **Architecture:** Intel/AMD 64-bit.
- **Target:** Typical Cloud VPS (e.g., Hetzner, DigitalOcean).
- **Hardware:** Explicitly configured for 4GB RAM / 2 vCPU.
- **Features:**
  - Swap file active (2GB).
  - Full SSH hardening (No root login, Key Auth only).
  - Automatic system upgrades enabled.

### 3. `aarch64-linux` (ARM VPS)
- **Architecture:** ARM64 (e.g., AWS Graviton, Oracle Ampere).
- **Target:** Production on efficient ARM architecture.
- **Hardware:** Mirrored to x86, optimized for 4GB RAM.

## Hardware Overrides

In each node, you will find a block similar to this:

```nix
services.wpbox.hardware = {
  runtimeMemoryMb = 4096;
  runtimeCores = 2;
};
```

These values force the configuration calculation.

If you remove them (set to null), the system will use fallback values (4GB) defined in interface.nix.

Best Practice: Keep these explicit to ensure that the configuration generated locally (on your PC) is identical to what will run on the server, regardless of the build machine's hardware.