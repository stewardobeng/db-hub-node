#!/usr/bin/env bash
set -Eeuo pipefail

# DB-Shield NODE Installer v5.0 (Enterprise Scaling Edition)
# High-Security Node with Resource Enforcement and Targeted Backups.

# --- Colors & Styles ---
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_RED="\033[0;31m"
CLR_GREEN="\033[0;32m"
CLR_YELLOW="\033[0;33m"
CLR_BLUE="\033[0;34m"
CLR_MAGENTA="\033[0;35m"
CLR_CYAN="\033[0;36m"

# --- UI Helpers ---
msg_header() { echo -e "\n${CLR_BOLD}${CLR_MAGENTA}=== $* ===${CLR_RESET}"; }
msg_info()   { echo -e "${CLR_BLUE}[i]${CLR_RESET} $*"; }
msg_ok()     { echo -e "${CLR_GREEN}[✔]${CLR_RESET} $*"; }
msg_warn()   { echo -e "${CLR_YELLOW}[!]${CLR_RESET} $*"; }
msg_err()    { echo -e "${CLR_RED}[✘]${CLR_RESET} $*"; }

spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while kill -0 "$pid" 2>/dev/null; do
        local temp=${spinstr#?}
        printf "  [${CLR_CYAN}%c${CLR_RESET}]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b\b"
    done
    printf "       \b\b\b\b\b\b\b"
}

run_with_spinner() {
    local msg="$1"
    shift
    printf "${CLR_BLUE}[i]${CLR_RESET} %-50s" "$msg"
    "$@" >/dev/null 2>&1 &
    local pid=$!
    spinner "$pid"
    wait "$pid" && msg_ok "$msg" || { msg_err "$msg failed"; exit 1; }
}

if [[ ${EUID:-0} -ne 0 ]]; then
  msg_err "Run this script as root."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

AGENT_ROOT="/var/www/db-agent"
MARIADB_CNF="/etc/mysql/mariadb.conf.d/50-server.cnf"
SUMMARY_FILE="/root/db-node-install-summary.txt"

: "${HUB_IP:=0.0.0.0/0}"
: "${SITE_FQDN:=_}"
: "${PMA_ALIAS:=phpmyadmin}"
: "${LETSENCRYPT_EMAIL:=}"

PROVISIONER_DB_USER="dbprovisioner"
PROVISIONER_DB_PASS="$(openssl rand -base64 24 | tr -d '\n')"
AGENT_API_KEY="$(openssl rand -hex 32)"
MASTER_BACKUP_KEY="$(openssl rand -hex 16)"

wizard() {
    echo -e "${CLR_BOLD}${CLR_CYAN}===================================================="
    echo "       DB-Shield NODE v5.0: ENTERPRISE SCALING      "
    echo -e "====================================================${CLR_RESET}"
    read -p "Hub Restriction IP [${HUB_IP}]: " input_hub; HUB_IP=${input_hub:-$HUB_IP}
    read -p "Node FQDN: " input_fqdn; SITE_FQDN=${input_fqdn:-$SITE_FQDN}
    read -p "Email for SSL: " input_email; LETSENCRYPT_EMAIL=${input_email:-$LETSENCRYPT_EMAIL}
    echo -e "\n${CLR_BOLD}${CLR_YELLOW}Deploy Node? (y/n): ${CLR_RESET}"
    read -p "" confirm; if [[ ! "$confirm" =~ ^[Yy]$ ]]; then exit 0; fi
}

require_ubuntu() {
  if [[ ! -f /etc/os-release ]]; then exit 1; fi
  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" ]]; then exit 1; fi
}

install_packages() {
  msg_header "Provisioning Environment"
  apt-get update >/dev/null 2>&1
  apt-get install -y apache2 mariadb-server mariadb-client php libapache2-mod-php php-cli php-mysql php-curl php-zip php-xml php-mbstring php-json phpmyadmin certbot python3-certbot-apache unzip curl openssl ufw cron rclone >/dev/null 2>&1
}

configure_mariadb() {
  msg_header "Hardening & Tuning Data Layer"
  systemctl enable mariadb >/dev/null 2>&1; systemctl start mariadb

  # Nitro Tuning for Remote Latency
  local mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  local buffer_pool_mb=$((mem_kb / 1024 / 2)) # Use 50% of RAM for DB Buffer

  cat > /etc/mysql/mariadb.conf.d/99-nitro-speed.cnf <<EOF
[mysqld]
# Speed Optimizations
skip-name-resolve
thread_cache_size = 32
query_cache_type = 1
query_cache_size = 32M
innodb_buffer_pool_size = ${buffer_pool_mb}M
innodb_flush_log_at_trx_commit = 2
innodb_log_file_size = 128M
max_connections = 500
EOF

  if [[ -f "$MARIADB_CNF" ]]; then sed -i "s/^[# ]*bind-address.*/bind-address = 0.0.0.0/" "$MARIADB_CNF"; fi
  systemctl restart mariadb

  mysql <<SQL
CREATE USER IF NOT EXISTS '${PROVISIONER_DB_USER}'@'%' IDENTIFIED BY '${PROVISIONER_DB_PASS}';
GRANT ALL PRIVILEGES ON *.* TO '${PROVISIONER_DB_USER}'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
}

deploy_agent() {
  msg_header "Deploying Agent API v5.0"
  mkdir -p "$AGENT_ROOT"
  
  cat >"$AGENT_ROOT/agent.php" <<'PHPAGENT'
<?php
declare(strict_types=1);
const API_KEY = '__API_KEY__';
const PROV_USER = '__PROV_USER__';
const PROV_PASS = '__PROV_PASS__';
const BACKUP_DIR = '/var/backups/mariadb';
const BACKUP_KEY = '__BACKUP_KEY__';

if (($_GET['key'] ?? '') !== API_KEY) { http_response_code(403); die('Forbidden'); }

function db(): PDO {
    return new PDO('mysql:host=localhost;dbname=information_schema', PROV_USER, PROV_PASS, [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC
    ]);
}

$action = $_GET['action'] ?? 'stats';
$res = [];

try {
    $pdo = db();
    if ($action === 'stats') {
        $free = 0; $total = 0;
        if (is_readable('/proc/meminfo')) {
            $mem = file_get_contents('/proc/meminfo');
            if (preg_match('/MemTotal:\s+(\d+)/', $mem, $m)) $total = (int)$m[1];
            if (preg_match('/MemAvailable:\s+(\d+)/', $mem, $m)) $free = (int)$m[1];
        }
        $res = [
            'cpu' => min(100, round((sys_getloadavg()[0] / (int)shell_exec('nproc')) * 100)),
            'ram' => $total > 0 ? round((($total - $free) / $total) * 100) : 0,
            'ram_text' => round(($total - $free)/1024/1024, 1) . 'GB / ' . round($total/1024/1024, 1) . 'GB',
            'disk' => round(((disk_total_space('/') - disk_free_space('/')) / disk_total_space('/')) * 100),
            'active_conns' => (int)$pdo->query("SHOW STATUS LIKE 'Threads_connected'")->fetch()['Value']
        ];
    } elseif ($action === 'list_tenants') {
        $sql = "SELECT SCHEMA_NAME, 
                (SELECT SUM(data_length + index_length) FROM information_schema.TABLES WHERE table_schema = SCHEMA_NAME) as size_bytes
                FROM information_schema.SCHEMATA 
                WHERE SCHEMA_NAME LIKE '%\_%' AND SCHEMA_NAME NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')";
        foreach ($pdo->query($sql) as $r) {
            $db = $r['SCHEMA_NAME']; $prefix = explode('_', $db)[0]; $u = $prefix . '_user';
            $stmt = $pdo->prepare("SELECT User, Host FROM mysql.user WHERE User = ?");
            $stmt->execute([$u]);
            $res[] = [
                'db' => $db, 
                'user' => $u, 
                'size_mb' => round(($r['size_bytes'] ?? 0) / 1024 / 1024, 2),
                'users' => $stmt->fetchAll()
            ];
        }
    } elseif ($action === 'update_hosts') {
        $u = $_POST['db_user'];
        $hosts = json_decode($_POST['hosts'], true);
        if (!$hosts) throw new Exception("Invalid host list.");
        // Get current pass (harsh but effective way to sync across hosts)
        $p_stmt = $pdo->prepare("SELECT authentication_string FROM mysql.user WHERE User = ? AND Host = 'localhost' LIMIT 1");
        $p_stmt->execute([$u]);
        $auth_str = $p_stmt->fetchColumn();
        
        $pdo->exec("DELETE FROM mysql.user WHERE User = '$u' AND Host != 'localhost'");
        foreach($hosts as $h) {
            $pdo->exec("CREATE USER IF NOT EXISTS '$u'@'$h' IDENTIFIED BY PASSWORD '$auth_str'");
            // Re-grant permissions for this DB (prefix_db)
            $db_name = explode('_user', $u)[0] . '_db';
            $pdo->exec("GRANT ALL PRIVILEGES ON `$db_name`.* TO '$u'@'$h'");
        }
        $pdo->exec("FLUSH PRIVILEGES");
        $res = ['message' => "IP Whitelist Synchronized."];
    } elseif ($action === 'trigger_backup') {
        $filter = $_POST['db_name'] ?? '--all-databases';
        if ($filter !== '--all-databases') $filter = "`$filter`";
        $stamp = date('Ymd-His'); $file = BACKUP_DIR . "/snapshot-$stamp.sql.gz.enc";
        shell_exec("mariadb-dump $filter --single-transaction --quick --routines --events | gzip | openssl enc -aes-256-cbc -salt -pbkdf2 -pass pass:".BACKUP_KEY." -out $file");
        @shell_exec("rclone sync ".BACKUP_DIR." remote:backup --config /root/.rclone.conf");
        $res = ['message' => "Point-in-time snapshot created."];
    } elseif ($action === 'create') {
        $prefix = $_POST['db_prefix']; $suffix = $_POST['db_suffix']; $host = $_POST['remote_host'];
        $max_conns = (int)($_POST['max_conns'] ?? 10);
        $dbName = $prefix.'_'.$suffix; $dbUser = $prefix.'_user'; $dbPass = bin2hex(random_bytes(12));
        $pdo->exec("CREATE DATABASE `$dbName` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci");
        $pdo->exec("CREATE USER '$dbUser'@'$host' IDENTIFIED BY '$dbPass' WITH MAX_USER_CONNECTIONS $max_conns");
        if ($host !== 'localhost') $pdo->exec("CREATE USER IF NOT EXISTS '$dbUser'@'localhost' IDENTIFIED BY '$dbPass' WITH MAX_USER_CONNECTIONS $max_conns");
        $pdo->exec("GRANT ALL PRIVILEGES ON `$dbName`.* TO '$dbUser'@'$host'");
        if ($host !== 'localhost') $pdo->exec("GRANT ALL PRIVILEGES ON `$dbName`.* TO '$dbUser'@'localhost'");
        $res = ['message' => "Resource-hardened DB created.", 'download' => ['filename' => $dbName.'.env', 'content' => "DB_DATABASE=$dbName\nDB_USERNAME=$dbUser\nDB_PASSWORD=$dbPass"]];
    }
} catch (Exception $e) { http_response_code(500); $res = ['error' => $e->getMessage()]; }
header('Content-Type: application/json'); echo json_encode($res);
PHPAGENT

  sed -i "s|__API_KEY__|${AGENT_API_KEY}|g" "$AGENT_ROOT/agent.php"
  sed -i "s|__PROV_USER__|${PROVISIONER_DB_USER}|g" "$AGENT_ROOT/agent.php"
  sed -i "s|__PROV_PASS__|${PROVISIONER_DB_PASS}|g" "$AGENT_ROOT/agent.php"
  sed -i "s|__BACKUP_KEY__|${MASTER_BACKUP_KEY}|g" "$AGENT_ROOT/agent.php"
  
  cat >/etc/apache2/conf-available/db-agent.conf <<APACHE
Alias /agent-api ${AGENT_ROOT}
<Directory ${AGENT_ROOT}>
    Require all granted
</Directory>
APACHE
  a2enconf db-agent >/dev/null 2>&1 || true
}

configure_firewall() {
  msg_header "Hardening Firewall"
  ufw allow OpenSSH; ufw allow 'Apache Full'; ufw allow 3306/tcp; ufw --force enable
}

write_backup_script() {
  msg_header "Configuring Encryption Engine"
  mkdir -p /var/backups/mariadb
  cat >/usr/local/sbin/db-platform-backup.sh <<BACKUP
#!/usr/bin/env bash
set -euo pipefail
BACKUP_DIR="/var/backups/mariadb"
STAMP="\$(date +%F-%H%M%S)"
mariadb-dump --all-databases --single-transaction --quick --routines --events | gzip | openssl enc -aes-256-cbc -salt -pbkdf2 -pass pass:${MASTER_BACKUP_KEY} -out "\$BACKUP_DIR/auto-\$STAMP.sql.gz.enc"
if [ -f /root/.rclone.conf ]; then rclone sync "\$BACKUP_DIR" remote:backup --config /root/.rclone.conf; fi
find "\$BACKUP_DIR" -type f -name '*.enc' -mtime +30 -delete
BACKUP
  chmod 700 /usr/local/sbin/db-platform-backup.sh
  systemctl enable cron >/dev/null 2>&1; systemctl start cron
  (crontab -l 2>/dev/null || true; echo "0 2 * * * /usr/local/sbin/db-platform-backup.sh") | crontab -
}

write_summary() {
  cat > "$SUMMARY_FILE" <<EOF
SHIELD NODE v5.0 SUCCESSFUL
Agent Key: ${AGENT_API_KEY}
Backup Key: ${MASTER_BACKUP_KEY}
Provisioner: ${PROVISIONER_DB_USER}
EOF
  echo -e "\n${CLR_BOLD}${CLR_GREEN}Enterprise Node Online!${RESET:-}"
}

main() {
  clear; require_ubuntu; wizard; install_packages; configure_mariadb; configure_phpmyadmin; deploy_agent; systemctl restart apache2; configure_firewall; write_backup_script; write_summary
}

main "$@"
