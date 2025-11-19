# Operations Manual

This document covers day-to-day management tasks for the WPBox infrastructure.

## Managing Sites

Sites are strictly defined in `sites.json`. This file is the single source of truth for domain provisioning, SSL, and PHP pools.

### Adding a New Site

1.  Open `sites.json` in the root of the repository.
2.  Add a new object to the `sites` array:
    ```json
    {
      "domain": "new-domain.com",
      "enabled": true,
      "php": {
        "memory_limit": "256M",
        "max_execution_time": 300
      },
      "nginx": {
        "client_max_body_size": "64M"
      },
      "wordpress": {
        "debug": false,
        "auto_update": false
      }
    }
    ```

3. **Deploy:** Run `nixos-rebuild switch ...`

**What happens next?**
- A new **System User** (`wordpress`) is created (if not exists).
- A new **PHP-FPM Pool** (`phpfpm-wordpress-new-client.com`) is started.
- A new **Nginx VHost** is generated with ACME (Let's Encrypt) enabled.
- A new **Database** (`wp_new_client_com`) is created (empty).

### Removing a Site
Set `"enabled": false` in `sites.json` and redeploy.
* **Note:** This stops the services but **does not delete** the data in `/var/lib/wordpress` or the Database, ensuring data safety.

## Backups

TBD


## 
Logs & Monitoring
We use systemd-journald for centralized logging.

Monitor Nginx Access (Real-time):

```bash
journalctl -u nginx -f
```
Monitor Specific Site Errors (PHP):

```bash
journalctl -u phpfpm-wordpress-example.com -f
```

Check Security Blocks (Fail2Ban):

```bash
fail2ban-client status wordpress-auth
tail -f /var/log/nginx/fail2ban.log
```