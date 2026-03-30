# DB Hub & Node Platform

A distributed, multi-tenant MariaDB management system. This platform allows you to manage multiple remote database servers (Nodes) from a single central dashboard (Hub).

## Features (v5.0 Enterprise)

- **Central Management Hub**: Professional Cyber-Industrial dashboard for total fleet control.
- **Intelligent Provisioning**: Automated node selection based on real-time server load (CPU/RAM).
- **Security Shield**:
  - **Granular IP Whitelisting**: Clients can restrict DB access to specific IPs (Vercel, Office, etc.).
  - **Brute-Force Protection**: Automatic IP locking after failed login attempts.
  - **Hardened Headers**: Production-grade web security configurations.
- **Monetization & Quotas**:
  - **Paystack Integration**: Fully automated subscription activation via webhooks.
  - **Resource Enforcement**: Disk quotas (GB) and Connection limits per plan.
- **Enterprise Backups**:
  - **Point-in-Time Recovery**: Trigger and restore snapshots directly from the Hub.
  - **Encrypted Cloud Sync**: Automated AES-256 encrypted sync to Cloudflare R2/S3.
- **Communication**: SMTP-powered notifications for provisioning, billing, and server health.

## Architecture

1.  **Management Hub**: The central PHP/Tailwind dashboard.
2.  **Database Node**: A remote server running MariaDB and a lightweight Agent API.

---

## Installation

### 1. Deploy the Management Hub
Run this on your primary management server (Ubuntu 22.04/24.04):

```bash
chmod +x install-db-hub.sh
sudo ./install-db-hub.sh
```

### 2. Deploy a Database Node
Run this on every database server you want to manage:

```bash
chmod +x install-db-node.sh
sudo ./install-db-node.sh
```

### 3. Connect Node to Hub
1. Log in to your Hub Dashboard.
2. Click **"Connect New Server"**.
3. Enter the Node's IP, Public URL, and the **Agent API Key** provided at the end of the node installation.

---

## Maintenance

### Uninstalling
To completely remove the platform from a server:
```bash
sudo ./uninstall-db-platform.sh
```

### SSL (Let's Encrypt)
If SSL was not configured during installation, you can add it later:
```bash
sudo certbot --apache -d your-domain.com
```

---

## Security Note
The installer generates random secure passwords for all components. Review the summary files in `/root/` after installation for your credentials.
