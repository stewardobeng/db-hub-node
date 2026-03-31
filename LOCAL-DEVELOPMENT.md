# Local Development

CloudDB can now be previewed directly from this repository without deploying to Ubuntu first.

## Layout

- Hub app: `app/hub`
- Node app: `app/node`
- Hub public entrypoint: `app/hub/public/index.php`
- Node public entrypoint: `app/node/public/agent.php`

## XAMPP Quick Start

1. Keep the repo under `D:\xampp\htdocs\db-platform-package`.
2. Copy `app/hub/.env.example` to `app/hub/.env`.
3. Copy `app/node/.env.example` to `app/node/.env`.
4. Generate a Hub admin password hash:

```bash
D:\xampp\php\php.exe -r "echo password_hash('ChangeMe123!', PASSWORD_DEFAULT), PHP_EOL;"
```

5. Paste that value into `app/hub/.env` as `ADMIN_HASH=...`.
6. Set a local API key in `app/node/.env`.
7. Set local MariaDB credentials in `app/node/.env`.

## Local URLs

- Hub: `http://localhost/db-platform-package/app/hub/public/`
- Node: `http://localhost/db-platform-package/app/node/public/agent.php?action=stats&key=YOUR_API_KEY`

## Local Behavior

- The Hub uses SQLite by default at `app/hub/storage/hub_v5.sqlite`.
- The Node expects a reachable MariaDB server through `NODE_DB_DSN`, `PROV_USER`, and `PROV_PASS`.
- The Node backup engine exists in `app/node/bin/backup-engine.sh`, but scheduled backups, Apache aliasing, Certbot, phpMyAdmin installation, and firewall rules are still deployment-time concerns handled by the Ubuntu installers.

## Optional Apache VHosts

If you want cleaner local URLs, point Apache virtual hosts at:

- Hub DocumentRoot: `D:/xampp/htdocs/db-platform-package/app/hub/public`
- Node DocumentRoot: `D:/xampp/htdocs/db-platform-package/app/node/public`

The production installers follow the same pattern on Ubuntu by serving the `public` subdirectories and keeping `.env` plus storage outside the public web root.
