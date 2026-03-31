#!/usr/bin/env bash
set -Eeuo pipefail

# CloudDB NODE Installer v5.0 (Enterprise Scaling Edition)
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
msg_ok()     { echo -e "${CLR_GREEN}[âœ”]${CLR_RESET} $*"; }
msg_warn()   { echo -e "${CLR_YELLOW}[!]${CLR_RESET} $*"; }
msg_err()    { echo -e "${CLR_RED}[âœ˜]${CLR_RESET} $*"; }

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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

AGENT_ROOT="/var/www/db-agent"
MARIADB_CNF="/etc/mysql/mariadb.conf.d/50-server.cnf"
SUMMARY_FILE="/root/db-node-install-summary.txt"

: "${HUB_IP:=any}"
: "${SITE_FQDN:=_}"
: "${PMA_ALIAS:=phpmyadmin}"
: "${LETSENCRYPT_EMAIL:=}"
: "${BACKUP_SCHEDULE:=0 2 * * *}"
: "${BACKUP_RETENTION_DAYS:=30}"
: "${BACKUP_SYNC_TARGET:=remote:backup}"

PROVISIONER_DB_USER="dbprovisioner"
PROVISIONER_DB_PASS="$(openssl rand -base64 24 | tr -d '\n')"
AGENT_API_KEY="$(openssl rand -hex 32)"
MASTER_BACKUP_KEY="$(openssl rand -hex 16)"
AGENT_REQUIRE_DIRECTIVE="Require all granted"
PMA_CONTROL_DB="phpmyadmin"
PMA_CONTROL_USER="pma_clouddb"
PMA_CONTROL_PASS="$(openssl rand -hex 16)"
BACKUP_SCRIPT_PATH="/usr/local/sbin/db-platform-backup.sh"
BACKUP_ENGINE_DIR="/etc/clouddb"
BACKUP_DB_CNF="${BACKUP_ENGINE_DIR}/backup-mysql.cnf"
BACKUP_LOG_FILE="/var/log/clouddb-backup.log"

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
    echo "         CloudDB NODE v5.0: ENTERPRISE SCALE        "
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
  local pma_schema=""
  if [[ -f /usr/share/phpmyadmin/sql/create_tables.sql ]]; then
    pma_schema="/usr/share/phpmyadmin/sql/create_tables.sql"
  elif [[ -f /usr/share/dbconfig-common/data/phpmyadmin/install/mysql ]]; then
    pma_schema="/usr/share/dbconfig-common/data/phpmyadmin/install/mysql"
  fi

  mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`${PMA_CONTROL_DB}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${PMA_CONTROL_USER}'@'localhost' IDENTIFIED BY '${PMA_CONTROL_PASS}';
ALTER USER '${PMA_CONTROL_USER}'@'localhost' IDENTIFIED BY '${PMA_CONTROL_PASS}';
GRANT SELECT, INSERT, UPDATE, DELETE ON \`${PMA_CONTROL_DB}\`.* TO '${PMA_CONTROL_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

  if [[ -n "$pma_schema" ]]; then
    if [[ "$(mysql -Nse "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '${PMA_CONTROL_DB}' AND table_name = 'pma__bookmark'")" == "0" ]]; then
      mysql "${PMA_CONTROL_DB}" < "$pma_schema"
    fi
  else
    msg_warn "phpMyAdmin storage schema file was not found. Configuration storage may remain limited."
  fi

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
    $cfg['Servers'][$i]['controlhost'] = 'localhost';
    $cfg['Servers'][$i]['controluser'] = '__PMA_CONTROL_USER__';
    $cfg['Servers'][$i]['controlpass'] = '__PMA_CONTROL_PASS__';
    $cfg['Servers'][$i]['pmadb'] = '__PMA_CONTROL_DB__';
    $cfg['Servers'][$i]['bookmarktable'] = 'pma__bookmark';
    $cfg['Servers'][$i]['relation'] = 'pma__relation';
    $cfg['Servers'][$i]['table_info'] = 'pma__table_info';
    $cfg['Servers'][$i]['table_coords'] = 'pma__table_coords';
    $cfg['Servers'][$i]['pdf_pages'] = 'pma__pdf_pages';
    $cfg['Servers'][$i]['column_info'] = 'pma__column_info';
    $cfg['Servers'][$i]['history'] = 'pma__history';
    $cfg['Servers'][$i]['table_uiprefs'] = 'pma__table_uiprefs';
    $cfg['Servers'][$i]['tracking'] = 'pma__tracking';
    $cfg['Servers'][$i]['userconfig'] = 'pma__userconfig';
    $cfg['Servers'][$i]['recent'] = 'pma__recent';
    $cfg['Servers'][$i]['favorite'] = 'pma__favorite';
    $cfg['Servers'][$i]['users'] = 'pma__users';
    $cfg['Servers'][$i]['usergroups'] = 'pma__usergroups';
    $cfg['Servers'][$i]['navigationhiding'] = 'pma__navigationhiding';
    $cfg['Servers'][$i]['savedsearches'] = 'pma__savedsearches';
    $cfg['Servers'][$i]['central_columns'] = 'pma__central_columns';
    $cfg['Servers'][$i]['designer_settings'] = 'pma__designer_settings';
    $cfg['Servers'][$i]['export_templates'] = 'pma__export_templates';
    $cfg['Servers'][$i]['hide_db'] = '^(information_schema|performance_schema|mysql|sys|phpmyadmin)$';
}
PMACONF
  sed -i "s|__PMA_CONTROL_USER__|$(sed_escape "$PMA_CONTROL_USER")|g" /etc/phpmyadmin/conf.d/90-db-platform.php
  sed -i "s|__PMA_CONTROL_PASS__|$(sed_escape "$PMA_CONTROL_PASS")|g" /etc/phpmyadmin/conf.d/90-db-platform.php
  sed -i "s|__PMA_CONTROL_DB__|$(sed_escape "$PMA_CONTROL_DB")|g" /etc/phpmyadmin/conf.d/90-db-platform.php
  a2enconf phpmyadmin >/dev/null 2>&1 || true
}

deploy_agent() {
  local app_src="$SCRIPT_DIR/app/node"
  local agent_public="$AGENT_ROOT/public"

  msg_header "Deploying Agent API v5.0"
  [[ -d "$app_src" ]] || { msg_err "Bundled Node app not found at $app_src"; exit 1; }

  rm -rf "$AGENT_ROOT"
  mkdir -p "$AGENT_ROOT/storage"
  cp -a "$app_src/." "$AGENT_ROOT/"

  cat >"$AGENT_ROOT/.env" <<EOF
APP_NAME=CloudDB Node
API_KEY=${AGENT_API_KEY}
PROV_USER=${PROVISIONER_DB_USER}
PROV_PASS=${PROVISIONER_DB_PASS}
NODE_DB_DSN=mysql:host=localhost;dbname=information_schema
STORAGE_PATH=${AGENT_ROOT}/storage
BACKUP_DIR=/var/backups/mariadb
BACKUP_SCRIPT=${BACKUP_SCRIPT_PATH}
BACKUP_DB_CNF=${BACKUP_DB_CNF}
BACKUP_LOG=${BACKUP_LOG_FILE}
BACKUP_KEY=${MASTER_BACKUP_KEY}
BACKUP_RETENTION_DAYS=${BACKUP_RETENTION_DAYS}
BACKUP_SYNC_TARGET=${BACKUP_SYNC_TARGET}
EOF

  chown -R www-data:www-data "$AGENT_ROOT"
  find "$AGENT_ROOT" -type d -exec chmod 750 {} \;
  find "$AGENT_ROOT" -type f -exec chmod 640 {} \;

  cat >/etc/apache2/conf-available/db-agent.conf <<APACHE
Alias /agent-api ${agent_public}
<Directory ${agent_public}>
    Options FollowSymLinks
    AllowOverride None
    DirectoryIndex agent.php
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
  local backup_template="$SCRIPT_DIR/app/node/bin/backup-engine.sh"

  msg_header "Configuring Backup Engine"
  [[ -f "$backup_template" ]] || { msg_err "Bundled backup engine not found at $backup_template"; exit 1; }
  mkdir -p /var/backups/mariadb "$BACKUP_ENGINE_DIR"
  chown root:www-data /var/backups/mariadb "$BACKUP_ENGINE_DIR"
  chmod 2770 /var/backups/mariadb
  chmod 750 "$BACKUP_ENGINE_DIR"

  cat >"$BACKUP_DB_CNF" <<EOF
[client]
user=${PROVISIONER_DB_USER}
password=${PROVISIONER_DB_PASS}
host=localhost
EOF
  chown root:www-data "$BACKUP_DB_CNF"
  chmod 640 "$BACKUP_DB_CNF"

  touch "$BACKUP_LOG_FILE"
  chown root:www-data "$BACKUP_LOG_FILE"
  chmod 660 "$BACKUP_LOG_FILE"

  install -o root -g www-data -m 750 "$backup_template" "$BACKUP_SCRIPT_PATH"
  sed -i 's/\r$//' "$BACKUP_SCRIPT_PATH"
  chown root:www-data "$BACKUP_SCRIPT_PATH"
  chmod 750 "$BACKUP_SCRIPT_PATH"
  systemctl enable cron >/dev/null 2>&1; systemctl start cron
  (crontab -l 2>/dev/null | grep -v 'CloudDB backup schedule' || true; echo "${BACKUP_SCHEDULE} ${BACKUP_SCRIPT_PATH} # CloudDB backup schedule") | crontab -
}

write_summary() {
  cat > "$SUMMARY_FILE" <<EOF
CLOUDDB NODE v5.0 SUCCESSFUL
Agent Key: ${AGENT_API_KEY}
Backup Key: ${MASTER_BACKUP_KEY}
Provisioner: ${PROVISIONER_DB_USER}
Agent Path Restriction: ${HUB_IP}
phpMyAdmin Alias: ${PMA_ALIAS}
Backup Directory: /var/backups/mariadb
Backup Schedule: ${BACKUP_SCHEDULE}
Backup Log: ${BACKUP_LOG_FILE}
EOF
  echo -e "\n${CLR_BOLD}${CLR_GREEN}CloudDB Node Online!${RESET:-}"
}

main() {
  clear; require_ubuntu; wizard; install_packages; configure_mariadb; write_backup_script; configure_phpmyadmin; deploy_agent; systemctl restart apache2; configure_firewall; write_summary
}

main "$@"
