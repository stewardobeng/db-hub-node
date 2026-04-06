# CloudDB Platform

CloudDB is a self-hosted multi-tenant MariaDB control plane built from two installers:

- `install-db-hub.sh`: deploys the Hub dashboard.
- `install-db-node.sh`: deploys a database Node with the agent API, MariaDB, phpMyAdmin, and backup jobs.

The Hub manages tenants and Nodes. Each Node runs the actual MariaDB workloads.

## What The Current Build Does

- Admin Node add, edit, delete, health check, and full-node backup from the Hub UI.
- Admin tenant create, edit, delete, provision, and tenant backup from the Hub UI.
- Client signup, login, self-service database provisioning, IP whitelist management, and per-database backup from the client UI.
- Multi-factor authentication for admin and tenant accounts with passkeys, authenticator codes, and email codes.
- Downloaded tenant `.env` files now include `DB_HOST`, `DB_PORT`, `DB_DATABASE`, `DB_USERNAME`, and `DB_PASSWORD`.
- phpMyAdmin is exposed per Node, its configuration storage is initialized automatically, and internal schemas are hidden from the tenant navigation tree.
- Automatic encrypted daily Node backups with optional `rclone` sync.
- Scope-aware uninstall for `hub`, `node`, or `all`.
- Optional installer checkout removal during uninstall with `--remove-repo` or `REMOVE_REPO=yes`.

## UI Source Of Truth

The runtime source of truth now lives in normal PHP app directories.

- `app/hub/`: repo-backed Hub application deployed by `install-db-hub.sh`
- `app/node/`: repo-backed Node agent application deployed by `install-db-node.sh`
- `stitch/`: designer-delivered HTML screens, screenshots, and design references for every major page and feature.
- `uidesign.md`: the product-facing screen and information architecture brief.

Current install behavior:

1. `install-db-hub.sh` copies `app/hub/` into `/var/www/db-hub`, writes `/var/www/db-hub/.env`, and serves `/var/www/db-hub/public`.
2. `install-db-node.sh` copies `app/node/` into `/var/www/db-agent`, writes `/var/www/db-agent/.env`, and serves `/var/www/db-agent/public` behind `/agent-api`.
3. The installers still own OS-level concerns such as Apache, MariaDB, Certbot, phpMyAdmin, cron, firewall rules, and backup directories.

If you want to change the live runtime, edit the files under `app/`. Treat `stitch/` as the visual design reference, not the deployed runtime itself.

## Architecture

1. The Hub app lives at `/var/www/db-hub`, serves from `/var/www/db-hub/public`, and stores metadata in SQLite at `/var/www/db-hub/storage/hub_v5.sqlite`.
2. Each Node app lives at `/var/www/db-agent`, serves from `/var/www/db-agent/public`, exposes `/agent-api/agent.php`, and publishes a phpMyAdmin alias.
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

## Production Deployment Guide

Use this order for a clean live rollout:

1. Deploy the Hub.
2. Deploy one or more Nodes.
3. Add each Node in the Hub UI.
4. Test provisioning with a tenant account.
5. Configure billing webhook if you use paid plans.

### 1. Prepare DNS and firewall

Before running the installers:

- Point your Hub FQDN to the Hub server public IP.
- Point each Node FQDN to the correct Node server public IP.
- Open `80` and `443` on the Hub server.
- Open `80` on each Node server.
- Open `3306` on each Node only if tenants will connect remotely to MariaDB from outside the server.

Recommended example:

- Hub: `dbhub.example.com`
- Node: `dbnode1.example.com`

### 2. Clone the repo on each server

Run this on the Hub server and on each Node server:

```bash
apt update
apt install -y git
git clone https://github.com/stewardobeng/db-hub-node.git
cd db-hub-node
chmod +x install-db-hub.sh install-db-node.sh uninstall-db-platform.sh
```

### 3. Install the Hub

On the Hub server:

```bash
cd ~/db-hub-node
sudo ./install-db-hub.sh
```

The installer will ask for:

- `FQDN`: the Hub public hostname, for example `dbhub.example.com`
- `Admin Alert Email`: used for alerts and automatic HTTPS
- `Paystack Secret`: optional, leave blank to disable paid billing
- `Paystack Currency`: for example `NGN`
- `SMTP Host`, `SMTP Port`, `SMTP User`, `SMTP Pass`, `SMTP From`: optional mail settings

After install, check:

```bash
cat /root/db-hub-install-summary.txt
systemctl status apache2 --no-pager
```

Important values in the summary:

- `Access`: the Hub login URL
- `Admin Identity`: first admin username
- `Access Key`: first admin password
- `TLS`: whether HTTPS completed automatically
- `TLS Command`: the manual Certbot fallback command if HTTPS did not complete

If automatic HTTPS did not complete:

1. confirm the Hub FQDN already points to the server
2. confirm port `80` is reachable from the internet
3. run the saved `TLS Command` from `/root/db-hub-install-summary.txt`

### 4. Verify the Hub is live

From the Hub server:

```bash
curl -I http://127.0.0.1/
```

Then open the public URL from the summary file and sign in with:

- username: `Admin Identity`
- password: `Access Key`

### 5. Install a Node

On each Node server:

```bash
cd ~/db-hub-node
sudo ./install-db-node.sh
```

The installer will ask for:

- `Hub Restriction IP or CIDR`: the Hub server IP, a narrow CIDR, or `any`
- `Node FQDN`: the public Node hostname
- `Email for SSL`: currently collected, but do not assume Node HTTPS is live unless you configure it separately

After install, check:

```bash
cat /root/db-node-install-summary.txt
systemctl status apache2 --no-pager
systemctl status mariadb --no-pager
```

Important values in the summary:

- `Agent Key`
- `Backup Key`
- `phpMyAdmin Alias`
- `Agent Path Restriction`
- `Backup Directory`

### 6. Verify the Node agent before adding it to the Hub

From the Node server:

```bash
curl "http://127.0.0.1/agent-api/agent.php?action=stats&key=YOUR_AGENT_KEY"
```

Replace `YOUR_AGENT_KEY` with the `Agent Key` from `/root/db-node-install-summary.txt`.

If that returns JSON, the agent is working locally.

Then test the public endpoint:

```bash
curl "http://YOUR_NODE_FQDN/agent-api/agent.php?action=stats&key=YOUR_AGENT_KEY"
```

Use `https://` only if you separately confirmed Node HTTPS is live.

### 7. Add the Node in the Hub UI

Sign in to the Hub as admin, open the Node form, and use:

- `Name`: any display label
- `Database Host / IP`: the MariaDB host clients should use, for example `dbnode1.example.com` or `dbnode1.example.com:3306`
- `Public Endpoint`: the Node base URL only, for example `http://dbnode1.example.com`
- `Agent Access Token`: the Node `Agent Key`
- `phpMyAdmin Alias`: usually `phpmyadmin`

Do not append `/agent-api/agent.php` to `Public Endpoint`.

### 8. Create a tenant and test provisioning

Recommended first live test:

1. sign in to the Hub as admin
2. create a tenant or sign up from the public landing page
3. provision one database
4. download the generated `.env`
5. open phpMyAdmin from the dashboard
6. trigger one manual backup

Successful provisioning confirms:

- Hub to Node health checks are working
- MariaDB provisioning is working
- tenant connection files are correct
- backup actions are reaching the Node
- completed backup jobs become downloadable from the Hub

### 9. Configure paid billing if you use Paystack

If you use paid plans:

- set `Paystack Secret` during Hub install
- add this webhook in your Paystack dashboard:

```text
https://YOUR_HUB_FQDN/index.php?action=paystack_webhook
```

Example:

```text
https://dbhub.example.com/index.php?action=paystack_webhook
```

Without a working webhook, successful Paystack payments will not automatically activate accounts.

### 10. Backups and restore readiness

After each Node install:

- keep a copy of `/root/db-node-install-summary.txt`
- keep the `Backup Key` somewhere safe
- confirm `/var/backups/mariadb` exists
- confirm the backup log exists at `/var/log/clouddb-backup.log`

UI backup operations:

- admins can download completed backup files from the `Backups` page and from database detail pages
- tenants can download completed backups for their own databases from the same areas
- admins can restore database backups and full-node backups from the Hub UI
- tenants can restore backups only for their own provisioned databases
- database restores replace the current contents of that database before import

If a live Linux backup still shows `queued`, refresh the `Backups` page after the file is written on the Node. The Hub now checks the Node for the file and marks the job `completed` when it is ready.

Manual restore format:

```bash
openssl enc -d -aes-256-cbc -pbkdf2 -pass pass:YOUR_BACKUP_KEY -in /var/backups/mariadb/your-backup.sql.gz.enc | gunzip | mariadb
```

### 11. Ongoing updates

For code updates, pull the repo first:

```bash
cd ~/db-hub-node
git pull origin main
```

Important caution:

- do not blindly rerun the installers on a live server unless you understand the credential impact
- rerunning the installers can regenerate admin passwords, agent keys, provisioner passwords, and backup keys
- on live systems, treat the summary files as secrets and store them safely

## Run Locally

The Hub and Node now run as normal PHP applications from this repository, so you can preview and edit them before deployment.

### XAMPP quick preview

1. Keep the repo under `D:\xampp\htdocs\db-platform-package`.
2. Copy `app/hub/.env.example` to `app/hub/.env`.
3. Copy `app/node/.env.example` to `app/node/.env`.
4. Set a real admin password hash for the Hub:

```bash
D:\xampp\php\php.exe -r "echo password_hash('ChangeMe123!', PASSWORD_DEFAULT), PHP_EOL;"
```

5. Put that hash into `app/hub/.env` as `ADMIN_HASH=...`.
6. Open the Hub locally at `http://localhost/db-platform-package/app/hub/public/`.
7. Test the Node agent locally at `http://localhost/db-platform-package/agent-api/agent.php?action=stats&key=YOUR_API_KEY`.

Local notes:

- The Hub uses SQLite locally by default through `app/hub/storage/hub_v5.sqlite`.
- The Node expects MariaDB credentials in `app/node/.env`.
- The repo includes a local compatibility route at `agent-api/agent.php` so the Hub can call the Node with the same `/agent-api/agent.php` path it uses in production.
- The repo includes `phpmyadmin/index.php` as a local redirect stub so the Hub can open your local phpMyAdmin install from the same base URL.
- Windows and XAMPP use `app/node/bin/backup-engine.php` for local backup testing. Linux deployments still use the shell engine installed by `install-db-node.sh`.
- Scheduled backups, Apache aliasing, Certbot, phpMyAdmin installation, and firewall rules still remain deployment-time concerns handled by the Ubuntu installers.

For the exact local file layout and URL examples, see [LOCAL-DEVELOPMENT.md](/D:/xampp/htdocs/db-platform-package/LOCAL-DEVELOPMENT.md).

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
- Download completed backup files from the backup center.
- Restore completed database backups, and restore full-node backups when needed.

Deletion safeguards:

- A Node cannot be removed while tenant databases are still attached to it.
- A tenant cannot be removed while it still owns provisioned databases.

## Client Workflow

Clients can:

- Sign up or log in.
- Enable or disable passkeys, authenticator app codes, and email 2FA from Settings.
- Provision databases until their package limit is reached.
- Download the generated `.env` file.
- Open phpMyAdmin on the assigned Node.
- Change allowed database client IPs.
- Trigger a backup for an individual database.
- Download completed backups for their own databases.
- Restore completed backups into their own databases.

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

Completed backup jobs can be downloaded from the Hub UI.

Restore behavior in the Hub UI:

- Database restore:
  - available to admins and the owning tenant
  - restores into the current provisioned database
  - replaces the current database contents before import
- Tenant backup restore:
  - each tenant backup is now recorded per provisioned database
  - those completed entries can be downloaded or restored individually
- Full-node backup restore:
  - available to admins only
  - intended for recovery and should be used carefully because it can overwrite MariaDB data on that Node

Node backup engine notes:

- Script path: `/usr/local/sbin/db-platform-backup.sh`
- MySQL credential file: `/etc/clouddb/backup-mysql.cnf`
- Log file: `/var/log/clouddb-backup.log`
- Retention: 30 days by default
- Future R2 support can be added through the existing `rclone` sync target instead of redesigning the backup flow again.

Local backup engine notes:

- Windows/XAMPP dev uses `app/node/bin/backup-engine.php`.
- Local backup output is written under `app/node/storage/backups`.
- The local engine encrypts and compresses dumps so backup testing works before you deploy to Ubuntu.

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
- [`app/hub/`](./app/hub)
- [`app/node/`](./app/node)
- [DOCUMENTATION.md](./DOCUMENTATION.md)
- [LOCAL-DEVELOPMENT.md](./LOCAL-DEVELOPMENT.md)
- [uidesign.md](./uidesign.md)
- [`stitch/`](./stitch)
