#!/usr/bin/env bash
set -Eeuo pipefail

# DB Platform NODE Installer (Database + Agent API)
# This script installs MariaDB and a lightweight Agent for the Central Hub.

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

# --- Initialization ---
if [[ ${EUID:-0} -ne 0 ]]; then
  msg_err "Run this script as root."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

AGENT_ROOT="/var/www/db-agent"
MARIADB_CNF="/etc/mysql/mariadb.conf.d/50-server.cnf"
SUMMARY_FILE="/root/db-node-install-summary.txt"

# Default values
: "${HUB_IP:=0.0.0.0/0}"
: "${SITE_FQDN:=_}"
: "${PMA_ALIAS:=phpmyadmin}"
: "${LETSENCRYPT_EMAIL:=}"

PROVISIONER_DB_USER="dbprovisioner"
PROVISIONER_DB_PASS="$(openssl rand -base64 24 | tr -d '\n')"
AGENT_API_KEY="$(openssl rand -hex 32)"

# --- Wizard ---
wizard() {
    echo -e "${CLR_BOLD}${CLR_CYAN}"
    echo "===================================================="
    echo "       DB Platform NODE Installation Wizard        "
    echo "===================================================="
    echo -e "${CLR_RESET}"

    read -p "$(echo -e "${CLR_BOLD}Enter Central Hub IP (to restrict access) [${HUB_IP}]: ${CLR_RESET}")" input_hub
    HUB_IP=${input_hub:-$HUB_IP}

    read -p "$(echo -e "${CLR_BOLD}Enter Node Domain (optional) [${SITE_FQDN}]: ${CLR_RESET}")" input_fqdn
    SITE_FQDN=${input_fqdn:-$SITE_FQDN}

    read -p "$(echo -e "${CLR_BOLD}Enter SSL Email (optional): ${CLR_RESET}")" input_email
    LETSENCRYPT_EMAIL=${input_email:-$LETSENCRYPT_EMAIL}

    echo -e "\n${CLR_BOLD}${CLR_YELLOW}Ready to install Node components? (y/n): ${CLR_RESET}")" confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        msg_warn "Installation cancelled."
        exit 0
    fi
}

require_ubuntu() {
  if [[ ! -f /etc/os-release ]]; then
    msg_err "Cannot detect OS."
    exit 1
  fi
  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" ]]; then
    msg_err "This installer targets Ubuntu only."
    exit 1
  fi
}

install_packages() {
  msg_header "Installing Node Dependencies"
  run_with_spinner "Updating package index" apt-get update
  run_with_spinner "Installing core packages" apt-get install -y \
    apache2 \
    mariadb-server mariadb-client \
    php libapache2-mod-php php-cli php-mysql php-curl php-zip php-xml php-mbstring php-json \
    phpmyadmin \
    certbot python3-certbot-apache \
    unzip curl openssl ufw cron
}

configure_mariadb() {
  msg_header "Configuring MariaDB"
  run_with_spinner "Enabling and starting MariaDB" systemctl enable mariadb
  systemctl start mariadb

  # Node must allow remote access from the Hub
  if [[ -f "$MARIADB_CNF" ]]; then
    sed -i "s/^[# ]*bind-address.*/bind-address = 0.0.0.0/" "$MARIADB_CNF"
  fi
  run_with_spinner "Applying MariaDB configuration" systemctl restart mariadb

  msg_info "Creating Provisioner user"
  mysql <<SQL
CREATE USER IF NOT EXISTS '${PROVISIONER_DB_USER}'@'%' IDENTIFIED BY '${PROVISIONER_DB_PASS}';
GRANT ALL PRIVILEGES ON *.* TO '${PROVISIONER_DB_USER}'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
}

configure_phpmyadmin() {
  msg_header "Configuring phpMyAdmin"
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
  msg_header "Deploying Agent API"
  mkdir -p "$AGENT_ROOT"
  
  cat >"$AGENT_ROOT/agent.php" <<'PHPAGENT'
<?php
declare(strict_types=1);
const API_KEY = '__API_KEY__';
const PROV_USER = '__PROV_USER__';
const PROV_PASS = '__PROV_PASS__';

if (($_GET['key'] ?? '') !== API_KEY) {
    http_response_code(403); die('Forbidden');
}

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
        // RAM
        $free = 0; $total = 0;
        if (is_readable('/proc/meminfo')) {
            $mem = file_get_contents('/proc/meminfo');
            if (preg_match('/MemTotal:\s+(\d+)/', $mem, $m)) $total = (int)$m[1];
            if (preg_match('/MemAvailable:\s+(\d+)/', $mem, $m)) $free = (int)$m[1];
        }
        $ram_usage = $total > 0 ? round((($total - $free) / $total) * 100) : 0;
        
        // CPU
        $load = sys_getloadavg();
        $cpu_usage = min(100, round(($load[0] / (int)shell_exec('nproc')) * 100));

        $res = [
            'cpu' => $cpu_usage,
            'ram' => $ram_usage,
            'ram_text' => round(($total - $free)/1024/1024, 1) . 'GB / ' . round($total/1024/1024, 1) . 'GB',
            'disk' => round(((disk_total_space('/') - disk_free_space('/')) / disk_total_space('/')) * 100),
            'disk_text' => round(disk_free_space('/')/1024/1024/1024, 1) . 'GB Free',
            'active_conns' => (int)$pdo->query("SHOW STATUS LIKE 'Threads_connected'")->fetch()['Value']
        ];

    } elseif ($action === 'list_tenants') {
        $sql = "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME LIKE '%\_%' AND SCHEMA_NAME NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')";
        foreach ($pdo->query($sql) as $r) {
            $db = $r['SCHEMA_NAME'];
            $prefix = explode('_', $db)[0];
            $u = $prefix . '_user';
            $stmt = $pdo->prepare("SELECT User, Host FROM mysql.user WHERE User = ?");
            $stmt->execute([$u]);
            $res[] = ['db' => $db, 'user' => $u, 'users' => $stmt->fetchAll()];
        }

    } elseif ($action === 'create') {
        $prefix = $_POST['db_prefix'];
        $suffix = $_POST['db_suffix'];
        $host = $_POST['remote_host'];
        $dbName = $prefix . '_' . $suffix;
        $dbUser = $prefix . '_user';
        $dbPass = bin2hex(random_bytes(12));

        $pdo->exec("CREATE DATABASE `$dbName` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci");
        
        $check = $pdo->prepare("SELECT User FROM mysql.user WHERE User = ? AND Host = ?");
        $check->execute([$dbUser, $host]);
        $exists = $check->fetch();

        if (!$exists) {
            $pdo->exec("CREATE USER '$dbUser'@'$host' IDENTIFIED BY '$dbPass'");
            if ($host !== 'localhost') $pdo->exec("CREATE USER IF NOT EXISTS '$dbUser'@'localhost' IDENTIFIED BY '$dbPass'");
        }
        
        $pdo->exec("GRANT ALL PRIVILEGES ON `$dbName`.* TO '$dbUser'@'$host'");
        if ($host !== 'localhost') $pdo->exec("GRANT ALL PRIVILEGES ON `$dbName`.* TO '$dbUser'@'localhost'");
        
        $res = [
            'message' => "Database $dbName created.",
            'download' => [
                'filename' => $dbName . '.env',
                'content' => "DB_DATABASE=$dbName\nDB_USERNAME=$dbUser\nDB_PASSWORD=" . ($exists ? "(Existing)" : $dbPass)
            ]
        ];

    } elseif ($action === 'rotate') {
        $u = $_POST['db_user'];
        $h = $_POST['db_host'];
        $p = bin2hex(random_bytes(12));
        $pdo->exec("ALTER USER '$u'@'$h' IDENTIFIED BY '$p'");
        $res = ['message' => "Password rotated.", 'download' => ['filename' => $u . '_new.env', 'content' => "USER=$u\nPASS=$p"]];

    } elseif ($action === 'delete') {
        $db = $_POST['db_name'];
        $pdo->exec("DROP DATABASE IF EXISTS `$db` text");
        $res = ['message' => "Database deleted."];
    }

} catch (Exception $e) {
    http_response_code(500);
    $res = ['error' => $e->getMessage()];
}

header('Content-Type: application/json');
echo json_encode($res);
PHPAGENT

  sed -i "s|__API_KEY__|${AGENT_API_KEY}|g" "$AGENT_ROOT/agent.php"
  sed -i "s|__PROV_USER__|${PROVISIONER_DB_USER}|g" "$AGENT_ROOT/agent.php"
  sed -i "s|__PROV_PASS__|${PROVISIONER_DB_PASS}|g" "$AGENT_ROOT/agent.php"
  
  cat >/etc/apache2/conf-available/db-agent.conf <<APACHE
Alias /agent-api ${AGENT_ROOT}
<Directory ${AGENT_ROOT}>
    Require all granted
</Directory>
APACHE
  a2enconf db-agent >/dev/null 2>&1 || true
  msg_ok "Agent API Bridge deployed"
}

configure_firewall() {
  msg_header "Configuring Firewall"
  run_with_spinner "Allowing SSH" ufw allow OpenSSH
  run_with_spinner "Allowing HTTP/HTTPS" ufw allow 'Apache Full'
  run_with_spinner "Allowing Remote MariaDB (3306)" ufw allow 3306/tcp
  run_with_spinner "Enabling Firewall" ufw --force enable
}

write_summary() {
  cat > "$SUMMARY_FILE" <<EOF
DB NODE INSTALLATION COMPLETE
Agent API Key: ${AGENT_API_KEY}
Provisioner User: ${PROVISIONER_DB_USER}
Provisioner Pass: ${PROVISIONER_DB_PASS}
EOF
  echo -e "\n${CLR_BOLD}${CLR_GREEN}Node ready!${CLR_RESET}"
  echo -e "Agent API Key: ${CLR_YELLOW}${AGENT_API_KEY}${CLR_RESET}"
}

main() {
  clear
  require_ubuntu
  wizard
  install_packages
  configure_mariadb
  configure_phpmyadmin
  deploy_agent
  systemctl restart apache2
  configure_firewall
  write_summary
}

main "$@"
