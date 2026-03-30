# DB Hub & Node Platform

A distributed, multi-tenant MariaDB management system. This platform allows you to manage multiple remote database servers (Nodes) from a single central dashboard (Hub).

## Features

- **Central Management Hub**: One dashboard to rule all your database servers.
- **Remote Provisioning**: Create databases and users on any connected node via a secure Agent API.
- **Real-time Monitoring**: Monitor CPU, RAM, Disk, and Active Connections for every server in your fleet.
- **Smart Access**: One-click login to phpMyAdmin for any database on any server.
- **Security**: 
  - Custom Hub Login.
  - API Key authenticated communication between Hub and Nodes.
  - Automatic Let's Encrypt SSL support.
  - Automated logical backups.

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
