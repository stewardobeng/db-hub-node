#!/usr/bin/env bash
set -Eeuo pipefail

# DB Platform UNIVERSAL Uninstaller
# Safely removes both Hub and Node components from an Ubuntu system.

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
    wait "$pid" && msg_ok "$msg" || msg_warn "$msg skipped (already gone)"
}

if [[ ${EUID:-0} -ne 0 ]]; then
  msg_err "Run this script as root."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# --- Warning & Confirmation ---
clear
echo -e "${CLR_BOLD}${CLR_RED}"
echo "===================================================="
echo "       DANGER: UNIVERSAL PLATFORM UNINSTALLER      "
echo "===================================================="
echo -e "${CLR_RESET}"
echo -e "This script will PERMANENTLY remove:"
echo "  - Central Management Hub (Dashboard & SQLite Data)"
echo "  - Database Node Components (MariaDB & Agent API)"
echo "  - ALL Databases and Tenant Users"
echo "  - SSL Certificates and Apache Configs"
echo -e "\n${CLR_BOLD}${CLR_YELLOW}This action cannot be undone.${CLR_RESET}"

read -p "$(echo -e "\n${CLR_BOLD}Are you absolutely sure you want to proceed? (y/n): ${CLR_RESET}")" confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    msg_info "Uninstallation cancelled."
    exit 0
fi

msg_header "Stopping Services"
run_with_spinner "Stopping Apache2" systemctl stop apache2
run_with_spinner "Stopping MariaDB" systemctl stop mariadb

msg_header "Removing Web Configurations"
# Disable all possible aliases
for conf in db-hub db-agent phpmyadmin fqdn dbcreator; do
    run_with_spinner "Disabling $conf" a2disconf "$conf"
    run_with_spinner "Deleting $conf.conf" rm -f "/etc/apache2/conf-available/$conf.conf"
done
run_with_spinner "Cleaning password files" rm -f /etc/apache2/.htpasswd-*

msg_header "Removing Packages"
run_with_spinner "Purging phpMyAdmin" apt-get purge -y phpmyadmin
run_with_spinner "Purging MariaDB" apt-get purge -y mariadb-server mariadb-client mariadb-common
run_with_spinner "Purging Apache2" apt-get purge -y apache2 apache2-utils apache2-bin
run_with_spinner "Purging Certbot" apt-get purge -y certbot python3-certbot-apache
run_with_spinner "Auto-removing dependencies" apt-get autoremove -y
run_with_spinner "Cleaning apt cache" apt-get autoclean

msg_header "Deleting Files & Data"
run_with_spinner "Removing Hub Application" rm -rf /var/www/db-hub
run_with_spinner "Removing Node Agent" rm -rf /var/www/db-agent
run_with_spinner "Removing Old Creator App" rm -rf /var/www/dbcreator
run_with_spinner "Removing Database Storage" rm -rf /var/lib/mysql /etc/mysql
run_with_spinner "Removing Backups" rm -rf /var/backups/mariadb
run_with_spinner "Removing Installation Logs" rm -f /root/db-*-install-summary.txt /root/*-http-auth.txt

msg_header "Cleaning up Tasks"
run_with_spinner "Removing backup script" rm -f /usr/local/sbin/db-platform-backup.sh
run_with_spinner "Removing cron jobs" bash -c "crontab -l 2>/dev/null | grep -v 'db-platform-backup.sh' | crontab - || true"

msg_header "Resetting Firewall"
if ufw status | grep -q "active"; then
    run_with_spinner "Removing Apache rule" ufw delete allow 'Apache Full'
    msg_warn "UFW is still active. SSH access remains open."
fi

echo -e "\n${CLR_BOLD}${CLR_GREEN}===================================================="
echo "       Uninstallation Completed Successfully!         "
echo -e "====================================================${CLR_RESET}\n"
msg_info "The system is now completely clean."
