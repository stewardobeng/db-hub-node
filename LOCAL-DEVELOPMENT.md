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
- Node agent: `http://localhost/db-platform-package/agent-api/agent.php?action=stats&key=YOUR_API_KEY`
- phpMyAdmin shortcut: `http://localhost/db-platform-package/phpmyadmin/`

## Local Behavior

- The Hub uses SQLite by default at `app/hub/storage/hub_v5.sqlite`.
- The Node expects a reachable MariaDB server through `NODE_DB_DSN`, `PROV_USER`, and `PROV_PASS`.
- The repo includes `agent-api/agent.php` as a local compatibility route so the Hub can keep calling `/agent-api/agent.php`.
- The repo includes `phpmyadmin/index.php` as a local redirect stub for your XAMPP phpMyAdmin install.
- Windows and XAMPP use `app/node/bin/backup-engine.php` for local backup testing.
- Linux deployments still use the shell engine configured by `install-db-node.sh`.
- Scheduled backups, Apache aliasing, Certbot, phpMyAdmin installation, and firewall rules are still deployment-time concerns handled by the Ubuntu installers.

## MFA

- Admins and tenants can enable passkeys, authenticator app codes, and email verification from `Settings`.
- Passkeys work on `localhost` and HTTPS origins. On live deployments, use HTTPS for passkey support.

## Optional Apache VHosts

If you want cleaner local URLs, point Apache virtual hosts at:

- Hub DocumentRoot: `D:/xampp/htdocs/db-platform-package/app/hub/public`
- Node DocumentRoot: `D:/xampp/htdocs/db-platform-package/app/node/public`

The production installers follow the same pattern on Ubuntu by serving the `public` subdirectories and keeping `.env` plus storage outside the public web root.
