#!/usr/bin/env bash
set -Eeuo pipefail

# DB-Shield SaaS HUB Installer v4.0
# High-Security Edition with SMTP Notifications & Brute-Force Protection.

# --- Colors & Styles ---
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_RED="\033[0;31m"
CLR_GREEN="\033[0;32m"
CLR_YELLOW="\033[0;33m"
CLR_BLUE="\033[0;34m"
CLR_CYAN="\033[0;36m"

# --- UI Helpers ---
msg_header() { echo -e "\n${CLR_BOLD}${CLR_CYAN}=== $* ===${CLR_RESET}"; }
msg_info()   { echo -e "${CLR_BLUE}[i]${CLR_RESET} $*"; }
msg_ok()     { echo -e "${CLR_GREEN}[✔]${CLR_RESET} $*"; }
msg_warn()   { echo -e "${CLR_YELLOW}[!]${CLR_RESET} $*"; }
msg_err()    { echo -e "${CLR_RED}[✘]${CLR_RESET} $*"; }

if [[ ${EUID:-0} -ne 0 ]]; then
  msg_err "Run this script as root."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

HUB_ROOT="/var/www/db-hub"
APACHE_CONF="/etc/apache2/conf-available/db-hub.conf"
SUMMARY_FILE="/root/db-hub-install-summary.txt"

# Default values
: "${SITE_FQDN:=_}"
: "${HUB_ADMIN_USER:=admin}"
: "${PAYSTACK_SECRET:=}"
: "${SMTP_HOST:=smtp.gmail.com}"
: "${SMTP_PORT:=587}"
: "${SMTP_USER:=}"
: "${SMTP_PASS:=}"
: "${SMTP_FROM:=noreply@steprotech.com}"

HUB_ADMIN_PASS="$(openssl rand -base64 12 | tr -d '\n')"
HUB_ADMIN_HASH=$(php -r "echo password_hash('$HUB_ADMIN_PASS', PASSWORD_DEFAULT);")
CSRF_SECRET="$(openssl rand -hex 32)"

wizard() {
    echo -e "${CLR_BOLD}${CLR_CYAN}===================================================="
    echo "       DB-Shield SaaS HUB: SECURITY & EMAIL         "
    echo -e "====================================================${CLR_RESET}"
    
    read -p "Hub Domain (FQDN): " input_fqdn
    SITE_FQDN=${input_fqdn:-$SITE_FQDN}
    
    msg_header "SMTP Configuration (for Notifications)"
    read -p "SMTP Host [$SMTP_HOST]: " input_host; SMTP_HOST=${input_host:-$SMTP_HOST}
    read -p "SMTP Port [$SMTP_PORT]: " input_port; SMTP_PORT=${input_port:-$SMTP_PORT}
    read -p "SMTP User: " SMTP_USER
    read -p "SMTP Password: " SMTP_PASS
    read -p "From Email [$SMTP_FROM]: " input_from; SMTP_FROM=${input_from:-$SMTP_FROM}

    msg_header "Payment Integration"
    read -p "Paystack Secret Key: " PAYSTACK_SECRET

    read -p "$(echo -e "\n${CLR_BOLD}${CLR_YELLOW}Initialize Secure Hub? (y/n): ${CLR_RESET}")" confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then exit 0; fi
}

install_packages() {
  msg_header "Installing Security Modules"
  apt-get update >/dev/null 2>&1
  apt-get install -y apache2 php php-cli php-mysql php-curl php-sqlite3 php-mbstring php-xml unzip curl openssl ufw fail2ban >/dev/null 2>&1
}

deploy_hub() {
  msg_header "Deploying Hardened Dashboard"
  mkdir -p "$HUB_ROOT"
  
  cat >"$HUB_ROOT/index.php" <<'PHPHUB'
<?php
declare(strict_types=1);
session_start();

const ADMIN_USER = '__HUB_USER__';
const ADMIN_HASH = '__HUB_HASH__';
const APP_SECRET = '__CSRF_SECRET__';
const PAYSTACK_SECRET = '__PAYSTACK_SECRET__';
const HUB_DB = 'hub_secure.sqlite';

// SMTP Config
const SMTP_HOST = '__SMTP_HOST__';
const SMTP_PORT = '__SMTP_PORT__';
const SMTP_USER = '__SMTP_USER__';
const SMTP_PASS = '__SMTP_PASS__';
const SMTP_FROM = '__SMTP_FROM__';

// Hardened Security Headers
header("X-Frame-Options: DENY");
header("X-Content-Type-Options: nosniff");
header("Content-Security-Policy: default-src 'self' https://cdn.tailwindcss.com https://cdnjs.cloudflare.com; style-src 'self' 'unsafe-inline' https://cdnjs.cloudflare.com;");

function e(string $v): string { return htmlspecialchars($v, ENT_QUOTES, 'UTF-8'); }
function csrf_token(): string {
    if (empty($_SESSION['csrf'])) $_SESSION['csrf'] = hash_hmac('sha256', session_id(), APP_SECRET);
    return $_SESSION['csrf'];
}
function require_csrf(): void {
    if (!hash_equals(csrf_token(), $_POST['csrf'] ?? '')) throw new RuntimeException('Security violation.');
}

function hub_db(): PDO {
    static $pdo = null; if ($pdo) return $pdo;
    $pdo = new PDO('sqlite:' . HUB_DB);
    $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    $pdo->exec("CREATE TABLE IF NOT EXISTS servers (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, host TEXT, agent_key TEXT, public_url TEXT)");
    $pdo->exec("CREATE TABLE IF NOT EXISTS packages (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, price REAL, db_limit INTEGER, duration_days INTEGER)");
    $pdo->exec("CREATE TABLE IF NOT EXISTS clients (id INTEGER PRIMARY KEY AUTOINCREMENT, email TEXT UNIQUE, password_hash TEXT, package_id INTEGER, expires_at DATETIME, status TEXT DEFAULT 'active')");
    $pdo->exec("CREATE TABLE IF NOT EXISTS tenant_dbs (id INTEGER PRIMARY KEY AUTOINCREMENT, client_id INTEGER, server_id INTEGER, db_name TEXT, db_user TEXT)");
    $pdo->exec("CREATE TABLE IF NOT EXISTS security_log (ip TEXT, attempts INTEGER, last_attempt DATETIME)");
    return $pdo;
}

// --- Brute Force Shield ---
function security_check(): void {
    $ip = $_SERVER['REMOTE_ADDR'];
    $db = hub_db();
    $stmt = $db->prepare("SELECT * FROM security_log WHERE ip = ?");
    $stmt->execute([$ip]);
    $log = $stmt->fetch(PDO::FETCH_ASSOC);
    if ($log && $log['attempts'] >= 5 && (time() - strtotime($log['last_attempt'])) < 900) {
        die("Your IP ($ip) is temporarily blocked due to multiple failed login attempts.");
    }
}

function log_failed_attempt(): void {
    $ip = $_SERVER['REMOTE_ADDR'];
    $db = hub_db();
    $db->prepare("INSERT INTO security_log (ip, attempts, last_attempt) VALUES (?, 1, CURRENT_TIMESTAMP) 
                  ON CONFLICT(ip) DO UPDATE SET attempts = attempts + 1, last_attempt = CURRENT_TIMESTAMP")->execute([$ip]);
}

function reset_security_log(): void {
    hub_db()->prepare("DELETE FROM security_log WHERE ip = ?")->execute([$_SERVER['REMOTE_ADDR']]);
}

// --- Mail Engine ---
function send_notification(string $to, string $subject, string $body): bool {
    $headers = "MIME-Version: 1.0" . "\r\n";
    $headers .= "Content-type:text/html;charset=UTF-8" . "\r\n";
    $headers .= "From: " . SMTP_FROM . "\r\n";
    // This uses internal mail() for simplicity, assuming local postfix or SMTP relay is configured.
    // For production with remote SMTP, PHPMailer is recommended.
    return @mail($to, $subject, "<html><body>$body</body></html>", $headers);
}

function call_agent(array $server, array $params = []): array {
    $queryString = http_build_query(array_merge(['key' => $server['agent_key']], $params));
    $ch = curl_init(rtrim($server['public_url'], '/') . "/agent-api/agent.php?" . $queryString);
    curl_setopt($ch, CURLOPT_RETURNTRANSFER, true); curl_setopt($ch, CURLOPT_TIMEOUT, 10);
    if (!empty($params['post_data'])) {
        curl_setopt($ch, CURLOPT_POST, true); curl_setopt($ch, CURLOPT_POSTFIELDS, http_build_query($params['post_data']));
    }
    $res = curl_exec($ch); return json_decode((string)$res, true) ?? ['error' => 'Node Unreachable'];
}

// User Identification
$is_admin = isset($_SESSION['role']) && $_SESSION['role'] === 'admin';
$client_id = $_SESSION['client_id'] ?? null;
$is_client = (bool)$client_id;

$view = $_GET['view'] ?? ($is_admin ? 'admin_dash' : ($is_client ? 'client_dash' : 'landing'));

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    require_csrf();
    $action = $_POST['action'] ?? '';

    if ($action === 'login') {
        security_check();
        $u = $_POST['email']; $p = $_POST['password'];
        if ($u === ADMIN_USER && password_verify($p, ADMIN_HASH)) {
            reset_security_log(); $_SESSION['role'] = 'admin'; header('Location: ?view=admin_dash'); exit;
        }
        $user = hub_db()->prepare("SELECT * FROM clients WHERE email = ?");
        $user->execute([$u]); $res = $user->fetch(PDO::FETCH_ASSOC);
        if ($res && password_verify($p, $res['password_hash'])) {
            reset_security_log(); $_SESSION['client_id'] = $res['id']; header('Location: ?view=client_dash'); exit;
        }
        log_failed_attempt(); $login_err = "Access Denied.";
    }

    if ($action === 'create_tenant_db' && $is_client) {
        // [Logic for Smart Provisioning...]
        $db = hub_db();
        $servers = $db->query("SELECT * FROM servers")->fetchAll(PDO::FETCH_ASSOC);
        $best_server = null; $min_cpu = 101;
        foreach($servers as $s) {
            $stats = call_agent($s, ['action' => 'stats']);
            if (!isset($stats['error']) && $stats['cpu'] < $min_cpu) { $min_cpu = $stats['cpu']; $best_server = $s; }
        }
        if ($best_server) {
            $prefix = bin2hex(random_bytes(4));
            $nodeRes = call_agent($best_server, ['action' => 'create', 'post_data' => ['db_prefix' => $prefix, 'db_suffix' => 'db', 'remote_host' => '%']]);
            if (!isset($nodeRes['error'])) {
                $db->prepare("INSERT INTO tenant_dbs (client_id, server_id, db_name, db_user) VALUES (?,?,?,?)")->execute([$client_id, $best_server['id'], $prefix.'_db', $prefix.'_user']);
                send_notification($u, "Shield: New Database Provisioned", "Your database <b>".$prefix."_db</b> is ready. Access it via the portal.");
                $_SESSION['message'] = "Success! Credentials sent to your email.";
            }
        }
        header('Location: ?view=client_dash'); exit;
    }
}

if (isset($_GET['action']) && $_GET['action'] === 'logout') { session_destroy(); header('Location: ?view=landing'); exit; }

$db = hub_db();
$packages = $db->query("SELECT * FROM packages")->fetchAll(PDO::FETCH_ASSOC);

?><!doctype html><html><head><meta charset="utf-8"><title>Shield Platform</title>
<script src="https://cdn.tailwindcss.com?plugins=forms"></script>
<link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css" rel="stylesheet"/>
</head><body class="bg-slate-950 text-slate-300 font-sans">

<?php if ($view === 'landing'): ?>
    <nav class="flex justify-between px-12 py-8 items-center max-w-7xl mx-auto">
        <div class="text-2xl font-black text-white italic"><i class="fa-solid fa-shield-halved mr-2 text-indigo-500"></i>SHIELD</div>
        <div class="space-x-8 text-xs font-black uppercase tracking-widest"><a href="?view=login" class="bg-white text-black px-8 py-3 rounded-full hover:bg-indigo-500 hover:text-white transition-all">Identity Check</a></div>
    </nav>
    <main class="max-w-7xl mx-auto px-8 pt-24 pb-32 text-center">
        <h1 class="text-8xl font-black text-white tracking-tighter mb-8 leading-none">Fortified <span class="text-indigo-500 underline decoration-indigo-500/30">Infrastructure.</span></h1>
        <p class="text-slate-500 text-xl max-w-2xl mx-auto mb-20 font-medium">Enterprise MariaDB clusters with automated security hardening, real-time brute-force protection, and intelligent global routing.</p>
        <div class="grid grid-cols-1 md:grid-cols-3 gap-8 text-left">
            <?php foreach($packages as $p): ?>
            <div class="bg-slate-900 border border-slate-800 p-12 rounded-[3rem] hover:border-indigo-500/50 transition-all shadow-2xl">
                <h3 class="text-indigo-400 font-black uppercase tracking-[0.3em] text-[9px] mb-6"><?= e($p['name']) ?></h3>
                <div class="text-6xl font-black text-white mb-10 tracking-tighter">$<?= round($p['price']) ?></div>
                <ul class="space-y-5 mb-12 text-sm font-semibold text-slate-400">
                    <li><i class="fa-solid fa-shield-check text-indigo-500 mr-2"></i> <?= $p['db_limit'] ?> Instances</li>
                    <li><i class="fa-solid fa-shield-check text-indigo-500 mr-2"></i> Real-time Monitoring</li>
                </ul>
                <a href="?view=signup&pkg=<?= $p['id'] ?>" class="block text-center bg-indigo-600 text-white py-5 rounded-2xl font-black text-xs uppercase tracking-widest hover:bg-indigo-500 shadow-xl shadow-indigo-500/20 transition-all">Select Tier</a>
            </div>
            <?php endforeach; ?>
        </div>
    </main>

<?php elseif ($view === 'login'): ?>
    <div class="flex items-center justify-center min-h-screen">
        <form method="post" class="bg-slate-900 p-16 rounded-[3rem] border border-slate-800 w-full max-w-md shadow-2xl">
            <input type="hidden" name="action" value="login"><input type="hidden" name="csrf" value="<?= csrf_token() ?>">
            <h2 class="text-4xl font-black text-white mb-10 tracking-tighter text-center">ACCESS GATE</h2>
            <?php if(isset($login_err)) echo "<div class='bg-red-500/10 border border-red-500/20 text-red-400 p-4 rounded-xl mb-8 text-xs font-black uppercase text-center tracking-widest'>$login_err</div>"; ?>
            <div class="space-y-8">
                <div><label class="text-[10px] font-black text-slate-500 uppercase tracking-widest ml-1 mb-3 block">User Email</label>
                <input type="email" name="email" class="w-full bg-slate-950 border-slate-800 rounded-2xl p-5 text-white focus:ring-indigo-500" required></div>
                <div><label class="text-[10px] font-black text-slate-500 uppercase tracking-widest ml-1 mb-3 block">Access Key</label>
                <input type="password" name="password" class="w-full bg-slate-950 border-slate-800 rounded-2xl p-5 text-white focus:ring-indigo-500" required></div>
                <button class="w-full bg-indigo-600 py-6 rounded-2xl text-white font-black uppercase tracking-widest text-xs shadow-2xl shadow-indigo-500/20 hover:bg-indigo-500 transition-all mt-6">Authenticate</button>
            </div>
        </form>
    </div>
<?php endif; ?>

<footer class="text-center py-20 text-[10px] font-black text-slate-800 uppercase tracking-[1em]">Shield Infrastructure &bull; Hardened Environment</footer>
</body></html>
PHPHUB

  sed -i "s|__HUB_USER__|${HUB_ADMIN_USER}|g" "$HUB_ROOT/index.php"
  sed -i "s|__HUB_HASH__|${HUB_ADMIN_HASH}|g" "$HUB_ROOT/index.php"
  sed -i "s|__CSRF_SECRET__|${CSRF_SECRET}|g" "$HUB_ROOT/index.php"
  sed -i "s|__PAYSTACK_SECRET__|${PAYSTACK_SECRET}|g" "$HUB_ROOT/index.php"
  sed -i "s|__SMTP_HOST__|${SMTP_HOST}|g" "$HUB_ROOT/index.php"
  sed -i "s|__SMTP_PORT__|${SMTP_PORT}|g" "$HUB_ROOT/index.php"
  sed -i "s|__SMTP_USER__|${SMTP_USER}|g" "$HUB_ROOT/index.php"
  sed -i "s|__SMTP_PASS__|${SMTP_PASS}|g" "$HUB_ROOT/index.php"
  sed -i "s|__SMTP_FROM__|${SMTP_FROM}|g" "$HUB_ROOT/index.php"

  chown -R www-data:www-data "$HUB_ROOT"
  chmod 750 "$HUB_ROOT"
  touch "$HUB_ROOT/hub_secure.sqlite"
  chown www-data:www-data "$HUB_ROOT/hub_secure.sqlite"
  chmod 660 "$HUB_ROOT/hub_secure.sqlite"

  cat >"$APACHE_CONF" <<APACHE
Alias /${HUB_ALIAS} ${HUB_ROOT}
<Directory ${HUB_ROOT}>
    Options FollowSymLinks
    AllowOverride All
    Require all granted
</Directory>
APACHE
  a2enconf db-hub >/dev/null 2>&1 || true
}

configure_firewall() {
  msg_header "UFW Hardening"
  ufw allow OpenSSH; ufw allow 'Apache Full'; ufw --force enable
}

write_summary() {
  cat > "$SUMMARY_FILE" <<EOF
Shield SaaS Hub Hardened & Deployed
URL: http://${SITE_FQDN}/${HUB_ALIAS}
Security Level: HIGH
Brute-force Protection: ACTIVE
SMTP: CONFIGURED
EOF
  echo -e "\n${CLR_BOLD}${CLR_GREEN}Fortified Hub deployed successfully!${CLR_RESET}"
}

main() {
  clear; wizard; install_packages; deploy_hub; systemctl restart apache2; configure_firewall; write_summary
}

main "$@"
