#!/usr/bin/env bash
set -Eeuo pipefail

# DB Platform HUB Installer (Central Management Console)
# Distributed Architecture with Subscription Management & Paystack Integration.

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

HUB_ROOT="/var/www/db-hub"
APACHE_CONF="/etc/apache2/conf-available/db-hub.conf"
SUMMARY_FILE="/root/db-hub-install-summary.txt"

: "${SITE_FQDN:=_}"
: "${HUB_ALIAS:=db-hub}"
: "${HUB_ADMIN_USER:=admin}"
: "${LETSENCRYPT_EMAIL:=}"
: "${PAYSTACK_SECRET:=}"

HUB_ADMIN_PASS="$(openssl rand -base64 12 | tr -d '\n')"
HUB_ADMIN_HASH=$(php -r "echo password_hash('$HUB_ADMIN_PASS', PASSWORD_DEFAULT);")
CSRF_SECRET="$(openssl rand -hex 32)"
APP_KEY="$(openssl rand -hex 32)"

wizard() {
    echo -e "${CLR_BOLD}${CLR_CYAN}"
    echo "===================================================="
    echo "       DB-Shield HUB Installation Wizard           "
    echo "===================================================="
    echo -e "${CLR_RESET}"
    read -p "$(echo -e "${CLR_BOLD}Enter Hub Domain (FQDN) [${SITE_FQDN}]: ${CLR_RESET}")" input_fqdn
    SITE_FQDN=${input_fqdn:-$SITE_FQDN}
    read -p "$(echo -e "${CLR_BOLD}Enter SSL Email (optional): ${CLR_RESET}")" input_email
    LETSENCRYPT_EMAIL=${input_email:-$LETSENCRYPT_EMAIL}
    read -p "$(echo -e "${CLR_BOLD}Enter Paystack Secret Key (optional): ${CLR_RESET}")" input_paystack
    PAYSTACK_SECRET=${input_paystack:-$PAYSTACK_SECRET}
    read -p "$(echo -e "\n${CLR_BOLD}${CLR_YELLOW}Ready to install the Management Hub? (y/n): ${CLR_RESET}")" confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then exit 0; fi
}

require_ubuntu() {
  if [[ ! -f /etc/os-release ]]; then exit 1; fi
  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" ]]; then exit 1; fi
}

install_packages() {
  msg_header "Installing Hub Dependencies"
  apt-get update >/dev/null 2>&1
  apt-get install -y apache2 php libapache2-mod-php php-cli php-mysql php-curl php-zip php-xml php-mbstring php-json php-sqlite3 certbot python3-certbot-apache unzip curl openssl ufw >/dev/null 2>&1
}

deploy_hub() {
  msg_header "Deploying Central Hub Dashboard"
  mkdir -p "$HUB_ROOT"
  
  cat >"$HUB_ROOT/index.php" <<'PHPHUB'
<?php
declare(strict_types=1);
session_start();

const APP_USER = '__HUB_USER__';
const APP_HASH = '__HUB_HASH__';
const APP_SECRET = '__CSRF_SECRET__';
const PAYSTACK_SECRET = '__PAYSTACK_SECRET__';
const HUB_DB = 'hub_data.sqlite';

function e(string $v): string { return htmlspecialchars($v, ENT_QUOTES, 'UTF-8'); }
function csrf_token(): string {
    if (empty($_SESSION['csrf'])) $_SESSION['csrf'] = hash_hmac('sha256', session_id(), APP_SECRET);
    return $_SESSION['csrf'];
}
function require_csrf(): void {
    if (!hash_equals(csrf_token(), $_POST['csrf'] ?? '')) throw new RuntimeException('Invalid CSRF token.');
}
function is_logged_in(): bool { return isset($_SESSION['logged_in']) && $_SESSION['logged_in'] === true; }

function hub_db(): PDO {
    static $pdo = null;
    if ($pdo) return $pdo;
    $pdo = new PDO('sqlite:' . HUB_DB);
    $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    $pdo->exec("CREATE TABLE IF NOT EXISTS servers (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT, host TEXT, agent_key TEXT, public_url TEXT,
        s3_endpoint TEXT, s3_bucket TEXT, s3_access_key TEXT, s3_secret_key TEXT
    )");
    $pdo->exec("CREATE TABLE IF NOT EXISTS packages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT, price REAL, db_limit INTEGER, duration_days INTEGER
    )");
    $pdo->exec("CREATE TABLE IF NOT EXISTS clients (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        email TEXT UNIQUE, password_hash TEXT, package_id INTEGER,
        expires_at DATETIME, status TEXT DEFAULT 'active'
    )");
    return $pdo;
}

function call_agent(array $server, array $params = []): array {
    $queryString = http_build_query(array_merge(['key' => $server['agent_key']], $params));
    $url = rtrim($server['public_url'], '/') . "/agent-api/agent.php?" . $queryString;
    $ch = curl_init($url);
    curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
    curl_setopt($ch, CURLOPT_TIMEOUT, 10);
    if (!empty($params['post_data'])) {
        curl_setopt($ch, CURLOPT_POST, true);
        curl_setopt($ch, CURLOPT_POSTFIELDS, http_build_query($params['post_data']));
    }
    $res = curl_exec($ch);
    if (curl_errno($ch)) return ['error' => curl_error($ch)];
    return json_decode((string)$res, true) ?? ['error' => 'Invalid response from node'];
}

// Login
if (isset($_POST['action']) && $_POST['action'] === 'login') {
    if (($_POST['username'] ?? '') === APP_USER && password_verify($_POST['password'] ?? '', APP_HASH)) {
        $_SESSION['logged_in'] = true; header('Location: ' . $_SERVER['PHP_SELF']); exit;
    }
    $error = "Invalid credentials.";
}
if (isset($_GET['action']) && $_GET['action'] === 'logout') { session_destroy(); header('Location: ' . $_SERVER['PHP_SELF']); exit; }

if (!is_logged_in()) {
    ?><!doctype html><html><head><title>Login - DB Hub</title><script src="https://cdn.tailwindcss.com?plugins=forms"></script>
    <link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css" rel="stylesheet"/></head>
    <body class="bg-slate-900 flex items-center justify-center min-h-screen text-slate-300">
    <div class="bg-slate-800 p-8 rounded-2xl shadow-2xl border border-slate-700 w-full max-w-md text-center">
        <div class="bg-indigo-600 text-white w-20 h-20 rounded-2xl flex items-center justify-center mx-auto mb-6 rotate-3 shadow-indigo-500/50 shadow-lg"><i class="fa-solid fa-shield-halved text-3xl"></i></div>
        <h1 class="text-3xl font-black text-white mb-2 tracking-tight">Shield Hub</h1>
        <p class="text-slate-400 text-sm mb-8 font-medium italic">Command & Control Center</p>
        <?php if (isset($error)) echo "<div class='bg-red-500/10 text-red-400 border border-red-500/20 p-3 rounded-lg mb-6 text-sm'>$error</div>"; ?>
        <form method="post" class="space-y-5 text-left">
            <input type="hidden" name="action" value="login"><input type="hidden" name="csrf" value="<?= csrf_token() ?>">
            <div><label class="text-[10px] font-black text-slate-500 uppercase tracking-widest ml-1">Admin Identity</label>
            <input type="text" name="username" class="w-full bg-slate-900 border-slate-700 rounded-xl focus:ring-indigo-500 focus:border-indigo-500 text-white" required autofocus></div>
            <div><label class="text-[10px] font-black text-slate-500 uppercase tracking-widest ml-1">Access Key</label>
            <input type="password" name="password" class="w-full bg-slate-900 border-slate-700 rounded-xl focus:ring-indigo-500 focus:border-indigo-500 text-white" required></div>
            <button class="w-full bg-indigo-600 text-white font-black py-4 rounded-xl shadow-lg hover:bg-indigo-500 transition-all uppercase tracking-widest text-xs mt-4">Unlock Platform</button>
        </form></div></body></html><?php exit;
}

$db = hub_db();
$message = $_SESSION['message'] ?? ''; unset($_SESSION['message']);
$error = $_SESSION['error'] ?? ''; unset($_SESSION['error']);
$view = $_GET['view'] ?? 'dashboard';

// Hub Actions
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    require_csrf();
    $action = $_POST['action'] ?? '';
    
    if ($action === 'add_server') {
        $stmt = $db->prepare("INSERT INTO servers (name, host, agent_key, public_url) VALUES (?, ?, ?, ?)");
        $stmt->execute([$_POST['name'], $_POST['host'], $_POST['agent_key'], $_POST['public_url']]);
        header('Location: ' . $_SERVER['PHP_SELF']); exit;
    }
    if ($action === 'select_server') {
        $_SESSION['active_server_id'] = (int)$_POST['server_id'];
        header('Location: ' . $_SERVER['PHP_SELF']); exit;
    }
    if ($action === 'update_s3') {
        $stmt = $db->prepare("UPDATE servers SET s3_endpoint=?, s3_bucket=?, s3_access_key=?, s3_secret_key=? WHERE id=?");
        $stmt->execute([$_POST['s3_endpoint'], $_POST['s3_bucket'], $_POST['s3_access_key'], $_POST['s3_secret_key'], $_POST['server_id']]);
        $_SESSION['message'] = "S3 Config Stored.";
        header('Location: ' . $_SERVER['PHP_SELF'] . "?view=backups"); exit;
    }
    if ($action === 'add_package') {
        $stmt = $db->prepare("INSERT INTO packages (name, price, db_limit, duration_days) VALUES (?, ?, ?, ?)");
        $stmt->execute([$_POST['name'], $_POST['price'], $_POST['db_limit'], $_POST['duration_days']]);
        $_SESSION['message'] = "Package created.";
        header('Location: ' . $_SERVER['PHP_SELF'] . "?view=billing"); exit;
    }
}

$servers = $db->query("SELECT * FROM servers")->fetchAll(PDO::FETCH_ASSOC);
$active_id = $_SESSION['active_server_id'] ?? ($servers[0]['id'] ?? null);
$active_server = null; foreach($servers as $s) { if($s['id'] == $active_id) $active_server = $s; }

// Proxy to Node
if ($active_server && isset($_POST['node_action'])) {
    require_csrf();
    $nodeRes = call_agent($active_server, ['action' => $_POST['node_action'], 'post_data' => $_POST]);
    if (isset($nodeRes['error'])) $_SESSION['error'] = $nodeRes['error'];
    else {
        $_SESSION['message'] = $nodeRes['message'] ?? 'Action completed.';
        if (isset($nodeRes['download'])) $_SESSION['download'] = $nodeRes['download'];
    }
    header('Location: ' . $_SERVER['PHP_SELF'] . '?view=' . $view); exit;
}

if (isset($_GET['download']) && !empty($_SESSION['download'])) {
    header('Content-Type: text/plain'); header('Content-Disposition: attachment; filename="' . $_SESSION['download']['filename'] . '"');
    echo $_SESSION['download']['content']; unset($_SESSION['download']); exit;
}

$stats = $active_server ? call_agent($active_server, ['action' => 'stats']) : null;
$tenants = ($active_server && !isset($stats['error'])) ? call_agent($active_server, ['action' => 'list_tenants']) : [];
$backups = ($active_server && !isset($stats['error'])) ? call_agent($active_server, ['action' => 'list_backups']) : [];
$packages = $db->query("SELECT * FROM packages")->fetchAll(PDO::FETCH_ASSOC);

?><!doctype html><html><head><meta charset="utf-8"><title>Shield Hub Dashboard</title>
<script src="https://cdn.tailwindcss.com?plugins=forms"></script>
<link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css" rel="stylesheet"/>
</head><body class="bg-slate-50 font-sans antialiased text-slate-900">

<header class="bg-slate-900 text-white flex items-center justify-between px-8 py-4 shadow-2xl sticky top-0 z-40 border-b border-indigo-500/30">
    <div class="flex items-center space-x-3"><div class="bg-indigo-600 p-2 rounded-lg rotate-3"><i class="fa-solid fa-shield-halved"></i></div>
    <h1 class="text-xl font-black tracking-tighter uppercase">Shield <span class="text-indigo-400">Hub</span></h1></div>
    <div class="flex items-center space-x-6">
        <form method="post" class="flex items-center bg-slate-800 rounded-xl px-4 py-1.5 border border-slate-700 shadow-inner">
            <input type="hidden" name="csrf" value="<?= csrf_token() ?>"><input type="hidden" name="action" value="select_server">
            <select name="server_id" onchange="this.form.submit()" class="bg-transparent border-none text-xs font-bold text-slate-300 focus:ring-0 cursor-pointer">
                <option value="" disabled <?= !$active_id ? 'selected' : '' ?>>Network Switcher...</option>
                <?php foreach($servers as $s): ?><option value="<?= $s['id'] ?>" <?= $s['id'] == $active_id ? 'selected' : '' ?> class="text-black"><?= e($s['name']) ?></option><?php endforeach; ?>
            </select>
        </form>
        <div class="flex items-center space-x-4 border-l border-slate-700 pl-6">
            <button onclick="document.getElementById('modal-add').classList.remove('hidden')" class="text-slate-400 hover:text-white transition-colors"><i class="fa-solid fa-plus-circle text-xl"></i></button>
            <a href="?action=logout" class="text-slate-400 hover:text-red-400 transition-colors"><i class="fa-solid fa-power-off text-xl"></i></a>
        </div>
    </div>
</header>

<main class="max-w-7xl mx-auto px-8 py-8 space-y-8">
    <?php if ($message): ?><div class="bg-emerald-500/10 border border-emerald-500/20 text-emerald-600 px-6 py-4 rounded-2xl shadow-sm flex items-center font-bold animate-fade-in"><i class="fa-solid fa-check-circle mr-3"></i><?= e($message) ?></div><?php endif; ?>
    <?php if ($error): ?><div class="bg-red-500/10 border border-red-500/20 text-red-600 px-6 py-4 rounded-2xl shadow-sm flex items-center font-bold animate-shake"><i class="fa-solid fa-circle-exclamation mr-3"></i><?= e($error) ?></div><?php endif; ?>
    
    <div class="flex space-x-2 bg-slate-200/50 p-1.5 rounded-2xl border border-slate-200 w-fit shadow-inner">
        <a href="?view=dashboard" class="px-8 py-2.5 text-[10px] font-black uppercase tracking-[0.2em] rounded-xl transition-all <?= $view === 'dashboard' ? 'bg-white text-indigo-600 shadow-xl' : 'text-slate-500 hover:text-slate-700' ?>">Infrastructure</a>
        <a href="?view=backups" class="px-8 py-2.5 text-[10px] font-black uppercase tracking-[0.2em] rounded-xl transition-all <?= $view === 'backups' ? 'bg-white text-indigo-600 shadow-xl' : 'text-slate-500 hover:text-slate-700' ?>">Recovery</a>
        <a href="?view=billing" class="px-8 py-2.5 text-[10px] font-black uppercase tracking-[0.2em] rounded-xl transition-all <?= $view === 'billing' ? 'bg-white text-indigo-600 shadow-xl' : 'text-slate-500 hover:text-slate-700' ?>">Subscriptions</a>
    </div>

    <?php if (!$active_server && $view !== 'billing'): ?>
        <div class="bg-white p-24 rounded-[3rem] text-center border border-slate-200 shadow-2xl">
            <div class="w-24 h-24 bg-slate-100 rounded-full flex items-center justify-center mx-auto mb-8"><i class="fa-solid fa-satellite-dish text-4xl text-slate-300"></i></div>
            <h2 class="text-3xl font-black text-slate-900 mb-4 tracking-tight">Deployment Required</h2>
            <p class="text-slate-400 mb-12 max-w-md mx-auto font-medium">Link your secure database nodes to activate remote provisioning, real-time analytics, and automated cloud snapshots.</p>
            <button onclick="document.getElementById('modal-add').classList.remove('hidden')" class="bg-indigo-600 text-white px-12 py-5 rounded-2xl font-black shadow-2xl shadow-indigo-500/40 hover:bg-indigo-500 hover:-translate-y-1 transition-all uppercase tracking-widest text-xs">Initialize First Node</button>
        </div>
    <?php elseif ($view === 'billing'): ?>
        <div class="grid grid-cols-1 md:grid-cols-2 gap-8">
            <section class="bg-white p-10 rounded-[2.5rem] border border-slate-200 shadow-xl">
                <div class="flex items-center justify-between mb-8">
                    <h2 class="font-black text-slate-900 text-2xl tracking-tight">Subscription Tiers</h2>
                    <div class="bg-indigo-100 text-indigo-600 p-3 rounded-2xl"><i class="fa-solid fa-tags"></i></div>
                </div>
                <form method="post" class="space-y-6">
                    <input type="hidden" name="csrf" value="<?= csrf_token() ?>"><input type="hidden" name="action" value="add_package">
                    <div class="grid grid-cols-2 gap-6">
                        <div><label class="text-[10px] font-black text-slate-400 uppercase tracking-widest block mb-2 ml-1">Package Name</label>
                        <input type="text" name="name" placeholder="Starter" class="w-full rounded-2xl border-slate-200 bg-slate-50 p-4 focus:ring-indigo-500" required></div>
                        <div><label class="text-[10px] font-black text-slate-400 uppercase tracking-widest block mb-2 ml-1">Monthly Price</label>
                        <input type="number" step="0.01" name="price" placeholder="29.99" class="w-full rounded-2xl border-slate-200 bg-slate-50 p-4 focus:ring-indigo-500" required></div>
                    </div>
                    <div class="grid grid-cols-2 gap-6">
                        <div><label class="text-[10px] font-black text-slate-400 uppercase tracking-widest block mb-2 ml-1">DB Instance Limit</label>
                        <input type="number" name="db_limit" placeholder="5" class="w-full rounded-2xl border-slate-200 bg-slate-50 p-4 focus:ring-indigo-500" required></div>
                        <div><label class="text-[10px] font-black text-slate-400 uppercase tracking-widest block mb-2 ml-1">Validity (Days)</label>
                        <input type="number" name="duration_days" value="30" class="w-full rounded-2xl border-slate-200 bg-slate-50 p-4 focus:ring-indigo-500" required></div>
                    </div>
                    <button class="w-full bg-slate-900 text-white font-black py-5 rounded-2xl uppercase tracking-widest text-xs shadow-2xl hover:bg-black transition-all">Publish New Package</button>
                </form>
            </section>
            <div class="space-y-6">
                <?php foreach($packages as $pkg): ?>
                <div class="bg-white p-8 rounded-[2rem] border border-slate-200 shadow-lg flex items-center justify-between hover:border-indigo-200 transition-colors group">
                    <div>
                        <h3 class="font-black text-slate-900 text-lg"><?= e($pkg['name']) ?></h3>
                        <p class="text-slate-400 text-sm font-medium italic"><?= $pkg['db_limit'] ?> Databases &bull; <?= $pkg['duration_days'] ?> Days</p>
                    </div>
                    <div class="text-right">
                        <div class="text-2xl font-black text-indigo-600 tracking-tight">$<?= number_format($pkg['price'], 2) ?></div>
                        <div class="text-[10px] font-black text-slate-300 uppercase tracking-widest">Paystack ID: #<?= $pkg['id'] ?></div>
                    </div>
                </div>
                <?php endforeach; ?>
            </div>
        </div>
    <?php elseif ($view === 'backups'): ?>
        <!-- [Backups Content remains similar but with new styling...] -->
        <div class="grid grid-cols-1 lg:grid-cols-3 gap-8">
            <div class="lg:col-span-2"><section class="bg-white rounded-[2.5rem] border border-slate-200 shadow-xl overflow-hidden">
                <div class="px-10 py-8 border-b border-slate-100 bg-slate-50/50 flex items-center justify-between">
                    <h2 class="font-black text-slate-900 text-xl tracking-tight">Recovery Points</h2>
                    <form method="post"><input type="hidden" name="csrf" value="<?= csrf_token() ?>"><input type="hidden" name="node_action" value="trigger_backup">
                    <button class="bg-indigo-600 text-white px-8 py-3 rounded-2xl font-black text-[10px] uppercase tracking-widest shadow-xl shadow-indigo-500/30 hover:bg-indigo-500">Run Snapshot</button></form>
                </div>
                <div class="overflow-x-auto"><table class="min-w-full divide-y divide-slate-100">
                    <thead class="bg-slate-50"><tr><th class="px-10 py-4 text-left text-[10px] font-black text-slate-400 uppercase tracking-widest">Backup Identifier</th><th class="px-10 py-4 text-left text-[10px] font-black text-slate-400 uppercase tracking-widest">Size</th><th class="px-10 py-4 text-center text-[10px] font-black text-slate-400 uppercase tracking-widest">Operations</th></tr></thead>
                    <tbody class="divide-y divide-slate-50"><?php foreach($backups as $b): if(isset($b['error'])) continue; ?>
                        <tr class="group hover:bg-indigo-50/30 transition-colors">
                            <td class="px-10 py-6 whitespace-nowrap text-sm font-bold text-slate-700 flex items-center"><i class="fa-solid fa-file-shield mr-4 text-slate-300 group-hover:text-indigo-400 transition-colors"></i><?= e($b['name']) ?></td>
                            <td class="px-10 py-6 whitespace-nowrap text-xs font-black text-slate-400 uppercase tracking-tighter"><?= e($b['size']) ?></td>
                            <td class="px-10 py-6 whitespace-nowrap text-center">
                                <form method="post" onsubmit="return confirm('DESTUCTIVE OPERATION: RESTORE NOW?');" class="inline">
                                    <input type="hidden" name="csrf" value="<?= csrf_token() ?>"><input type="hidden" name="node_action" value="restore"><input type="hidden" name="filename" value="<?= e($b['name']) ?>">
                                    <button class="text-red-500 hover:text-red-700 font-black text-[10px] uppercase tracking-[0.2em] border border-red-100 px-4 py-2 rounded-xl hover:bg-red-50 transition-all">Restore</button>
                                </form></td></tr><?php endforeach; ?></tbody></table></div></section></div>
            <div class="space-y-8"><section class="bg-slate-900 p-10 rounded-[2.5rem] border border-indigo-500/20 shadow-2xl text-white">
                <h2 class="font-black text-white text-xl mb-8 tracking-tight flex items-center"><i class="fa-solid fa-cloud-bolt mr-3 text-indigo-400"></i>Cloud Vault</h2>
                <form method="post" class="space-y-6">
                    <input type="hidden" name="csrf" value="<?= csrf_token() ?>"><input type="hidden" name="action" value="update_s3"><input type="hidden" name="server_id" value="<?= $active_server['id'] ?>">
                    <div><label class="text-[10px] font-black text-slate-500 uppercase tracking-widest block mb-2 ml-1">S3 Endpoint</label>
                    <input type="text" name="s3_endpoint" value="<?= e($active_server['s3_endpoint'] ?? '') ?>" class="w-full bg-slate-800 border-slate-700 rounded-2xl p-4 text-xs font-mono" placeholder="Cloudflare R2 URL"></div>
                    <div><label class="text-[10px] font-black text-slate-500 uppercase tracking-widest block mb-2 ml-1">Bucket</label>
                    <input type="text" name="s3_bucket" value="<?= e($active_server['s3_bucket'] ?? '') ?>" class="w-full bg-slate-800 border-slate-700 rounded-2xl p-4 text-xs font-mono"></div>
                    <button class="w-full bg-indigo-600 text-white py-5 rounded-2xl font-black text-[10px] uppercase tracking-widest shadow-xl shadow-indigo-500/30 hover:bg-indigo-500 transition-all">Commit Configuration</button>
                </form>
                <form method="post" class="mt-6">
                    <input type="hidden" name="csrf" value="<?= csrf_token() ?>"><input type="hidden" name="node_action" value="save_s3_config">
                    <?php foreach(['s3_endpoint','s3_bucket','s3_access_key','s3_secret_key'] as $f): ?><input type="hidden" name="<?= $f ?>" value="<?= e($active_server[$f] ?? '') ?>"><?php endforeach; ?>
                    <button class="w-full bg-slate-800 text-slate-400 py-4 rounded-2xl font-black text-[10px] uppercase tracking-widest hover:bg-slate-700 transition-all border border-slate-700">Deploy Sync Engine</button>
                </form></section></div></div>
    <?php else: ?>
        <section class="grid grid-cols-1 md:grid-cols-4 gap-6"><?php foreach([['Health','cpu','CPU %','fa-microchip','indigo'],['Memory','ram','Used %','fa-memory','emerald'],['Storage','disk','Used %','fa-hard-drive','amber']] as $stat): ?>
            <div class="bg-white p-8 rounded-[2rem] border border-slate-200 shadow-lg group hover:shadow-2xl transition-all">
                <div class="flex items-center justify-between mb-4"><span class="text-[10px] font-black text-slate-400 uppercase tracking-widest"><?= $stat[0] ?></span><i class="fa-solid <?= $stat[3] ?> text-<?= $stat[4] ?>-500/50"></i></div>
                <div class="text-3xl font-black text-slate-900 group-hover:text-indigo-600 transition-colors"><?= $stats[$stat[1]] ?? '?' ?><span class="text-xs font-bold text-slate-300 ml-1"><?= $stat[2] ?></span></div>
                <div class="w-full bg-slate-100 h-2 rounded-full mt-6 overflow-hidden"><div class="bg-<?= $stat[4] ?>-500 h-full rounded-full transition-all duration-1000" style="width: <?= $stats[$stat[1]] ?? 0 ?>%"></div></div>
            </div><?php endforeach; ?>
            <div class="bg-slate-900 p-8 rounded-[2rem] shadow-2xl text-white border border-indigo-500/30">
                <span class="text-[10px] font-black text-slate-500 uppercase tracking-widest block mb-4">Connectivity</span>
                <div class="text-3xl font-black text-emerald-400 tracking-tighter">ONLINE</div>
                <div class="text-[10px] font-black text-slate-500 mt-4 truncate font-mono"><?= e($active_server['host']) ?></div>
            </div>
        </section>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-8">
            <section class="bg-white p-10 rounded-[2.5rem] border border-slate-200 shadow-xl">
                <h2 class="font-black text-slate-900 text-2xl mb-8 tracking-tight uppercase flex items-center"><i class="fa-solid fa-plus-circle mr-4 text-indigo-600 text-2xl"></i>Provisioning</h2>
                <form method="post" class="space-y-6">
                    <input type="hidden" name="csrf" value="<?= csrf_token() ?>"><input type="hidden" name="node_action" value="create">
                    <div class="grid grid-cols-2 gap-6">
                        <div><label class="text-[10px] font-black text-slate-400 uppercase tracking-widest block mb-2 ml-1">Prefix</label>
                        <input type="text" name="db_prefix" placeholder="clienta" class="w-full rounded-2xl border-slate-200 bg-slate-50 p-4 focus:ring-indigo-500" required></div>
                        <div><label class="text-[10px] font-black text-slate-400 uppercase tracking-widest block mb-2 ml-1">Suffix</label>
                        <input type="text" name="db_suffix" value="db" class="w-full rounded-2xl border-slate-200 bg-slate-50 p-4 focus:ring-indigo-500" required></div>
                    </div>
                    <div><label class="text-[10px] font-black text-slate-400 uppercase tracking-widest block mb-2 ml-1">Access Policy (Host)</label>
                    <input type="text" name="remote_host" value="localhost" class="w-full rounded-2xl border-slate-200 bg-slate-50 p-4 focus:ring-indigo-500 font-mono" required></div>
                    <button class="w-full bg-indigo-600 text-white font-black py-5 rounded-2xl uppercase tracking-widest text-xs shadow-2xl shadow-indigo-500/30 hover:bg-indigo-500 hover:-translate-y-1 transition-all">Execute Remote Provisioning</button>
                </form>
            </section>
            
            <section class="bg-white p-10 rounded-[2.5rem] border border-slate-200 shadow-xl overflow-hidden flex flex-col">
                <h2 class="font-black text-slate-900 text-2xl mb-8 tracking-tight uppercase flex items-center"><i class="fa-solid fa-database mr-4 text-indigo-600 text-2xl"></i>Active Fleet</h2>
                <div class="flex-grow overflow-y-auto pr-4 scrollbar-thin scrollbar-thumb-slate-200">
                    <table class="min-w-full divide-y divide-slate-100">
                        <tbody class="divide-y divide-slate-50"><?php foreach($tenants as $t): if(isset($t['error'])) continue; ?>
                            <tr class="group"><td class="py-5 font-black text-slate-700 group-hover:text-indigo-600 transition-colors"><?= e($t['db']) ?></td>
                                <td class="py-5 text-right">
                                    <a href="<?= rtrim($active_server['public_url'], '/') ?>/phpmyadmin" target="_blank" class="text-[10px] font-black uppercase tracking-widest border-2 border-indigo-50 px-6 py-2 rounded-xl text-indigo-600 hover:bg-indigo-600 hover:text-white transition-all shadow-sm">Inspect</a>
                                </td></tr><?php endforeach; ?></tbody></table></div></section></div>
    <?php endif; ?>

    <div id="modal-add" class="hidden fixed inset-0 bg-slate-900/90 backdrop-blur-xl flex items-center justify-center p-8 z-50 animate-fade-in">
        <form method="post" class="bg-white p-12 rounded-[3rem] shadow-2xl w-full max-w-lg border border-slate-100">
            <input type="hidden" name="csrf" value="<?= csrf_token() ?>"><input type="hidden" name="action" value="add_server">
            <h2 class="text-3xl font-black mb-10 text-slate-900 tracking-tighter text-center">Node Initialization</h2>
            <div class="space-y-6">
                <div><label class="text-[10px] font-black text-slate-400 uppercase tracking-widest ml-1 block mb-2">Display Name</label>
                <input type="text" name="name" class="w-full rounded-2xl border-slate-200 bg-slate-50 p-4 focus:ring-indigo-500" required></div>
                <div class="grid grid-cols-2 gap-6">
                    <div><label class="text-[10px] font-black text-slate-400 uppercase tracking-widest ml-1 block mb-2">Internal IP</label>
                    <input type="text" name="host" class="w-full rounded-2xl border-slate-200 bg-slate-50 p-4 focus:ring-indigo-500 font-mono text-xs" required></div>
                    <div><label class="text-[10px] font-black text-slate-400 uppercase tracking-widest ml-1 block mb-2">Public URL (HTTPS)</label>
                    <input type="text" name="public_url" class="w-full rounded-2xl border-slate-200 bg-slate-50 p-4 focus:ring-indigo-500 font-mono text-xs" required></div>
                </div>
                <div><label class="text-[10px] font-black text-slate-400 uppercase tracking-widest ml-1 block mb-2">Security Token (Agent Key)</label>
                <input type="password" name="agent_key" class="w-full rounded-2xl border-slate-200 bg-slate-50 p-4 focus:ring-indigo-500 font-mono text-xs" required></div>
            </div>
            <div class="flex justify-end space-x-6 mt-12">
                <button type="button" onclick="document.getElementById('modal-add').classList.add('hidden')" class="px-8 py-2 text-slate-400 font-black uppercase tracking-widest text-[10px]">Abort</button>
                <button type="submit" class="bg-indigo-600 text-white px-12 py-4 rounded-2xl font-black uppercase tracking-widest text-[10px] shadow-2xl shadow-indigo-500/40 hover:bg-indigo-500 transition-all">Link Infrastructure</button>
            </div>
        </form></div>
</main>
<footer class="text-center py-16 text-[10px] font-black text-slate-300 uppercase tracking-[0.5em]">&copy; <?= date('Y') ?> Shield Platform &bull; Global Distributed Engine</footer>
</body></html>
PHPHUB

  sed -i "s|__HUB_USER__|${HUB_ADMIN_USER}|g" "$HUB_ROOT/index.php"
  sed -i "s|__HUB_HASH__|${HUB_ADMIN_HASH}|g" "$HUB_ROOT/index.php"
  sed -i "s|__CSRF_SECRET__|${CSRF_SECRET}|g" "$HUB_ROOT/index.php"
  sed -i "s|__PAYSTACK_SECRET__|${PAYSTACK_SECRET}|g" "$HUB_ROOT/index.php"

  chown -R www-data:www-data "$HUB_ROOT"
  chmod 750 "$HUB_ROOT"
  touch "$HUB_ROOT/hub_data.sqlite"
  chown www-data:www-data "$HUB_ROOT/hub_data.sqlite"
  chmod 660 "$HUB_ROOT/hub_data.sqlite"

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
  msg_header "Configuring Firewall"
  ufw allow OpenSSH
  ufw allow 'Apache Full'
  ufw --force enable
}

write_summary() {
  cat > "$SUMMARY_FILE" <<EOF
Shield Hub Installation Successful
Domain: http://${SITE_FQDN}/${HUB_ALIAS}
Admin User: ${HUB_ADMIN_USER}
Admin Pass: ${HUB_ADMIN_PASS}
Paystack Status: ${PAYSTACK_SECRET:+'Active'}${PAYSTACK_SECRET:-'Not Set'}
EOF
  echo -e "\n${CLR_BOLD}${CLR_GREEN}Hub initialized successfully!${CLR_RESET}"
  echo -e "Access Key: ${CLR_YELLOW}${HUB_ADMIN_PASS}${CLR_RESET}"
}

main() {
  clear; require_ubuntu; wizard; install_packages; deploy_hub; systemctl restart apache2; configure_firewall; write_summary
}

main "$@"
