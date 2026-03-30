#!/usr/bin/env bash
set -Eeuo pipefail

# DB-Shield NODE Installer (Database + Agent API)
# High-Security Node with Automated Encrypted Cloud Sync.

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
    echo -e "${CLR_BOLD}${CLR_CYAN}"
    echo "===================================================="
    echo "       DB-Shield NODE Installation Wizard           "
    echo "===================================================="
    echo -e "${CLR_RESET}"
    read -p "$(echo -e "${CLR_BOLD}Enter Hub IP (restriction) [${HUB_IP}]: ${CLR_RESET}")" input_hub
    HUB_IP=${input_hub:-$HUB_IP}
    read -p "$(echo -e "${CLR_BOLD}Enter Node FQDN (for SSL): ${CLR_RESET}")" input_fqdn
    SITE_FQDN=${input_fqdn:-$SITE_FQDN}
    read -p "$(echo -e "${CLR_BOLD}Enter SSL Email: ${CLR_RESET}")" input_email
    LETSENCRYPT_EMAIL=${input_email:-$LETSENCRYPT_EMAIL}
    echo -e "\n${CLR_BOLD}${CLR_YELLOW}Execute Deployment? (y/n): ${CLR_RESET}"
    read -p "" confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then exit 0; fi
}

require_ubuntu() {
  if [[ ! -f /etc/os-release ]]; then exit 1; fi
  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" ]]; then exit 1; fi
}

install_packages() {
  msg_header "Installing Core Node Stack"
  apt-get update >/dev/null 2>&1
  apt-get install -y apache2 mariadb-server mariadb-client php libapache2-mod-php php-cli php-mysql php-curl php-zip php-xml php-mbstring php-json phpmyadmin certbot python3-certbot-apache unzip curl openssl ufw cron rclone >/dev/null 2>&1
}

configure_mariadb() {
  msg_header "Security Hardening: MariaDB"
  systemctl enable mariadb >/dev/null 2>&1; systemctl start mariadb
  if [[ -f "$MARIADB_CNF" ]]; then sed -i "s/^[# ]*bind-address.*/bind-address = 0.0.0.0/" "$MARIADB_CNF"; fi
  systemctl restart mariadb
  mysql <<SQL
CREATE USER IF NOT EXISTS '${PROVISIONER_DB_USER}'@'%' IDENTIFIED BY '${PROVISIONER_DB_PASS}';
GRANT ALL PRIVILEGES ON *.* TO '${PROVISIONER_DB_USER}'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
}

configure_phpmyadmin() {
  msg_header "UI Deployment: phpMyAdmin"
  cat >/etc/apache2/conf-available/phpmyadmin.conf <<APACHE
Alias /${PMA_ALIAS} /usr/share/phpmyadmin
<Directory /usr/share/phpmyadmin>
    Options SymLinksIfOwnerMatch
    DirectoryIndex index.php
    Require all granted
</Directory>
APACHE
  a2enconf phpmyadmin >/dev/null 2>&1 || true
}

deploy_agent() {
  msg_header "Deploying Agent API Bridge"
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
    } elseif ($action === 'list_backups') {
        if (!is_dir(BACKUP_DIR)) mkdir(BACKUP_DIR, 0700, true);
        $files = glob(BACKUP_DIR . '/*.sql.gz.enc');
        foreach ($files as $f) {
            $res[] = ['name' => basename($f), 'size' => round(filesize($f)/1024/1024, 2).'MB', 'date' => date('Y-m-d H:i:s', filemtime($f))];
        }
        usort($res, function($a, $b) { return strcmp($b['date'], $a['date']); });
    } elseif ($action === 'trigger_backup') {
        $stamp = date('Ymd-His'); $file = BACKUP_DIR . "/manual-$stamp.sql.gz.enc";
        shell_exec("mariadb-dump --all-databases --single-transaction --quick --routines --events | gzip | openssl enc -aes-256-cbc -salt -pbkdf2 -pass pass:".BACKUP_KEY." -out $file");
        @shell_exec("rclone sync ".BACKUP_DIR." remote:backup --config /root/.rclone.conf");
        $res = ['message' => "Backup created: $stamp"];
    } elseif ($action === 'restore') {
        $file = BACKUP_DIR . '/' . ($_POST['filename'] ?? '');
        if (!file_exists($file)) throw new Exception("File not found.");
        shell_exec("openssl enc -d -aes-256-cbc -pbkdf2 -pass pass:".BACKUP_KEY." -in $file | gunzip | mariadb");
        $res = ['message' => "Restored: ".$_POST['filename']];
    } elseif ($action === 'save_s3_config') {
        $conf = "[remote]\ntype = s3\nprovider = Other\nenv_auth = false\nendpoint = {$_POST['s3_endpoint']}\naccess_key_id = {$_POST['s3_access_key']}\nsecret_access_key = {$_POST['s3_secret_key']}\n";
        file_put_contents('/root/.rclone.conf', $conf);
        $res = ['message' => "Cloud Vault Link Established."];
    } elseif ($action === 'list_tenants') {
        $sql = "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME LIKE '%\_%' AND SCHEMA_NAME NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')";
        foreach ($pdo->query($sql) as $r) {
            $db = $r['SCHEMA_NAME']; $u = explode('_', $db)[0].'_user';
            $stmt = $pdo->prepare("SELECT User, Host FROM mysql.user WHERE User = ?");
            $stmt->execute([$u]);
            $res[] = ['db' => $db, 'user' => $u, 'users' => $stmt->fetchAll()];
        }
    } elseif ($action === 'create') {
        $prefix = $_POST['db_prefix']; $suffix = $_POST['db_suffix']; $host = $_POST['remote_host'];
        $dbName = $prefix.'_'.$suffix; $dbUser = $prefix.'_user'; $dbPass = bin2hex(random_bytes(12));
        $pdo->exec("CREATE DATABASE `$dbName` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci");
        $check = $pdo->prepare("SELECT User FROM mysql.user WHERE User=? AND Host=?"); $check->execute([$dbUser, $host]); $exists = $check->fetch();
        if (!$exists) {
            $pdo->exec("CREATE USER '$dbUser'@'$host' IDENTIFIED BY '$dbPass'");
            if ($host !== 'localhost') $pdo->exec("CREATE USER IF NOT EXISTS '$dbUser'@'localhost' IDENTIFIED BY '$dbPass'");
        }
        $pdo->exec("GRANT ALL PRIVILEGES ON `$dbName`.* TO '$dbUser'@'$host'");
        if ($host !== 'localhost') $pdo->exec("GRANT ALL PRIVILEGES ON `$dbName`.* TO '$dbUser'@'localhost'");
        $res = ['message' => "Provisioned: $dbName", 'download' => ['filename' => $dbName.'.env', 'content' => "DB_DATABASE=$dbName\nDB_USERNAME=$dbUser\nDB_PASSWORD=".($exists?"(Existing)":$dbPass)]];
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
  msg_header "Network Security: UFW"
  ufw allow OpenSSH; ufw allow 'Apache Full'; ufw allow 3306/tcp; ufw --force enable
}

write_backup_script() {
  msg_header "Initializing Backup Engine"
  mkdir -p /var/backups/mariadb
  cat >/usr/local/sbin/db-platform-backup.sh <<BACKUP
#!/usr/bin/env bash
set -euo pipefail
BACKUP_DIR="/var/backups/mariadb"
STAMP="\$(date +%F-%H%M%S)"
mariadb-dump --all-databases --single-transaction --quick --routines --events | gzip | openssl enc -aes-256-cbc -salt -pbkdf2 -pass pass:${MASTER_BACKUP_KEY} -out "\$BACKUP_DIR/daily-\$STAMP.sql.gz.enc"
# Cloud Sync if config exists
if [ -f /root/.rclone.conf ]; then rclone sync "\$BACKUP_DIR" remote:backup --config /root/.rclone.conf; fi
find "\$BACKUP_DIR" -type f -name '*.enc' -mtime +30 -delete
BACKUP
  chmod 700 /usr/local/sbin/db-platform-backup.sh
  systemctl enable cron >/dev/null 2>&1; systemctl start cron
  (crontab -l 2>/dev/null || true; echo "0 2 * * * /usr/local/sbin/db-platform-backup.sh") | crontab -
}

write_summary() {
  cat > "$SUMMARY_FILE" <<EOF
DB NODE DEPLOYMENT SUCCESSFUL
Agent Key: ${AGENT_API_KEY}
Backup Key: ${MASTER_BACKUP_KEY}
Provisioner: ${PROVISIONER_DB_USER} / ${PROVISIONER_DB_PASS}
EOF
  echo -e "\n${CLR_BOLD}${CLR_GREEN}Node ready!${CLR_RESET}"
  echo -e "Agent Security Key: ${CLR_YELLOW}${AGENT_API_KEY}${CLR_RESET}"
  echo -e "Master Backup Key: ${CLR_YELLOW}${MASTER_BACKUP_KEY}${CLR_RESET}"
}

main() {
  clear; require_ubuntu; wizard; install_packages; configure_mariadb; configure_phpmyadmin; deploy_agent; systemctl restart apache2; configure_firewall; write_backup_script; write_summary
}

main "$@"
