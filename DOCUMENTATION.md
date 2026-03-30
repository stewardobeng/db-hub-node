# DB-Shield Hub & Node: Complete Technical Documentation

## 1. Architecture Overview
DB-Shield uses a **Hub-and-Spoke** architecture designed for scalability and security.

-   **Management Hub**: A centralized PHP application that stores metadata about your infrastructure. It handles user authentication, server management, and acts as the gateway for provisioning requests.
-   **Database Nodes**: Remote Ubuntu servers running MariaDB. Each node runs a lightweight **Agent API** that executes commands sent by the Hub and reports health statistics.

## 2. Component Breakdown

### A. The Management Hub (Central Dashboard)
-   **Stack**: PHP 8.x, SQLite 3, Tailwind CSS.
-   **Security**: Uses a local SQLite database (`hub_data.sqlite`) to store server credentials and API keys. Authentication is handled via a secure login page with hashed passwords.
-   **Communication**: Communicates with nodes via `curl` requests to the Agent API.

### B. The Database Node (Worker Server)
-   **Stack**: MariaDB 10.x, Apache2, PHP 8.x (for Agent), rclone (for backups).
-   **Agent API**: A single file (`agent.php`) that performs:
    -   Database & User creation/deletion.
    -   Password rotation.
    -   Server health metrics (CPU, RAM, Disk, Active Connections).
    -   Backup triggering and restoration.
-   **Security**: The Agent API requires a unique `AGENT_KEY` for every request. MariaDB is configured to allow remote connections but restricted by UFW.

## 3. Advanced Features (v5.0)

### A. Granular IP Whitelisting
-   **Mechanism**: The Hub sends a JSON list of IPs to the Node's `update_hosts` endpoint.
-   **Execution**: The Node Agent drops existing remote users and recreates them with specific `HOST` definitions in MariaDB.
-   **Security**: Always preserves `localhost` access for phpMyAdmin connectivity.

### B. Resource Enforcement & Quotas
-   **Disk Quotas**: The Hub tracks `disk_quota_gb` per package. The Node reports usage via `list_tenants` (calculated from `information_schema.TABLES`).
-   **Connection Limits**: Provisioning uses `WITH MAX_USER_CONNECTIONS X` to prevent "noisy neighbor" scenarios where one tenant exhausts server threads.

### C. Intelligent Load Balancing
-   **Logic**: During provisioning, the Hub performs a health-check on all "Online" servers.
-   **Selection**: The server with the lowest `CPU Usage %` is automatically targeted for the new database.

### D. Automated Watchdog
-   **Cron Job**: A 10-minute heartbeat checks node connectivity.
-   **Alerts**: Failure to reach a node triggers an SMTP alert to the Admin email defined during setup.

## 4. Subscription & Billing System
-   **Platform**: Paystack Integration.
-   **Webhooks**: Hub exposes an endpoint for `charge.success` to automatically activate accounts and calculate `expires_at`.

## 4. Backup & Disaster Recovery
### Automated Backups
-   **Frequency**: Daily at 2:00 AM (local node time).
-   **Process**: `mariadb-dump` -> `gzip` -> `OpenSSL AES-256 Encryption`.
-   **Retention**: Local files are kept for 30 days.

### Cloud Sync (S3/R2)
-   Nodes use `rclone` to sync the `/var/backups/mariadb` directory to your configured S3 bucket.
-   Configuration is pushed from the Hub to the Node.

### Manual Restore
If a server is destroyed:
1. Provision a new Node using `install-db-node.sh`.
2. Upload the encrypted backup file to `/var/backups/mariadb`.
3. Use the `MASTER_BACKUP_KEY` from the original installation to decrypt and restore.

## 5. Maintenance Procedures

### Regular Updates
To update the software without a full reinstall:
```bash
# On Node
bash -c "source install-db-node.sh && deploy_agent"

# On Hub
bash -c "source install-db-hub.sh && deploy_hub"
```

### Log Monitoring
-   **Provisioning Logs**: `/var/lib/db-agent/provision.log` (on Node).
-   **Apache Logs**: `/var/log/apache2/error.log`.
-   **System Stats**: Check the Dashboard real-time indicators.

## 6. Continuous Development Guide
-   **Adding Node Features**: Add a new `action` block in `agent.php` inside `install-db-node.sh`, then add a corresponding `call_agent` call in the Hub.
-   **UI Changes**: The Hub uses Tailwind CSS via CDN for rapid development. Modify the `deploy_hub` function in `install-db-hub.sh` to update the interface.
