# DB Hub & Node Platform

DB Hub & Node is a self-hosted multi-tenant MariaDB platform built around two install targets:

- `install-db-hub.sh`: deploys the central Hub dashboard.
- `install-db-node.sh`: deploys a database Node with the agent API, MariaDB, phpMyAdmin, and backups.

The Hub provisions tenant databases on connected Nodes, enforces package quotas, tracks tenant usage, and manages IP whitelists from one place.

## What The Platform Does

- Central Hub dashboard built with PHP and SQLite.
- Node agent API for provisioning, usage reporting, IP whitelist updates, backups, tenant deletion, and password rotation.
- Package-based limits for database count, storage quota, and max connections.
- Optional Paystack billing and SMTP notifications.
- Daily encrypted node backups with optional `rclone` sync.
- Scope-aware uninstaller for `hub`, `node`, or `all`.

## Architecture

1. The Hub stores package, tenant, and server metadata in SQLite.
2. Each Node exposes `/agent-api/agent.php` and accepts authenticated requests only from `localhost` and the configured Hub IP.
3. The Hub selects an online Node, provisions tenant credentials, then shows the generated `.env` file and phpMyAdmin link to the tenant.

## Requirements

- Ubuntu 22.04 or 24.04 on the target servers.
- Root or `sudo` access.
- A public FQDN for the Hub.
- A public URL and fixed Hub IP for each Node.
- Optional:
  - Paystack secret key for paid plans.
  - SMTP credentials for alerts and notifications.
  - `rclone` remote configuration for off-server backup sync.

## Install The Hub

Run on the management server:

```bash
chmod +x install-db-hub.sh
sudo ./install-db-hub.sh
```

During setup the installer will prompt for:

- Hub FQDN and Apache alias
- admin email
- optional Paystack settings
- optional SMTP settings

The installer writes a summary file to `/root/db-hub-install-summary.txt`.

## Install A Node

Run on each database server:

```bash
chmod +x install-db-node.sh
sudo ./install-db-node.sh
```

During setup the installer will prompt for:

- Node FQDN
- public URL
- Hub IP
- phpMyAdmin alias

The installer writes a summary file to `/root/db-node-install-summary.txt` containing the agent API key, provisioner credentials, backup key, and access details.

## Connect A Node To The Hub

1. Log in to the Hub as the platform administrator.
2. Open the admin dashboard and add a server.
3. Enter:
   - a display name
   - the Node host or IP
   - the Node public URL
   - the Node agent API key
   - the phpMyAdmin alias configured on that Node

Once saved, the Hub can use that Node for health checks, provisioning, backup triggers, and whitelist updates.

## Tenant Flow

1. Create packages in the Hub or use the seeded defaults.
2. A client signs up for a package.
3. If billing is disabled or the package price is `0`, the account activates immediately.
4. If billing is enabled, the client is sent through Paystack and is activated by webhook after a successful charge.
5. The client provisions databases from the dashboard until their package limit is reached.
6. The Hub syncs usage from the Node and blocks provisioning when the storage quota is exhausted.

## Uninstall

The uninstaller now supports targeted cleanup:

```bash
sudo ./uninstall-db-platform.sh hub
sudo ./uninstall-db-platform.sh node
sudo ./uninstall-db-platform.sh all
```

You can also pre-answer package purge prompts:

```bash
sudo PURGE_PACKAGES=yes ./uninstall-db-platform.sh node
sudo PURGE_PACKAGES=yes ./uninstall-db-platform.sh all
```

Behavior:

- `hub`: removes the Hub app, SQLite data, hub cron job, Apache config, and legacy hub leftovers.
- `node`: removes the Node agent, MariaDB data/config, backup jobs, phpMyAdmin config, and node leftovers.
- `all`: removes both sides and can purge the shared Apache/PHP stack for a full wipe.

The script automatically detects whether the other platform component is still present before deciding whether the shared web stack should also be removed.

## Operational Notes

- Hub watchdog checks run every 10 minutes by cron.
- Node backups run daily at `02:00`.
- The generated Hub app seeds default packages if none exist.
- The generated Node agent validates tenant identifiers and host whitelist values before applying changes.
- Summary files in `/root/` are the primary place to retrieve generated credentials after installation.

## Security Notes

- Review generated credentials immediately after installation.
- Restrict Node exposure further at the cloud firewall or network layer when possible.
- Keep summary files and backup keys in a secure secrets store.
- If you enable billing or email, use real production credentials before going live.

## Repository Layout

- [install-db-hub.sh](./install-db-hub.sh)
- [install-db-node.sh](./install-db-node.sh)
- [uninstall-db-platform.sh](./uninstall-db-platform.sh)
- [DOCUMENTATION.md](./DOCUMENTATION.md)
