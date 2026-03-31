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

sed_escape() { printf '%s' "$1" | sed -e 's/[|&\\]/\\&/g'; }

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

: "${HUB_IP:=any}"
: "${SITE_FQDN:=_}"
: "${PMA_ALIAS:=phpmyadmin}"
: "${LETSENCRYPT_EMAIL:=}"

PROVISIONER_DB_USER="dbprovisioner"
PROVISIONER_DB_PASS="$(openssl rand -base64 24 | tr -d '\n')"
AGENT_API_KEY="$(openssl rand -hex 32)"
MASTER_BACKUP_KEY="$(openssl rand -hex 16)"
AGENT_REQUIRE_DIRECTIVE="Require all granted"

normalise_hub_restriction() {
  local raw="${1:-}"
  raw="$(printf '%s' "$raw" | tr -d '[:space:]')"
  if [[ -z "$raw" ]]; then raw="any"; fi

  case "${raw,,}" in
    any|all|'*'|0.0.0.0/0|::/0)
      HUB_IP="any"
      AGENT_REQUIRE_DIRECTIVE="Require all granted"
      return 0
      ;;
  esac

  if [[ "$raw" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
    HUB_IP="$raw"
    AGENT_REQUIRE_DIRECTIVE="Require ip ${HUB_IP}"
    return 0
  fi

  if [[ "$raw" =~ ^[0-9A-Fa-f:]+(/[0-9]{1,3})?$ ]]; then
    HUB_IP="$raw"
    AGENT_REQUIRE_DIRECTIVE="Require ip ${HUB_IP}"
    return 0
  fi

  msg_err "Invalid Hub restriction: '$raw'. Use 'any', a single IP, or CIDR such as 203.0.113.10 or 203.0.113.0/24."
  exit 1
}

wizard() {
    echo -e "${CLR_BOLD}${CLR_CYAN}===================================================="
    echo "       DB-Shield NODE v5.0: ENTERPRISE SCALING      "
    echo -e "====================================================${CLR_RESET}"
    read -p "Hub Restriction IP or CIDR [${HUB_IP}]: " input_hub; HUB_IP=${input_hub:-$HUB_IP}
    normalise_hub_restriction "$HUB_IP"
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
CREATE USER IF NOT EXISTS '${PROVISIONER_DB_USER}'@'localhost' IDENTIFIED BY '${PROVISIONER_DB_PASS}';
ALTER USER '${PROVISIONER_DB_USER}'@'localhost' IDENTIFIED BY '${PROVISIONER_DB_PASS}';
GRANT ALL PRIVILEGES ON *.* TO '${PROVISIONER_DB_USER}'@'localhost' WITH GRANT OPTION;
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
  mkdir -p /etc/phpmyadmin/conf.d
  cat >/etc/phpmyadmin/conf.d/90-db-platform.php <<'PMACONF'
<?php
if (isset($i) && is_int($i)) {
    $cfg['Servers'][$i]['hide_db'] = '^(information_schema|performance_schema|mysql|sys)$';
}
PMACONF
  a2enconf phpmyadmin >/dev/null 2>&1 || true
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
const BACKUP_SCRIPT = '/usr/local/sbin/db-platform-backup.sh';
const BACKUP_KEY = '__BACKUP_KEY__';

if (($_GET['key'] ?? '') !== API_KEY) { http_response_code(403); die('Forbidden'); }

function db(): PDO {
    return new PDO('mysql:host=localhost;dbname=information_schema', PROV_USER, PROV_PASS, [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC
    ]);
}
function ensure_identifier(string $value, string $label): string {
    if (!preg_match('/^[A-Za-z0-9_]{1,48}$/', $value)) throw new InvalidArgumentException($label . ' is invalid.');
    return $value;
}
function ensure_host_value(string $value): string {
    if ($value === '%') return $value;
    if (filter_var($value, FILTER_VALIDATE_IP)) return $value;
    if (preg_match('/^[A-Za-z0-9._:%-]{1,255}$/', $value)) return $value;
    throw new InvalidArgumentException('Host value is invalid.');
}
function sql_ident(string $value): string {
    return '`' . str_replace('`', '``', $value) . '`';
}
function tenant_db_for_user(string $dbUser): string {
    if (!preg_match('/^([A-Za-z0-9]+)_user$/', $dbUser, $m)) throw new InvalidArgumentException('Database user is invalid.');
    return $m[1] . '_db';
}
function quoted_user_host(PDO $pdo, string $user, string $host): string {
    return $pdo->quote($user) . '@' . $pdo->quote($host);
}
function drop_remote_user_hosts(PDO $pdo, string $user): void {
    $stmt = $pdo->prepare("SELECT Host FROM mysql.user WHERE User = ? AND Host != 'localhost'");
    $stmt->execute([$user]);
    foreach ($stmt->fetchAll(PDO::FETCH_COLUMN) as $host) {
        $pdo->exec("DROP USER IF EXISTS " . quoted_user_host($pdo, $user, (string)$host));
    }
}
function queue_backup_job(array $dbNames = []): array {
    if (!is_executable(BACKUP_SCRIPT)) throw new RuntimeException('Backup engine is not installed.');
    $cleanNames = [];
    foreach ($dbNames as $dbName) {
        $cleanNames[] = ensure_identifier((string)$dbName, 'Database name');
    }
    $cleanNames = array_values(array_unique($cleanNames));
    $label = $cleanNames
        ? preg_replace('/[^A-Za-z0-9._-]+/', '-', implode('-', array_slice($cleanNames, 0, 3)))
        : 'node-full';
    $stamp = date('Ymd-His');
    $file = BACKUP_DIR . '/' . ($label ?: 'snapshot') . '-' . $stamp . '.sql.gz.enc';
    $command = 'nohup env BACKUP_FILE=' . escapeshellarg($file) . ' ' . escapeshellarg(BACKUP_SCRIPT);
    foreach ($cleanNames as $dbName) {
        $command .= ' ' . escapeshellarg($dbName);
    }
    $command .= ' >/dev/null 2>&1 & echo $!';
    $pid = trim((string)shell_exec($command));
    return ['file' => basename($file), 'path' => $file, 'pid' => $pid];
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
                WHERE SCHEMA_NAME LIKE '%\\_db' ESCAPE '\\'
                  AND SCHEMA_NAME NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')";
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
        $u = ensure_identifier((string)($_POST['db_user'] ?? ''), 'Database user');
        $hosts = json_decode((string)($_POST['hosts'] ?? '[]'), true);
        if (!is_array($hosts) || !$hosts) throw new Exception("Invalid host list.");
        $hosts = array_values(array_unique(array_map('ensure_host_value', $hosts)));
        $p_stmt = $pdo->prepare("SELECT authentication_string FROM mysql.user WHERE User = ? AND Host = 'localhost' LIMIT 1");
        $p_stmt->execute([$u]);
        $auth_str = $p_stmt->fetchColumn();
        if (!$auth_str) throw new Exception("Base localhost user not found.");

        drop_remote_user_hosts($pdo, $u);
        $db_name = tenant_db_for_user($u);
        foreach($hosts as $h) {
            if ($h === 'localhost') continue;
            $pdo->exec("CREATE USER IF NOT EXISTS " . quoted_user_host($pdo, $u, $h) . " IDENTIFIED BY PASSWORD " . $pdo->quote((string)$auth_str));
            $pdo->exec("GRANT ALL PRIVILEGES ON " . sql_ident($db_name) . ".* TO " . quoted_user_host($pdo, $u, $h));
        }
        $pdo->exec("FLUSH PRIVILEGES");
        $res = ['message' => "IP Whitelist Synchronized."];
    } elseif ($action === 'trigger_backup') {
        $dbNames = [];
        $singleDbName = trim((string)($_POST['db_name'] ?? ''));
        if ($singleDbName !== '') $dbNames[] = $singleDbName;
        $multiDbNames = $_POST['db_names'] ?? null;
        if ($multiDbNames !== null) {
            $decoded = json_decode((string)$multiDbNames, true);
            if (!is_array($decoded)) throw new InvalidArgumentException('Database list is invalid.');
            foreach ($decoded as $dbName) $dbNames[] = (string)$dbName;
        }
        $backup = queue_backup_job($dbNames);
        if (count($dbNames) === 1) $message = 'Backup queued for ' . ensure_identifier($dbNames[0], 'Database name') . '.';
        elseif ($dbNames) $message = 'Backup queued for ' . count(array_unique($dbNames)) . ' databases.';
        else $message = 'Full-node backup queued.';
        $res = ['message' => $message, 'file' => $backup['file'], 'path' => $backup['path'], 'pid' => $backup['pid']];
    } elseif ($action === 'create') {
        $prefix = ensure_identifier((string)($_POST['db_prefix'] ?? ''), 'Database prefix');
        $suffix = ensure_identifier((string)($_POST['db_suffix'] ?? ''), 'Database suffix');
        $host = ensure_host_value((string)($_POST['remote_host'] ?? '%'));
        $max_conns = (int)($_POST['max_conns'] ?? 10);
        $dbName = $prefix . '_' . $suffix; $dbUser = $prefix . '_user'; $dbPass = bin2hex(random_bytes(12));
        $pdo->exec("CREATE DATABASE " . sql_ident($dbName) . " CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci");
        $pdo->exec("CREATE USER " . quoted_user_host($pdo, $dbUser, $host) . " IDENTIFIED BY " . $pdo->quote($dbPass) . " WITH MAX_USER_CONNECTIONS $max_conns");
        if ($host !== 'localhost') $pdo->exec("CREATE USER IF NOT EXISTS " . quoted_user_host($pdo, $dbUser, 'localhost') . " IDENTIFIED BY " . $pdo->quote($dbPass) . " WITH MAX_USER_CONNECTIONS $max_conns");
        $pdo->exec("GRANT ALL PRIVILEGES ON " . sql_ident($dbName) . ".* TO " . quoted_user_host($pdo, $dbUser, $host));
        if ($host !== 'localhost') $pdo->exec("GRANT ALL PRIVILEGES ON " . sql_ident($dbName) . ".* TO " . quoted_user_host($pdo, $dbUser, 'localhost'));
        $res = ['message' => "Resource-hardened DB created.", 'download' => ['filename' => $dbName.'.env', 'content' => "DB_DATABASE=$dbName\nDB_USERNAME=$dbUser\nDB_PASSWORD=$dbPass"]];
    } elseif ($action === 'delete') {
        $dbName = ensure_identifier((string)($_POST['db_name'] ?? ''), 'Database name');
        $dbUser = ensure_identifier((string)($_POST['db_user'] ?? ''), 'Database user');
        $stmt = $pdo->prepare("SELECT Host FROM mysql.user WHERE User = ?");
        $stmt->execute([$dbUser]);
        foreach ($stmt->fetchAll(PDO::FETCH_COLUMN) as $userHost) {
            $pdo->exec("DROP USER IF EXISTS " . quoted_user_host($pdo, $dbUser, (string)$userHost));
        }
        $pdo->exec("DROP DATABASE IF EXISTS " . sql_ident($dbName));
        $res = ['message' => "Database removed."];
    } elseif ($action === 'rotate_password') {
        $dbUser = ensure_identifier((string)($_POST['db_user'] ?? ''), 'Database user');
        $dbName = tenant_db_for_user($dbUser);
        $dbPass = trim((string)($_POST['db_password'] ?? '')) ?: bin2hex(random_bytes(12));
        $stmt = $pdo->prepare("SELECT Host FROM mysql.user WHERE User = ?");
        $stmt->execute([$dbUser]);
        $hosts = $stmt->fetchAll(PDO::FETCH_COLUMN);
        if (!$hosts) throw new Exception("Database user not found.");
        foreach ($hosts as $userHost) {
            $pdo->exec("ALTER USER " . quoted_user_host($pdo, $dbUser, (string)$userHost) . " IDENTIFIED BY " . $pdo->quote($dbPass));
        }
        $res = ['message' => "Password rotated.", 'download' => ['filename' => $dbName . '.env', 'content' => "DB_DATABASE=$dbName\nDB_USERNAME=$dbUser\nDB_PASSWORD=$dbPass"]];
    }
} catch (Throwable $e) { http_response_code(500); $res = ['error' => $e->getMessage()]; }
header('Content-Type: application/json'); echo json_encode($res);
PHPAGENT

  sed -i "s|__API_KEY__|$(sed_escape "$AGENT_API_KEY")|g" "$AGENT_ROOT/agent.php"
  sed -i "s|__PROV_USER__|$(sed_escape "$PROVISIONER_DB_USER")|g" "$AGENT_ROOT/agent.php"
  sed -i "s|__PROV_PASS__|$(sed_escape "$PROVISIONER_DB_PASS")|g" "$AGENT_ROOT/agent.php"
  sed -i "s|__BACKUP_KEY__|$(sed_escape "$MASTER_BACKUP_KEY")|g" "$AGENT_ROOT/agent.php"
  
  cat >/etc/apache2/conf-available/db-agent.conf <<APACHE
Alias /agent-api ${AGENT_ROOT}
<Directory ${AGENT_ROOT}>
    <RequireAny>
        Require local
        ${AGENT_REQUIRE_DIRECTIVE}
    </RequireAny>
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
STAMP="\${BACKUP_STAMP:-\$(date +%F-%H%M%S)}"
OUT_FILE="\${BACKUP_FILE:-\$BACKUP_DIR/auto-\$STAMP.sql.gz.enc}"
mkdir -p "\$BACKUP_DIR"
if [ "\$#" -gt 0 ]; then
  mariadb-dump --single-transaction --quick --routines --events --databases "\$@" | gzip | openssl enc -aes-256-cbc -salt -pbkdf2 -pass pass:${MASTER_BACKUP_KEY} -out "\$OUT_FILE"
else
  mariadb-dump --all-databases --single-transaction --quick --routines --events | gzip | openssl enc -aes-256-cbc -salt -pbkdf2 -pass pass:${MASTER_BACKUP_KEY} -out "\$OUT_FILE"
fi
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
Agent Path Restriction: ${HUB_IP}
phpMyAdmin Alias: ${PMA_ALIAS}
Backup Directory: /var/backups/mariadb
EOF
  echo -e "\n${CLR_BOLD}${CLR_GREEN}Enterprise Node Online!${RESET:-}"
}

main() {
  clear; require_ubuntu; wizard; install_packages; configure_mariadb; configure_phpmyadmin; deploy_agent; systemctl restart apache2; configure_firewall; write_backup_script; write_summary
}

main "$@"
