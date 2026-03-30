#!/usr/bin/env bash
set -Eeuo pipefail

# DB Platform Uninstaller for Ubuntu 24.04/22.04
# Safely removes all components installed by install-db-platform.sh.

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
    wait "$pid" && msg_ok "$msg" || msg_warn "$msg failed or was already removed"
}

# --- Initialization ---
if [[ ${EUID:-0} -ne 0 ]]; then
  msg_err "Run this script as root."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# --- Warning & Confirmation ---
clear
echo -e "${CLR_BOLD}${CLR_RED}"
echo "===================================================="
echo "       DANGER: DB PLATFORM UNINSTALLER             "
echo "===================================================="
echo -e "${CLR_RESET}"
echo -e "This script will PERMANENTLY delete:"
echo "  - All MariaDB databases and users"
echo "  - phpMyAdmin configuration"
echo "  - DB Creator application and logs"
echo "  - Apache configurations"
echo "  - SSL certificates (Let's Encrypt)"
echo "  - Database backups"
echo -e "\n${CLR_BOLD}${CLR_YELLOW}This action cannot be undone.${CLR_RESET}"

read -p "$(echo -e "\n${CLR_BOLD}Are you absolutely sure you want to proceed? (y/n): ${CLR_RESET}")" confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    msg_info "Uninstallation cancelled."
    exit 0
fi

# --- Uninstall Phases ---

msg_header "Stopping Services"
run_with_spinner "Stopping Apache2" systemctl stop apache2
run_with_spinner "Stopping MariaDB" systemctl stop mariadb

msg_header "Removing Apache Configurations"
run_with_spinner "Disabling dbcreator" a2disconf dbcreator
run_with_spinner "Disabling phpmyadmin" a2disconf phpmyadmin
run_with_spinner "Disabling fqdn config" a2disconf fqdn
run_with_spinner "Removing config files" rm -f /etc/apache2/conf-available/dbcreator.conf /etc/apache2/conf-available/phpmyadmin.conf /etc/apache2/conf-available/fqdn.conf /etc/apache2/.htpasswd-pma /etc/apache2/.htpasswd-dbcreator

msg_header "Removing Databases & Packages"
run_with_spinner "Purging phpMyAdmin" apt-get purge -y phpmyadmin
run_with_spinner "Purging MariaDB" apt-get purge -y mariadb-server mariadb-client mariadb-common
run_with_spinner "Purging Apache2" apt-get purge -y apache2 apache2-utils apache2-bin apache2.2-common
run_with_spinner "Purging Certbot" apt-get purge -y certbot python3-certbot-apache
run_with_spinner "Cleaning up dependencies" apt-get autoremove -y
run_with_spinner "Cleaning package cache" apt-get autoclean

msg_header "Deleting Application Files & Data"
run_with_spinner "Removing DB Creator app" rm -rf /var/www/dbcreator
run_with_spinner "Removing DB Creator logs" rm -rf /var/lib/dbcreator
run_with_spinner "Removing MySQL data" rm -rf /var/lib/mysql /etc/mysql
run_with_spinner "Removing Backups" rm -rf /var/backups/mariadb
run_with_spinner "Removing Summary files" rm -f /root/db-platform-install-summary.txt /root/phpmyadmin-http-auth.txt /root/dbcreator-http-auth.txt

msg_header "Cleaning up System Tasks"
run_with_spinner "Removing backup script" rm -f /usr/local/sbin/db-platform-backup.sh
run_with_spinner "Removing cron job" bash -c "crontab -l 2>/dev/null | grep -v 'db-platform-backup.sh' | crontab - || true"

msg_header "Resetting Firewall"
if ufw status | grep -q "active"; then
    run_with_spinner "Removing Apache rule" ufw delete allow 'Apache Full'
    msg_warn "UFW is still active. SSH access remains open."
fi

echo -e "\n${CLR_BOLD}${CLR_GREEN}===================================================="
echo "       Uninstallation Completed Successfully!         "
echo -e "====================================================${CLR_RESET}\n"
msg_info "The system is now clean and ready for a fresh install."
