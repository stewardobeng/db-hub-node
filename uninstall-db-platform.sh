#!/usr/bin/env bash
set -Eeuo pipefail

# DB Platform UNIVERSAL Uninstaller
# Supports targeted removal of the hub, the node, or the entire platform.

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
msg_ok()     { echo -e "${CLR_GREEN}[OK]${CLR_RESET} $*"; }
msg_warn()   { echo -e "${CLR_YELLOW}[!]${CLR_RESET} $*"; }
msg_err()    { echo -e "${CLR_RED}[X]${CLR_RESET} $*"; }

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

TARGET_SCOPE="${1:-${TARGET_SCOPE:-}}"
PURGE_PACKAGES="${PURGE_PACKAGES:-}"
REMOVE_HUB=0
REMOVE_NODE=0
PURGE_PACKAGES_FLAG=0
HUB_PRESENT=0
NODE_PRESENT=0
SHARED_WEB_STACK_REQUIRED=0
PURGE_SHARED_WEB_STACK=0

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

crontab_has() {
    local pattern="$1"
    command_exists crontab && crontab -l 2>/dev/null | grep -q "$pattern"
}

hub_component_present() {
    [[ -d /var/www/db-hub ]] ||
    [[ -f /etc/apache2/conf-available/db-hub.conf ]] ||
    [[ -L /etc/apache2/conf-enabled/db-hub.conf ]] ||
    [[ -f /root/db-hub-install-summary.txt ]] ||
    crontab_has 'action=watchdog'
}

node_component_present() {
    [[ -d /var/www/db-agent ]] ||
    [[ -f /etc/apache2/conf-available/db-agent.conf ]] ||
    [[ -L /etc/apache2/conf-enabled/db-agent.conf ]] ||
    [[ -f /etc/apache2/conf-available/phpmyadmin.conf ]] ||
    [[ -L /etc/apache2/conf-enabled/phpmyadmin.conf ]] ||
    [[ -f /usr/local/sbin/db-platform-backup.sh ]] ||
    [[ -d /var/lib/mysql ]] ||
    [[ -d /etc/mysql ]] ||
    [[ -f /etc/mysql/mariadb.conf.d/99-nitro-speed.cnf ]] ||
    [[ -f /root/db-node-install-summary.txt ]] ||
    crontab_has 'db-platform-backup.sh'
}

detect_existing_state() {
    hub_component_present && HUB_PRESENT=1 || HUB_PRESENT=0
    node_component_present && NODE_PRESENT=1 || NODE_PRESENT=0
}

compute_cleanup_plan() {
    local hub_remaining=$HUB_PRESENT
    local node_remaining=$NODE_PRESENT

    [[ $REMOVE_HUB -eq 1 ]] && hub_remaining=0
    [[ $REMOVE_NODE -eq 1 ]] && node_remaining=0

    if [[ $hub_remaining -eq 1 || $node_remaining -eq 1 ]]; then
        SHARED_WEB_STACK_REQUIRED=1
    else
        SHARED_WEB_STACK_REQUIRED=0
    fi

    if [[ $PURGE_PACKAGES_FLAG -eq 1 && $SHARED_WEB_STACK_REQUIRED -eq 0 ]]; then
        PURGE_SHARED_WEB_STACK=1
    else
        PURGE_SHARED_WEB_STACK=0
    fi
}

choose_scope() {
    if [[ "$TARGET_SCOPE" =~ ^(hub|node|all)$ ]]; then
        return
    fi

    clear
    echo -e "${CLR_BOLD}${CLR_RED}"
    echo "===================================================="
    echo "       DB PLATFORM TARGETED UNINSTALLER            "
    echo "===================================================="
    echo -e "${CLR_RESET}"
    echo "Choose what to remove:"
    echo "  hub  - central dashboard, SQLite data, hub cron/config"
    echo "  node - agent, MariaDB data, backups, node cron/config"
    echo "  all  - hub + node + optional package purge"
    read -r -p "$(echo -e "\n${CLR_BOLD}Target [hub/node/all]: ${CLR_RESET}")" TARGET_SCOPE

    if [[ ! "$TARGET_SCOPE" =~ ^(hub|node|all)$ ]]; then
        msg_err "Invalid target. Use: hub, node, or all."
        exit 1
    fi
}

set_scope_flags() {
    case "$TARGET_SCOPE" in
        hub) REMOVE_HUB=1 ;;
        node) REMOVE_NODE=1 ;;
        all) REMOVE_HUB=1; REMOVE_NODE=1 ;;
    esac
}

choose_package_mode() {
    local prompt default_label
    if [[ -n "$PURGE_PACKAGES" ]]; then
        if [[ "$PURGE_PACKAGES" =~ ^([Yy]|1|true|yes)$ ]]; then
            PURGE_PACKAGES_FLAG=1
        else
            PURGE_PACKAGES_FLAG=0
        fi
        return
    fi

    if [[ "$TARGET_SCOPE" == "all" ]]; then
        prompt="Also purge related system packages for a full wipe? [Y/n]: "
        default_label="Y"
    elif [[ "$TARGET_SCOPE" == "hub" && $NODE_PRESENT -eq 0 ]]; then
        prompt="Hub is the only detected platform component. Also purge related system packages for a full cleanup? [Y/n]: "
        default_label="Y"
    elif [[ "$TARGET_SCOPE" == "node" && $HUB_PRESENT -eq 0 ]]; then
        prompt="Node is the only detected platform component. Also purge related system packages for a full cleanup? [Y/n]: "
        default_label="Y"
    else
        prompt="Also purge component-specific packages after removing the selected component? [y/N]: "
        default_label="N"
    fi

    read -r -p "$(echo -e "${CLR_BOLD}${prompt}${CLR_RESET}")" purge_answer
    if [[ -z "$purge_answer" ]]; then
        [[ "$default_label" == "Y" ]] && PURGE_PACKAGES_FLAG=1 || PURGE_PACKAGES_FLAG=0
    elif [[ "$purge_answer" =~ ^[Yy]$ ]]; then
        PURGE_PACKAGES_FLAG=1
    else
        PURGE_PACKAGES_FLAG=0
    fi
}

confirm_scope() {
    clear
    echo -e "${CLR_BOLD}${CLR_RED}"
    echo "===================================================="
    echo "       DANGER: DB PLATFORM UNINSTALLER             "
    echo "===================================================="
    echo -e "${CLR_RESET}"
    echo "Selected target: ${TARGET_SCOPE}"
    echo "Package purge:   $([[ $PURGE_PACKAGES_FLAG -eq 1 ]] && echo yes || echo no)"
    echo
    [[ $REMOVE_HUB -eq 1 ]] && echo "  - Hub application, SQLite data, hub Apache config, hub cron"
    [[ $REMOVE_NODE -eq 1 ]] && echo "  - Node agent, MariaDB data, backups, node Apache config, node cron"
    if [[ $PURGE_PACKAGES_FLAG -eq 1 ]]; then
        if [[ $REMOVE_NODE -eq 1 && $PURGE_SHARED_WEB_STACK -eq 1 ]]; then
            echo "  - Node packages plus the shared Apache/PHP web stack"
        elif [[ $REMOVE_NODE -eq 1 ]]; then
            echo "  - Node packages while preserving the shared Apache/PHP web stack"
        elif [[ $PURGE_SHARED_WEB_STACK -eq 1 ]]; then
            echo "  - Shared Apache/PHP web stack used by the hub"
        else
            echo "  - No hub-only OS packages were found beyond the shared Apache/PHP stack"
        fi
    fi
    [[ $REMOVE_HUB -eq 1 && $HUB_PRESENT -eq 0 ]] && echo "  - Hub artifacts were not detected; cleanup will still scan common leftovers"
    [[ $REMOVE_NODE -eq 1 && $NODE_PRESENT -eq 0 ]] && echo "  - Node artifacts were not detected; cleanup will still scan common leftovers"
    echo -e "\n${CLR_BOLD}${CLR_YELLOW}This action cannot be undone.${CLR_RESET}"

    read -r -p "$(echo -e "\n${CLR_BOLD}Are you absolutely sure you want to proceed? (y/n): ${CLR_RESET}")" confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        msg_info "Uninstallation cancelled."
        exit 0
    fi
}

stop_services() {
    msg_header "Stopping Services"
    if [[ $REMOVE_HUB -eq 1 || $REMOVE_NODE -eq 1 ]]; then
        run_with_spinner "Stopping Apache2" systemctl stop apache2
    fi
    if [[ $REMOVE_NODE -eq 1 ]]; then
        run_with_spinner "Stopping MariaDB" systemctl stop mariadb
    fi
}

remove_hub_assets() {
    msg_header "Removing Hub Components"
    run_with_spinner "Disabling db-hub config" a2disconf db-hub
    run_with_spinner "Deleting db-hub.conf" rm -f /etc/apache2/conf-available/db-hub.conf
    run_with_spinner "Deleting enabled db-hub link" rm -f /etc/apache2/conf-enabled/db-hub.conf
    run_with_spinner "Removing Hub watchdog cron" bash -c "crontab -l 2>/dev/null | grep -v 'action=watchdog' | crontab - || true"
    run_with_spinner "Removing Hub application" rm -rf /var/www/db-hub
    run_with_spinner "Removing Hub summary" rm -f /root/db-hub-install-summary.txt
    run_with_spinner "Removing legacy creator app" rm -rf /var/www/dbcreator
    run_with_spinner "Removing legacy creator configs" rm -f /etc/apache2/conf-available/dbcreator.conf /etc/apache2/conf-available/fqdn.conf
    run_with_spinner "Deleting enabled legacy config links" rm -f /etc/apache2/conf-enabled/dbcreator.conf /etc/apache2/conf-enabled/fqdn.conf
    run_with_spinner "Cleaning legacy password files" rm -f /etc/apache2/.htpasswd-* /root/*-http-auth.txt
}

remove_node_assets() {
    msg_header "Removing Node Components"
    run_with_spinner "Disabling db-agent config" a2disconf db-agent
    run_with_spinner "Deleting db-agent.conf" rm -f /etc/apache2/conf-available/db-agent.conf
    run_with_spinner "Deleting enabled db-agent link" rm -f /etc/apache2/conf-enabled/db-agent.conf
    run_with_spinner "Disabling phpMyAdmin config" a2disconf phpmyadmin
    run_with_spinner "Deleting phpmyadmin.conf" rm -f /etc/apache2/conf-available/phpmyadmin.conf
    run_with_spinner "Deleting enabled phpMyAdmin link" rm -f /etc/apache2/conf-enabled/phpmyadmin.conf
    run_with_spinner "Removing backup cron" bash -c "crontab -l 2>/dev/null | grep -v 'db-platform-backup.sh' | crontab - || true"
    run_with_spinner "Removing backup script" rm -f /usr/local/sbin/db-platform-backup.sh
    run_with_spinner "Removing Node agent" rm -rf /var/www/db-agent
    run_with_spinner "Removing MariaDB tuning config" rm -f /etc/mysql/mariadb.conf.d/99-nitro-speed.cnf
    run_with_spinner "Removing Database storage" rm -rf /var/lib/mysql /etc/mysql
    run_with_spinner "Removing Backups" rm -rf /var/backups/mariadb
    run_with_spinner "Removing Node summary" rm -f /root/db-node-install-summary.txt
}

purge_node_packages() {
    msg_header "Purging Node Packages"
    run_with_spinner "Purging phpMyAdmin" apt-get purge -y phpmyadmin
    run_with_spinner "Purging MariaDB" apt-get purge -y mariadb-server mariadb-client mariadb-common
    run_with_spinner "Purging rclone" apt-get purge -y rclone
}

purge_web_stack_if_unused() {
    msg_header "Purging Shared Web Stack"
    run_with_spinner "Purging Apache2" apt-get purge -y apache2 apache2-utils apache2-bin
    run_with_spinner "Purging PHP stack" apt-get purge -y libapache2-mod-php php php-cli php-mysql php-curl php-sqlite3 php-mbstring php-xml php-zip php-json
    run_with_spinner "Purging Certbot" apt-get purge -y certbot python3-certbot-apache
}

cleanup_packages() {
    if [[ $PURGE_PACKAGES_FLAG -eq 0 ]]; then
        return
    fi

    if [[ $REMOVE_NODE -eq 1 ]]; then
        purge_node_packages
    fi

    if [[ $PURGE_SHARED_WEB_STACK -eq 1 ]]; then
        purge_web_stack_if_unused
    elif [[ $PURGE_PACKAGES_FLAG -eq 1 ]]; then
        msg_info "Keeping the shared Apache/PHP stack because another web workload may still need it."
    fi

    msg_header "Cleaning Package Cache"
    run_with_spinner "Auto-removing dependencies" apt-get autoremove -y
    run_with_spinner "Cleaning apt cache" apt-get autoclean
}

reset_firewall() {
    msg_header "Resetting Firewall"
    if ! ufw status | grep -q "active"; then
        msg_warn "UFW is not active. Skipping firewall cleanup."
        return
    fi

    if [[ $REMOVE_NODE -eq 1 ]]; then
        run_with_spinner "Removing MariaDB rule" ufw --force delete allow 3306/tcp
    fi

    if [[ $PURGE_SHARED_WEB_STACK -eq 1 ]]; then
        run_with_spinner "Removing Apache rule" ufw --force delete allow 'Apache Full'
    else
        msg_info "Keeping Apache firewall rule because the shared web stack is staying in place."
    fi

    msg_warn "UFW remains enabled. SSH access is preserved."
}

restart_remaining_services() {
    msg_header "Restoring Remaining Services"
    if [[ $PURGE_SHARED_WEB_STACK -eq 0 ]]; then
        run_with_spinner "Starting Apache2" systemctl start apache2
    else
        msg_info "No platform web components remain. Apache2 stays stopped."
    fi
}

print_summary() {
    echo -e "\n${CLR_BOLD}${CLR_GREEN}===================================================="
    echo "       Uninstallation Completed Successfully!       "
    echo -e "====================================================${CLR_RESET}\n"
    msg_info "Removed target: ${TARGET_SCOPE}"
    msg_info "Package purge: $([[ $PURGE_PACKAGES_FLAG -eq 1 ]] && echo enabled || echo skipped)"
    msg_info "Shared web stack: $([[ $PURGE_SHARED_WEB_STACK -eq 1 ]] && echo purged || echo retained)"
}

main() {
    choose_scope
    set_scope_flags
    detect_existing_state
    choose_package_mode
    compute_cleanup_plan
    confirm_scope
    stop_services
    [[ $REMOVE_HUB -eq 1 ]] && remove_hub_assets
    [[ $REMOVE_NODE -eq 1 ]] && remove_node_assets
    cleanup_packages
    reset_firewall
    restart_remaining_services
    print_summary
}

main "$@"
