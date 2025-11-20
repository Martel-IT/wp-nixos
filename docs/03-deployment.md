# Deployment Guide

This guide covers the bootstrapping process for a new WPBox server.

## Prerequisites

1.  **Target Server:** A VPS (Hetzner, AWS, DigitalOcean) with NixOS installed.
    * *Tip:* If the provider doesn't offer NixOS, use `nixos-infect` to convert an Ubuntu/Debian instance. 
    You can always use [NixOS Anywhere][nixos-anywhere] with [Disko][disko] installing NixOS on a running machine, with partitioning support.
2.  **SSH Access:** Root access via SSH Key (Password auth is disabled by default).

In out repo we cover AWS and a local machine (devm) as target nodes.
Please refer to the [Bootstrap docs][bootstrap] we crafted for more info and instructions.

## DNS
Ensure your domain names (defined in sites.json) point to the server's public IP.


> **_Note:_** Nginx is configured to trust Cloudflare IPs. If you are behind Cloudflare, set the Proxy status to "Proxied" (Orange Cloud). 

TBD


[bootstrap]: bootstrap/README.md
[nixos-anywhere]: https://github.com/numtide/nixos-anywhere
[disko]: https://github.com/nix-community/disko