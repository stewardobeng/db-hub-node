#!/usr/bin/env bash
set -Eeuo pipefail

# CloudDB SaaS HUB v5.0 (High-End Dark Edition)
# Complete SaaS: Landing Page, Paystack, Brute-Force Shield, Watchdog, Resource Quotas.
# Cyber-Industrial UI with high contrast and professional layout.

# --- Colors & Styles ---
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_RED="\033[0;31m"
CLR_GREEN="\033[0;32m"
CLR_YELLOW="\033[0;33m"
CLR_BLUE="\033[0;34m"
CLR_CYAN="\033[0;36m"

sed_escape() { printf '%s' "$1" | sed -e 's/[|&\\]/\\&/g'; }

msg_header() { echo -e "\n${CLR_BOLD}${CLR_CYAN}=== $* ===${CLR_RESET}"; }
msg_info()   { echo -e "${CLR_BLUE}[i]${CLR_RESET} $*"; }
msg_ok()     { echo -e "${CLR_GREEN}[âœ”]${CLR_RESET} $*"; }
msg_warn()   { echo -e "${CLR_YELLOW}[!]${CLR_RESET} $*"; }
msg_err()    { echo -e "${CLR_RED}[âœ˜]${CLR_RESET} $*"; }

if [[ ${EUID:-0} -ne 0 ]]; then msg_err "Run as root."; exit 1; fi

export DEBIAN_FRONTEND=noninteractive
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HUB_ROOT="/var/www/db-hub"
SUMMARY_FILE="/root/db-hub-install-summary.txt"

# Defaults
: "${SITE_FQDN:=_}"
: "${HUB_ALIAS:=db-hub}"
: "${HUB_ADMIN_USER:=admin}"
: "${ADMIN_EMAIL:=}"
: "${PAYSTACK_SECRET:=}"
: "${PAYSTACK_CURRENCY:=NGN}"
: "${SMTP_HOST:=}"
: "${SMTP_PORT:=587}"
: "${SMTP_USER:=}"
: "${SMTP_PASS:=}"
: "${SMTP_FROM:=noreply@clouddb.io}"

HUB_ADMIN_PASS="$(openssl rand -base64 12 | tr -d '\n')"
CSRF_SECRET="$(openssl rand -hex 32)"
SSL_READY=0
SSL_MANUAL_COMMAND=""

valid_fqdn() {
    local host="${1:-}"
    [[ -n "$host" && "$host" != "_" ]] || return 1
    [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

hub_access_url() {
    if valid_fqdn "$SITE_FQDN"; then
        if [[ $SSL_READY -eq 1 ]]; then
            echo "https://${SITE_FQDN}"
        else
            echo "http://${SITE_FQDN}"
        fi
        return
    fi
    local host_ip
    host_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    host_ip="${host_ip:-localhost}"
    echo "http://${host_ip}/${HUB_ALIAS}"
}

ssl_manual_command() {
    local email="${ADMIN_EMAIL:-YOUR_EMAIL@example.com}"
    printf 'certbot --apache -d %s -m %s --agree-tos --no-eff-email --redirect' "$SITE_FQDN" "$email"
}

wizard() {
    echo -e "${CLR_BOLD}${CLR_CYAN}===================================================="
    echo "       CloudDB HUB v5.0: GLOBAL AUTOMATION        "
    echo -e "====================================================${CLR_RESET}"
    read -p "FQDN (e.g. hub.steprotech.com): " input_fqdn; SITE_FQDN=${input_fqdn:-$SITE_FQDN}
    read -p "Admin Alert Email: " input_admin_email; ADMIN_EMAIL=${input_admin_email:-$ADMIN_EMAIL}
    read -p "Paystack Secret (leave blank to disable billing): " input_paystack; PAYSTACK_SECRET=${input_paystack:-$PAYSTACK_SECRET}
    read -p "Paystack Currency [$PAYSTACK_CURRENCY]: " input_currency; PAYSTACK_CURRENCY=${input_currency:-$PAYSTACK_CURRENCY}
    msg_header "SMTP Notification Config"
    read -p "SMTP Host [$SMTP_HOST]: " input_host; SMTP_HOST=${input_host:-$SMTP_HOST}
    read -p "SMTP Port [$SMTP_PORT]: " input_port; SMTP_PORT=${input_port:-$SMTP_PORT}
    [[ "$SMTP_PORT" =~ ^[0-9]+$ ]] || SMTP_PORT=587
    read -p "SMTP User: " input_smtp_user; SMTP_USER=${input_smtp_user:-$SMTP_USER}
    read -p "SMTP Pass: " input_smtp_pass; SMTP_PASS=${input_smtp_pass:-$SMTP_PASS}
    read -p "SMTP From [$SMTP_FROM]: " input_from; SMTP_FROM=${input_from:-$SMTP_FROM}
    echo -e "\n${CLR_BOLD}${CLR_YELLOW}Deploy Dark Hub v5.0? (y/n): ${CLR_RESET}"
    read -p "" confirm; if [[ ! "$confirm" =~ ^[Yy]$ ]]; then exit 0; fi
}

install_packages() {
  msg_header "Finalizing Hub Stack"
  apt-get update >/dev/null 2>&1
  apt-get install -y apache2 libapache2-mod-php php php-cli php-mysql php-curl php-sqlite3 php-mbstring php-xml unzip curl openssl ufw cron certbot python3-certbot-apache >/dev/null 2>&1
}

deploy_hub() {
  local app_src="$SCRIPT_DIR/app/hub"
  local hub_public="$HUB_ROOT/public"

  msg_header "Deploying Premium Dashboard"
  [[ -d "$app_src" ]] || { msg_err "Bundled Hub app not found at $app_src"; exit 1; }

  HUB_ADMIN_HASH=$(php -r "echo password_hash('$HUB_ADMIN_PASS', PASSWORD_DEFAULT);")

  rm -rf "$HUB_ROOT"
  mkdir -p "$HUB_ROOT/storage"
  cp -a "$app_src/." "$HUB_ROOT/"

  cat >"$HUB_ROOT/.env" <<EOF
APP_NAME=CloudDB
APP_ENV=production
ADMIN_USER=${HUB_ADMIN_USER}
ADMIN_HASH=${HUB_ADMIN_HASH}
ADMIN_EMAIL=${ADMIN_EMAIL}
APP_SECRET=${CSRF_SECRET}
PAYSTACK_SECRET=${PAYSTACK_SECRET}
PAYSTACK_CURRENCY=${PAYSTACK_CURRENCY}
SMTP_HOST=${SMTP_HOST}
SMTP_PORT=${SMTP_PORT}
SMTP_USER=${SMTP_USER}
SMTP_PASS=${SMTP_PASS}
SMTP_FROM=${SMTP_FROM}
STORAGE_PATH=${HUB_ROOT}/storage
HUB_DB_PATH=${HUB_ROOT}/storage/hub_v5.sqlite
EOF

  touch "$HUB_ROOT/storage/hub_v5.sqlite"
  chown -R www-data:www-data "$HUB_ROOT"
  find "$HUB_ROOT" -type d -exec chmod 750 {} \;
  find "$HUB_ROOT" -type f -exec chmod 640 {} \;
  chmod 660 "$HUB_ROOT/storage/hub_v5.sqlite"

  if valid_fqdn "$SITE_FQDN"; then
    cat >"/etc/apache2/sites-available/db-hub-site.conf" <<APACHE
<VirtualHost *:80>
    ServerName ${SITE_FQDN}
    DocumentRoot ${hub_public}
    DirectoryIndex index.php

    <Directory ${hub_public}>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    Alias /${HUB_ALIAS} ${hub_public}

    ErrorLog \${APACHE_LOG_DIR}/db-hub-error.log
    CustomLog \${APACHE_LOG_DIR}/db-hub-access.log combined
</VirtualHost>
APACHE
    a2dissite 000-default >/dev/null 2>&1 || true
    a2ensite db-hub-site >/dev/null 2>&1 || true
    a2disconf db-hub >/dev/null 2>&1 || true
    rm -f /etc/apache2/conf-available/db-hub.conf /etc/apache2/conf-enabled/db-hub.conf
  else
    a2dissite db-hub-site >/dev/null 2>&1 || true
    a2dissite db-hub-site-le-ssl >/dev/null 2>&1 || true
    rm -f /etc/apache2/sites-available/db-hub-site.conf /etc/apache2/sites-enabled/db-hub-site.conf
    rm -f /etc/apache2/sites-available/db-hub-site-le-ssl.conf /etc/apache2/sites-enabled/db-hub-site-le-ssl.conf
    cat >"/etc/apache2/conf-available/db-hub.conf" <<APACHE
Alias /${HUB_ALIAS} ${hub_public}
<Directory ${hub_public}>
    Options FollowSymLinks
    AllowOverride All
    Require all granted
    DirectoryIndex index.php
</Directory>
APACHE
    a2enconf db-hub >/dev/null 2>&1 || true
  fi

  local php_version
  php_version=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
  a2enmod "php${php_version}" >/dev/null 2>&1 || true
  a2enmod rewrite headers ssl >/dev/null 2>&1 || true
  systemctl restart apache2

  local watchdog_cmd
  if valid_fqdn "$SITE_FQDN"; then
    watchdog_cmd="curl -fsS -H 'Host: ${SITE_FQDN}' http://127.0.0.1/index.php?action=watchdog >/dev/null 2>&1"
  else
    watchdog_cmd="curl -fsS http://127.0.0.1/${HUB_ALIAS}/index.php?action=watchdog >/dev/null 2>&1"
  fi
  (crontab -l 2>/dev/null | grep -v "index.php?action=watchdog" || true; echo "*/10 * * * * ${watchdog_cmd}") | crontab -
}

configure_firewall() {
  ufw allow OpenSSH; ufw allow 'Apache Full'; ufw --force enable
}

install_ssl_certificate() {
  SSL_READY=0
  SSL_MANUAL_COMMAND=""

  if ! valid_fqdn "$SITE_FQDN"; then
    msg_warn "Skipping automatic HTTPS: no valid FQDN was provided."
    return
  fi

  SSL_MANUAL_COMMAND="$(ssl_manual_command)"

  if [[ -z "$ADMIN_EMAIL" ]]; then
    msg_warn "Skipping automatic HTTPS: admin alert email is blank."
    msg_info "Manual TLS command: ${SSL_MANUAL_COMMAND}"
    return
  fi

  msg_header "Configuring HTTPS"
  if certbot --apache -d "$SITE_FQDN" -m "$ADMIN_EMAIL" --agree-tos --no-eff-email --redirect --non-interactive > /root/db-hub-certbot.log 2>&1; then
    SSL_READY=1
    msg_ok "HTTPS enabled for https://${SITE_FQDN}"
    rm -f /root/db-hub-certbot.log
  else
    msg_warn "Automatic HTTPS setup failed. Review /root/db-hub-certbot.log and run:"
    echo "  ${SSL_MANUAL_COMMAND}"
  fi
}

write_summary() {
  local access_url tls_status tls_extra
  access_url="$(hub_access_url)"
  if [[ $SSL_READY -eq 1 ]]; then
    tls_status="enabled automatically"
    tls_extra=""
  elif valid_fqdn "$SITE_FQDN"; then
    if [[ -n "$ADMIN_EMAIL" ]]; then
      tls_status="automatic setup failed; run the command below after DNS/port checks"
    else
      tls_status="not attempted automatically; provide an admin email and run the command below"
    fi
    tls_extra="TLS Command: ${SSL_MANUAL_COMMAND}"
  else
    tls_status="skipped; install with a valid FQDN to enable HTTPS"
    tls_extra=""
  fi
  cat > "$SUMMARY_FILE" <<EOF
CLOUDDB HUB v5.0 DEPLOYED (Enterprise Dark UI)
Access: ${access_url}
TLS: ${tls_status}
${tls_extra}
Admin Identity: ${HUB_ADMIN_USER}
Access Key: ${HUB_ADMIN_PASS}
Admin Alerts: ${ADMIN_EMAIL:-disabled}
Billing Currency: ${PAYSTACK_CURRENCY}
SaaS Features: ENABLED
Security: ENTERPRISE HARDENED
EOF
  echo -e "\n${CLR_BOLD}${CLR_GREEN}Premium Dark Hub Interface Active!${CLR_RESET}"
  echo -e "Access URL:      ${CLR_YELLOW}$(hub_access_url)${CLR_RESET}"
  echo -e "Admin Identity: ${CLR_YELLOW}${HUB_ADMIN_USER}${CLR_RESET}"
  echo -e "Access Key:     ${CLR_YELLOW}${HUB_ADMIN_PASS}${CLR_RESET}\n"
  if [[ $SSL_READY -eq 0 && -n "$SSL_MANUAL_COMMAND" ]]; then
    msg_warn "Automatic HTTPS is not active yet."
    msg_info "Manual TLS command: ${SSL_MANUAL_COMMAND}"
  fi
  msg_info "Full credentials saved to: ${CLR_BOLD}${SUMMARY_FILE}${CLR_RESET}"
}

main() { clear; wizard; install_packages; deploy_hub; systemctl restart apache2; configure_firewall; install_ssl_certificate; write_summary; }
main "$@"
