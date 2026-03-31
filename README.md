# CloudDB Platform

CloudDB is a self-hosted multi-tenant MariaDB control plane built from two installers:

- `install-db-hub.sh`: deploys the Hub dashboard.
- `install-db-node.sh`: deploys a database Node with the agent API, MariaDB, phpMyAdmin, and backup jobs.

The Hub manages tenants and Nodes. Each Node runs the actual MariaDB workloads.

## What The Current Build Does

- Admin Node add, edit, delete, health check, and full-node backup from the Hub UI.
- Admin tenant create, edit, delete, provision, and tenant backup from the Hub UI.
- Client signup, login, self-service database provisioning, IP whitelist management, and per-database backup from the client UI.
- Downloaded tenant `.env` files now include `DB_HOST`, `DB_PORT`, `DB_DATABASE`, `DB_USERNAME`, and `DB_PASSWORD`.
- phpMyAdmin is exposed per Node, its configuration storage is initialized automatically, and internal schemas are hidden from the tenant navigation tree.
- Automatic encrypted daily Node backups with optional `rclone` sync.
- Scope-aware uninstall for `hub`, `node`, or `all`.
- Optional installer checkout removal during uninstall with `--remove-repo` or `REMOVE_REPO=yes`.

## UI Source Of Truth

The current Hub UI is no longer maintained only as a large inline heredoc.

- `templates/hub-index.php`: primary Hub runtime template copied into `/var/www/db-hub/index.php` during install.
- `templates/hub-view.php`: supporting Hub view template copied into `/var/www/db-hub/hub-view.php` during install.
- `stitch/`: designer-delivered HTML screens, screenshots, and design references for every major page and feature.
- `uidesign.md`: the product-facing screen and information architecture brief.

Current Hub install behavior:

1. `install-db-hub.sh` still contains a fallback PHP heredoc for the Hub runtime.
2. If `templates/hub-index.php` and `templates/hub-view.php` exist beside the installer, the installer copies those files into the deployed Hub and uses them as the shipped UI.
3. After copy, the installer injects environment-specific values such as the admin credentials.

If you want to change the live Hub UI, update the files in `templates/` first. Treat `stitch/` as the visual design reference, not the deployed runtime itself.

## Architecture

1. The Hub stores platform metadata in SQLite at `/var/www/db-hub/hub_v5.sqlite`.
2. Each Node exposes `/agent-api/agent.php` plus a phpMyAdmin alias.
3. The Hub chooses a healthy Node, provisions the tenant database, stores the mapping, and offers a ready-to-use `.env` file.
4. Backup requests from the Hub UI queue encrypted dump jobs on the Node and write output to `/var/backups/mariadb`.

## Server Requirements

- Ubuntu 22.04 or 24.04 on the target servers.
- Root or `sudo` access.
- A stable public hostname for the Hub.
- A public hostname or IP for each Node.
- Optional:
  - Paystack secret key for paid plans.
  - SMTP credentials for alerts and notifications.
  - `rclone` config at `/root/.rclone.conf` for off-server backup sync.

## Install The Hub

```bash
chmod +x install-db-hub.sh
sudo ./install-db-hub.sh
```

The Hub installer writes `/root/db-hub-install-summary.txt`.

Important fields in that summary:

- `Access`: Hub login URL. New installs now prefer the FQDN root, for example `https://dbhub.example.com`.
- `TLS`: whether HTTPS was enabled automatically or still needs the fallback command.
- `TLS Command`: the exact manual Certbot command to run if automatic HTTPS could not complete.
- `Admin Identity`: initial Hub admin username.
- `Access Key`: initial Hub admin password.

Automatic HTTPS behavior:

- If you provide a valid Hub FQDN and an admin email, the installer now creates an Apache virtual host and attempts to run Certbot automatically.
- If automatic HTTPS fails, the installer keeps the Hub online over HTTP, writes the fallback Certbot command into `/root/db-hub-install-summary.txt`, and prints that command at the end.
- Automatic HTTPS requires the FQDN to already point to the server and port `80` to be reachable from the Internet.

## Install A Node

```bash
chmod +x install-db-node.sh
sudo ./install-db-node.sh
```

The Node installer writes `/root/db-node-install-summary.txt`.

Important fields in that summary:

- `Agent Key`: use this when registering the Node in the Hub.
- `Backup Key`: use this to decrypt backup files during restore.
- `Provisioner`: internal MariaDB service account used by the Node agent.
- `Agent Path Restriction`: the allowed Hub IP or `any`.
- `phpMyAdmin Alias`: the alias used in the Node URL.
- `Backup Directory`: local path where encrypted backups are written.
- `Backup Schedule`: cron schedule for automatic Node-wide backups.
- `Backup Log`: log file written by the Node backup engine.
- phpMyAdmin configuration storage is initialized automatically on the Node; no manual `pmadb` setup is required on fresh installs.

## Connect A Node To The Hub

In the Hub admin UI, fill the Node form like this:

- `Name`: any display label you want.
- `Database Host / IP`: the MariaDB host that should be written into downloaded tenant `.env` files. Use `host:port` if you need a non-default MariaDB port.
- `Public Endpoint`: the Node base URL only, for example `http://dbnode.example.com`. Do not include `/agent-api/agent.php`.
- `Agent Access Token`: the `Agent Key` from `/root/db-node-install-summary.txt`.
- `phpMyAdmin Alias`: the value from `/root/db-node-install-summary.txt`, usually `phpmyadmin`.

Notes:

- The Hub uses `Public Endpoint` for health checks and agent calls.
- The tenant `.env` uses `Database Host / IP` first. If you leave it blank in a future customization, the Hub falls back to the endpoint hostname and port `3306`.

## Admin Workflow

From the Hub admin UI you can:

- Link, edit, back up, and remove Nodes.
- Create, edit, provision, back up, and remove tenant accounts.
- Download the latest generated tenant `.env` file after an admin-side provision.

Deletion safeguards:

- A Node cannot be removed while tenant databases are still attached to it.
- A tenant cannot be removed while it still owns provisioned databases.

## Client Workflow

Clients can:

- Sign up or log in.
- Provision databases until their package limit is reached.
- Download the generated `.env` file.
- Open phpMyAdmin on the assigned Node.
- Change allowed database client IPs.
- Trigger a backup for an individual database.

## Backups

There are three backup paths:

- Automatic Node backup:
  - Daily at `02:00` local Node time.
  - Dumps all databases on the Node.
- Admin tenant backup:
  - From the Hub tenant table.
  - Queues backups for every database owned by that tenant.
- Client database backup:
  - From the client dashboard.
  - Queues a backup for that single database.

Admin full-node backup is also available from the Node table in the Hub UI.

All UI-triggered backups:

- queue an encrypted dump job on the target Node,
- write the output to `/var/backups/mariadb`,
- use the local provisioner credentials instead of root socket auth,
- and sync via `rclone` if `/root/.rclone.conf` exists.

Node backup engine notes:

- Script path: `/usr/local/sbin/db-platform-backup.sh`
- MySQL credential file: `/etc/clouddb/backup-mysql.cnf`
- Log file: `/var/log/clouddb-backup.log`
- Retention: 30 days by default
- Future R2 support can be added through the existing `rclone` sync target instead of redesigning the backup flow again.

## Restore A Backup

You need:

- the `.sql.gz.enc` backup file,
- the Node `Backup Key` from `/root/db-node-install-summary.txt`,
- and a MariaDB server to restore into.

Basic restore command:

```bash
openssl enc -d -aes-256-cbc -pbkdf2 -pass pass:YOUR_BACKUP_KEY -in /var/backups/mariadb/your-backup.sql.gz.enc | gunzip | mariadb
```

Recommended restore flow:

1. Provision a fresh Node or use the original Node.
2. Copy the encrypted backup file onto that server.
3. Confirm MariaDB is running.
4. Run the restore command above with the correct `Backup Key`.
5. Reconnect the Node to the Hub if you rebuilt it from scratch.

If you restore onto a brand-new Node, also reapply any DNS, firewall, or Hub registration details that existed before the failure.

## Operational Notes

- Hub watchdog checks run every 10 minutes.
- The Hub seeds default packages if none exist.
- Node backups are retained locally for 30 days.
- phpMyAdmin hides `information_schema`, `performance_schema`, `mysql`, `sys`, and `phpmyadmin` from the navigation tree.
- MariaDB still uses those internal schemas under the hood; the hide rule is for UI clarity, not a database-engine change.

## Uninstall

```bash
sudo ./uninstall-db-platform.sh hub
sudo ./uninstall-db-platform.sh node
sudo ./uninstall-db-platform.sh all
```

Optional package purge:

```bash
sudo PURGE_PACKAGES=yes ./uninstall-db-platform.sh node
sudo PURGE_PACKAGES=yes ./uninstall-db-platform.sh all
```

Optional installer checkout removal:

```bash
sudo ./uninstall-db-platform.sh all --remove-repo
sudo REMOVE_REPO=yes ./uninstall-db-platform.sh hub
```

Behavior:

- `hub`: removes the Hub app, SQLite data, Hub cron job, Apache config, and Hub leftovers.
- `node`: removes the Node agent, MariaDB data/config, backup jobs, phpMyAdmin config, and Node leftovers.
- `all`: removes both sides and can purge shared packages for a full wipe.
- `--remove-repo`: also removes the installer checkout directory when the script can safely confirm it is running from that repo.

Recommended uninstall examples:

```bash
sudo ./uninstall-db-platform.sh hub
sudo PURGE_PACKAGES=yes ./uninstall-db-platform.sh node
sudo ./uninstall-db-platform.sh all --remove-repo
```

Notes:

- Default uninstall removes the deployed runtime only.
- Repo removal is intentionally conservative and only happens when the script still recognizes its own checkout safely.
- Use `--remove-repo` when the cloned project directory on the server is no longer needed after uninstall.

## Repository Layout

- [install-db-hub.sh](./install-db-hub.sh)
- [install-db-node.sh](./install-db-node.sh)
- [uninstall-db-platform.sh](./uninstall-db-platform.sh)
- [DOCUMENTATION.md](./DOCUMENTATION.md)
- [uidesign.md](./uidesign.md)
- [`templates/`](./templates)
- [`stitch/`](./stitch)
