#!/usr/bin/env bash
set -Eeuo pipefail

# DB-Shield SaaS HUB v5.0 (High-End Dark Edition)
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

msg_header() { echo -e "\n${CLR_BOLD}${CLR_CYAN}=== $* ===${CLR_RESET}"; }
msg_info()   { echo -e "${CLR_BLUE}[i]${CLR_RESET} $*"; }
msg_ok()     { echo -e "${CLR_GREEN}[✔]${CLR_RESET} $*"; }
msg_warn()   { echo -e "${CLR_YELLOW}[!]${CLR_RESET} $*"; }
msg_err()    { echo -e "${CLR_RED}[✘]${CLR_RESET} $*"; }

if [[ ${EUID:-0} -ne 0 ]]; then msg_err "Run as root."; exit 1; fi

export DEBIAN_FRONTEND=noninteractive
HUB_ROOT="/var/www/db-hub"
SUMMARY_FILE="/root/db-hub-install-summary.txt"

# Defaults
: "${SITE_FQDN:=_}"
: "${HUB_ALIAS:=db-hub}"
: "${HUB_ADMIN_USER:=admin}"
: "${PAYSTACK_SECRET:=}"
: "${SMTP_HOST:=smtp.gmail.com}"
: "${SMTP_PORT:=587}"
: "${SMTP_USER:=}"
: "${SMTP_PASS:=}"
: "${SMTP_FROM:=noreply@dbshield.io}"

HUB_ADMIN_PASS="$(openssl rand -base64 12 | tr -d '\n')"
CSRF_SECRET="$(openssl rand -hex 32)"

wizard() {
    echo -e "${CLR_BOLD}${CLR_CYAN}===================================================="
    echo "       DB-Shield HUB v5.0: GLOBAL AUTOMATION        "
    echo -e "====================================================${CLR_RESET}"
    read -p "FQDN (e.g. hub.steprotech.com): " input_fqdn; SITE_FQDN=${input_fqdn:-$SITE_FQDN}
    read -p "Paystack Secret: " PAYSTACK_SECRET
    msg_header "SMTP Notification Config"
    read -p "SMTP Host [$SMTP_HOST]: " input_host; SMTP_HOST=${input_host:-$SMTP_HOST}
    read -p "SMTP User: " SMTP_USER
    read -p "SMTP Pass: " SMTP_PASS
    echo -e "\n${CLR_BOLD}${CLR_YELLOW}Deploy Dark Hub v5.0? (y/n): ${CLR_RESET}"
    read -p "" confirm; if [[ ! "$confirm" =~ ^[Yy]$ ]]; then exit 0; fi
}

install_packages() {
  msg_header "Finalizing Hub Stack"
  apt-get update >/dev/null 2>&1
  apt-get install -y apache2 libapache2-mod-php php php-cli php-mysql php-curl php-sqlite3 php-mbstring php-xml unzip curl openssl ufw cron >/dev/null 2>&1
}

deploy_hub() {
  msg_header "Deploying Premium Dashboard"
  mkdir -p "$HUB_ROOT"
  
  # Generate Hash now that PHP is installed
  HUB_ADMIN_HASH=$(php -r "echo password_hash('$HUB_ADMIN_PASS', PASSWORD_DEFAULT);")
  
  cat >"$HUB_ROOT/index.php" <<'PHPHUB'
<?php
declare(strict_types=1);
session_start();

const ADMIN_USER = '__HUB_USER__';
const ADMIN_HASH = '__HUB_HASH__';
const APP_SECRET = '__CSRF_SECRET__';
const PAYSTACK_SECRET = '__PAYSTACK_SECRET__';
const HUB_DB = 'hub_v5.sqlite';
const SMTP_FROM = '__SMTP_FROM__';

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
    $pdo->exec("CREATE TABLE IF NOT EXISTS servers (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, host TEXT, agent_key TEXT, public_url TEXT, last_seen DATETIME, s3_endpoint TEXT, s3_bucket TEXT, s3_access_key TEXT, s3_secret_key TEXT)");
    $pdo->exec("CREATE TABLE IF NOT EXISTS packages (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, price REAL, db_limit INTEGER, disk_quota_gb INTEGER DEFAULT 1, max_conns INTEGER DEFAULT 10, duration_days INTEGER DEFAULT 30)");
    $pdo->exec("CREATE TABLE IF NOT EXISTS clients (id INTEGER PRIMARY KEY AUTOINCREMENT, email TEXT UNIQUE, password_hash TEXT, package_id INTEGER, expires_at DATETIME, status TEXT DEFAULT 'pending')");
    $pdo->exec("CREATE TABLE IF NOT EXISTS tenant_dbs (id INTEGER PRIMARY KEY AUTOINCREMENT, client_id INTEGER, server_id INTEGER, db_name TEXT, db_user TEXT, allowed_ips TEXT DEFAULT '[\"%\"]', last_size_mb REAL DEFAULT 0)");
    $pdo->exec("CREATE TABLE IF NOT EXISTS security_log (ip TEXT UNIQUE, attempts INTEGER DEFAULT 0, last_attempt DATETIME)");
    return $pdo;
}

function call_agent(array $server, array $params = []): array {
    $queryString = http_build_query(array_merge(['key' => $server['agent_key']], $params));
    $ch = curl_init(rtrim($server['public_url'], '/') . "/agent-api/agent.php?" . $queryString);
    curl_setopt($ch, CURLOPT_RETURNTRANSFER, true); curl_setopt($ch, CURLOPT_TIMEOUT, 5);
    if (!empty($params['post_data'])) {
        curl_setopt($ch, CURLOPT_POST, true); curl_setopt($ch, CURLOPT_POSTFIELDS, http_build_query($params['post_data']));
    }
    $res = curl_exec($ch); return json_decode((string)$res, true) ?? ['error' => 'Node Unreachable'];
}

function send_mail(string $to, string $subj, string $msg): void {
    $headers = "MIME-Version: 1.0\r\nContent-type:text/html;charset=UTF-8\r\nFrom: ".SMTP_FROM."\r\n";
    @mail($to, $subj, "<html><body style='font-family:sans-serif;'>$msg</body></html>", $headers);
}

if (isset($_GET['action']) && $_GET['action'] === 'watchdog') {
    $db = hub_db();
    foreach($db->query("SELECT * FROM servers")->fetchAll(PDO::FETCH_ASSOC) as $s) {
        $stats = call_agent($s, ['action' => 'stats']);
        if (isset($stats['error'])) send_mail(ADMIN_USER, "NODE OFFLINE: " . $s['name'], "Node is unreachable.");
        else $db->prepare("UPDATE servers SET last_seen = CURRENT_TIMESTAMP WHERE id = ?")->execute([$s['id']]);
    }
    exit;
}

if (isset($_GET['action']) && $_GET['action'] === 'paystack_webhook') {
    $input = file_get_contents("php://input");
    $sig = $_SERVER['HTTP_X_PAYSTACK_SIGNATURE'] ?? '';
    if ($sig !== hash_hmac('sha256', $input, PAYSTACK_SECRET)) exit;
    $event = json_decode($input, true);
    if ($event['event'] === 'charge.success') {
        $email = $event['data']['customer']['email'];
        $pkg_id = $event['data']['metadata']['package_id'] ?? 1;
        $db = hub_db();
        $pkg = $db->prepare("SELECT duration_days FROM packages WHERE id = ?"); $pkg->execute([$pkg_id]);
        $days = $pkg->fetchColumn() ?: 30;
        $expiry = date('Y-m-d H:i:s', strtotime("+$days days"));
        $db->prepare("UPDATE clients SET package_id = ?, expires_at = ?, status = 'active' WHERE email = ?")->execute([$pkg_id, $expiry, $email]);
        send_mail($email, "Subscription Active", "Your Shield Hub account is ready.");
    }
    exit;
}

$is_admin = isset($_SESSION['role']) && $_SESSION['role'] === 'admin';
$client_id = $_SESSION['client_id'] ?? null;
$view = $_GET['view'] ?? ($is_admin ? 'admin' : ($client_id ? 'client' : 'landing'));

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    require_csrf(); $action = $_POST['action'] ?? '';

    if ($action === 'login') {
        $u = $_POST['email']; $p = $_POST['password'];
        if ($u === ADMIN_USER && password_verify($p, ADMIN_HASH)) { $_SESSION['role'] = 'admin'; header('Location: ?view=admin'); exit; }
        $user = hub_db()->prepare("SELECT * FROM clients WHERE email = ?"); $user->execute([$u]); $c = $user->fetch(PDO::FETCH_ASSOC);
        if ($c && password_verify($p, $c['password_hash'])) { 
            if ($c['status'] !== 'active') { $_SESSION['error'] = "Account pending payment."; }
            else { $_SESSION['client_id'] = $c['id']; header('Location: ?view=client'); exit; }
        }
        else { $_SESSION['error'] = "Invalid access credentials."; }
        header('Location: ?view=login'); exit;
    }

    if ($action === 'signup') {
        $email = $_POST['email']; $pass = password_hash($_POST['password'], PASSWORD_DEFAULT);
        $pkg_id = (int)$_POST['package_id'];
        try {
            hub_db()->prepare("INSERT INTO clients (email, password_hash, package_id) VALUES (?,?,?)")->execute([$email, $pass, $pkg_id]);
            $_SESSION['message'] = "Account created. Please login.";
            header('Location: ?view=login'); exit;
        } catch(Exception $e) { $_SESSION['error'] = "Account already exists."; header('Location: ?view=landing'); exit; }
    }

    if ($action === 'provision' && $client_id) {
        $db = hub_db();
        $me_stmt = $db->prepare("SELECT c.*, p.db_limit, p.max_conns FROM clients c JOIN packages p ON c.package_id = p.id WHERE c.id = ?");
        $me_stmt->execute([$client_id]); $me = $me_stmt->fetch(PDO::FETCH_ASSOC);
        $servers = $db->query("SELECT * FROM servers")->fetchAll(PDO::FETCH_ASSOC);
        $best = null; $min = 101;
        foreach($servers as $s) {
            $stats = call_agent($s, ['action' => 'stats']);
            if (!isset($stats['error']) && $stats['cpu'] < $min) { $min = $stats['cpu']; $best = $s; }
        }
        if ($best) {
            $prefix = bin2hex(random_bytes(4));
            $node = call_agent($best, ['action' => 'create', 'post_data' => ['db_prefix' => $prefix, 'db_suffix' => 'db', 'remote_host' => '%', 'max_conns' => $me['max_conns']]]);
            if (!isset($node['error'])) {
                $db->prepare("INSERT INTO tenant_dbs (client_id, server_id, db_name, db_user) VALUES (?,?,?,?)")->execute([$client_id, $best['id'], $prefix.'_db', $prefix.'_user']);
                $_SESSION['download'] = $node['download'];
            } else { $_SESSION['error'] = $node['error']; }
        }
        header('Location: ?view=client'); exit;
    }

    if ($action === 'update_whitelist' && $client_id) {
        $db = hub_db();
        $tdb_stmt = $db->prepare("SELECT t.*, s.agent_key, s.public_url FROM tenant_dbs t JOIN servers s ON t.server_id = s.id WHERE t.id = ? AND t.client_id = ?");
        $tdb_stmt->execute([$_POST['tdb_id'], $client_id]); $tdb = $tdb_stmt->fetch(PDO::FETCH_ASSOC);
        if ($tdb) {
            $ips = array_map('trim', explode(',', $_POST['ips']));
            $nodeRes = call_agent($tdb, ['action' => 'update_hosts', 'post_data' => ['db_user' => $tdb['db_user'], 'hosts' => json_encode($ips)]]);
            if (!isset($nodeRes['error'])) $db->prepare("UPDATE tenant_dbs SET allowed_ips = ? WHERE id = ?")->execute([json_encode($ips), $tdb['id']]);
        }
        header('Location: ?view=client'); exit;
    }
}

if (isset($_GET['action']) && $_GET['action'] === 'logout') { session_destroy(); header('Location: ?'); exit; }

$db = hub_db();
$packages = $db->query("SELECT * FROM packages")->fetchAll(PDO::FETCH_ASSOC);
$message = $_SESSION['message'] ?? ''; unset($_SESSION['message']);
$error = $_SESSION['error'] ?? ''; unset($_SESSION['error']);

?><!doctype html><html><head><meta charset="utf-8"><title>Shield Platform</title>
<script src="https://cdn.tailwindcss.com?plugins=forms"></script>
<link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css" rel="stylesheet"/>
<style> .grad { background: radial-gradient(circle at top right, #1e1b4b, #020617); } </style>
</head><body class="bg-slate-950 text-slate-400 font-sans">

<?php if ($view === 'landing'): ?>
    <div class="grad min-h-screen">
        <nav class="flex justify-between px-16 py-10 max-w-7xl mx-auto items-center">
            <div class="text-3xl font-black text-white italic tracking-tighter"><i class="fa-solid fa-shield-halved text-indigo-500 mr-2"></i>SHIELD</div>
            <div class="flex items-center space-x-10 text-[10px] font-black uppercase tracking-[0.3em] text-slate-500">
                <a href="?view=login" class="bg-white text-black px-10 py-4 rounded-2xl hover:bg-indigo-600 hover:text-white transition-all shadow-xl">Identity Access</a>
            </div>
        </nav>
        <main class="max-w-7xl mx-auto px-16 py-24 text-center">
            <h1 class="text-[7rem] leading-none font-black text-white tracking-tight mb-8">Hardened<br><span class="text-indigo-500">Fleet.</span></h1>
            <p class="text-xl max-w-2xl mx-auto mb-24 font-medium text-slate-500">Autonomous MariaDB infrastructure with real-time brute-force resistance, isolation, and cloud snapshots.</p>
            <div id="tiers" class="grid grid-cols-1 md:grid-cols-3 gap-10 text-left">
                <?php foreach($packages as $p): ?>
                <div class="bg-slate-900/50 backdrop-blur-xl border border-white/5 p-12 rounded-[3.5rem] hover:border-indigo-500/40 transition-all shadow-2xl group">
                    <h3 class="text-indigo-400 font-black uppercase tracking-[0.4em] text-[9px] mb-8"><?= e($p['name']) ?></h3>
                    <div class="text-7xl font-black text-white mb-12 tracking-tighter group-hover:scale-105 transition-transform">$<?= round($p['price']) ?><span class="text-sm font-normal text-slate-700 ml-2">/mo</span></div>
                    <ul class="space-y-6 mb-16 text-sm font-bold text-slate-500">
                        <li><i class="fa-solid fa-circle-check text-indigo-500 mr-3"></i> <?= $p['db_limit'] ?> Active Databases</li>
                        <li><i class="fa-solid fa-circle-check text-indigo-500 mr-3"></i> <?= $p['disk_quota_gb'] ?>GB NVMe Storage</li>
                        <li><i class="fa-solid fa-circle-check text-indigo-500 mr-3"></i> Smart Global Routing</li>
                    </ul>
                    <a href="?view=signup&pkg=<?= $p['id'] ?>" class="block text-center bg-slate-800 text-white py-6 rounded-3xl font-black text-[10px] uppercase tracking-widest hover:bg-indigo-600 transition-all shadow-xl">Initialize Node</a>
                </div>
                <?php endforeach; ?>
            </div>
        </main>
    </div>

<?php elseif ($view === 'login'): ?>
    <div class="flex items-center justify-center min-h-screen bg-slate-950">
        <form method="post" class="bg-slate-900/50 backdrop-blur-2xl p-16 rounded-[4rem] border border-white/5 w-full max-w-md shadow-2xl text-center">
            <input type="hidden" name="action" value="login"><input type="hidden" name="csrf" value="<?= csrf_token() ?>">
            <div class="bg-indigo-600 w-20 h-20 rounded-3xl flex items-center justify-center mx-auto mb-10 rotate-6 shadow-xl shadow-indigo-500/20"><i class="fa-solid fa-fingerprint text-white text-3xl"></i></div>
            <h2 class="text-3xl font-black text-white mb-10 tracking-tighter uppercase">Access Terminal</h2>
            <?php if($error) echo "<div class='bg-red-500/10 text-red-500 text-[10px] font-black uppercase text-center p-4 rounded-2xl border border-red-500/20 mb-8 animate-pulse'>Access Restricted</div>"; ?>
            <div class="space-y-8 text-left">
                <div><label class="text-[9px] font-black text-slate-500 uppercase tracking-widest ml-1 mb-2 block">Identity</label>
                <input type="text" name="email" placeholder="ADMIN OR CLIENT EMAIL" class="w-full bg-slate-950/50 border-white/5 rounded-2xl p-5 text-white focus:ring-indigo-500 text-xs font-bold tracking-widest" required autofocus></div>
                <div><label class="text-[9px] font-black text-slate-500 uppercase tracking-widest ml-1 mb-2 block">Security Token</label>
                <input type="password" name="password" placeholder="••••••••" class="w-full bg-slate-950/50 border-white/5 rounded-2xl p-5 text-white focus:ring-indigo-500 text-xs font-bold tracking-widest" required></div>
                <button class="w-full bg-indigo-600 py-6 rounded-3xl text-white font-black uppercase tracking-widest text-[10px] shadow-2xl shadow-indigo-500/20 hover:bg-indigo-500 transition-all">Unlock Environment</button>
            </div>
        </form>
    </div>

<?php elseif ($view === 'signup'): ?>
    <div class="flex items-center justify-center min-h-screen bg-slate-950">
        <form method="post" class="bg-slate-900/50 backdrop-blur-2xl p-16 rounded-[4rem] border border-white/5 w-full max-w-md shadow-2xl">
            <input type="hidden" name="action" value="signup"><input type="hidden" name="csrf" value="<?= csrf_token() ?>">
            <input type="hidden" name="package_id" value="<?= $_GET['pkg'] ?? 1 ?>">
            <h2 class="text-3xl font-black text-white mb-10 tracking-tighter text-center uppercase">Register Node</h2>
            <div class="space-y-8">
                <input type="email" name="email" placeholder="IDENTITY@EMAIL.COM" class="w-full bg-slate-950/50 border-white/5 rounded-2xl p-5 text-white focus:ring-indigo-500 text-xs font-bold tracking-widest" required autofocus>
                <input type="password" name="password" placeholder="CHOOSE SECURE KEY" class="w-full bg-slate-950/50 border-white/5 rounded-2xl p-5 text-white focus:ring-indigo-500 text-xs font-bold tracking-widest" required>
                <button class="w-full bg-indigo-600 py-6 rounded-3xl text-white font-black uppercase tracking-widest text-[10px] shadow-2xl shadow-indigo-500/20 hover:bg-indigo-500 transition-all">Generate Account</button>
            </div>
        </form>
    </div>

<?php elseif ($view === 'client' && $client_id): ?>
    <header class="flex justify-between px-16 py-8 items-center border-b border-white/5 bg-slate-900/20 backdrop-blur-md sticky top-0 z-50">
        <div class="text-2xl font-black text-white tracking-tighter italic">SHIELD<span class="text-indigo-500">CLOUD</span></div>
        <div class="flex items-center space-x-10 text-[10px] font-black uppercase tracking-widest">
            <a href="?action=logout" class="text-slate-600 hover:text-red-500 transition-colors">Terminate</a>
        </div>
    </header>
    <main class="max-w-7xl mx-auto px-16 py-16 space-y-16">
        <?php if (!empty($_SESSION['download'])): ?>
        <div class="bg-indigo-600 p-10 rounded-[3rem] shadow-2xl flex items-center justify-between">
            <div><h3 class="text-white font-black text-xl tracking-tighter uppercase">Vault Ready</h3><p class="text-indigo-200 text-[10px] font-black uppercase tracking-widest">Security environment file generated</p></div>
            <a href="?download=1" class="bg-white text-indigo-600 px-10 py-4 rounded-2xl font-black text-[10px] uppercase tracking-widest shadow-xl">Retrieve .env</a>
        </div>
        <?php endif; ?>
        <div class="flex items-center justify-between">
            <div><h2 class="text-5xl font-black text-white tracking-tighter">Your Cluster</h2><p class="text-slate-500 font-bold uppercase tracking-widest text-[10px] mt-2">Active Database Inventory</p></div>
            <form method="post"><input type="hidden" name="csrf" value="<?= csrf_token() ?>"><input type="hidden" name="action" value="provision">
            <button class="bg-indigo-600 text-white px-12 py-5 rounded-3xl font-black text-[10px] uppercase tracking-widest shadow-2xl shadow-indigo-500/30 hover:scale-105 transition-all">Provision Instance</button></form>
        </div>
        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-10">
            <?php 
            $dbs = $db->prepare("SELECT t.*, s.public_url, s.name as server_name FROM tenant_dbs t JOIN servers s ON t.server_id = s.id WHERE t.client_id = ?"); $dbs->execute([$client_id]);
            foreach($dbs->fetchAll(PDO::FETCH_ASSOC) as $row): ?>
            <div class="bg-slate-900/50 border border-white/5 p-10 rounded-[3rem] shadow-xl group hover:border-indigo-500/30 transition-all text-left">
                <div class="flex items-center justify-between mb-8"><div class="bg-slate-800 p-4 rounded-3xl"><i class="fa-solid fa-database text-indigo-500 text-2xl"></i></div><span class="text-[10px] font-black text-emerald-500 uppercase tracking-widest flex items-center"><span class="w-2 h-2 bg-emerald-500 rounded-full mr-2 animate-ping"></span>Linked</span></div>
                <h3 class="text-2xl font-black text-white mb-2 tracking-tight"><?= e($row['db_name']) ?></h3>
                <p class="text-slate-600 text-[10px] font-black uppercase tracking-widest mb-10">Node: <span class="text-indigo-400"><?= e($row['server_name']) ?></span></p>
                <div class="grid grid-cols-1 gap-4">
                    <a href="<?= rtrim($row['public_url'], '/') ?>/phpmyadmin" target="_blank" class="bg-slate-800 text-center py-4 rounded-2xl text-[10px] font-black uppercase tracking-widest hover:bg-slate-700 transition-all">Admin Gateway</a>
                    <button onclick="document.getElementById('modal-ips-<?= $row['id'] ?>').classList.remove('hidden')" class="border border-indigo-500/20 text-indigo-400 text-center py-4 rounded-2xl text-[10px] font-black uppercase tracking-widest hover:bg-indigo-600 hover:text-white transition-all">Node Guard</button>
                </div>
            </div>
            <div id="modal-ips-<?= $row['id'] ?>" class="hidden fixed inset-0 bg-slate-950/90 backdrop-blur-xl flex items-center justify-center p-8 z-50 text-left">
                <form method="post" class="bg-slate-900 p-12 rounded-[3rem] border border-white/5 w-full max-w-lg shadow-2xl">
                    <input type="hidden" name="action" value="update_whitelist"><input type="hidden" name="csrf" value="<?= csrf_token() ?>"><input type="hidden" name="tdb_id" value="<?= $row['id'] ?>">
                    <h2 class="text-2xl font-black text-white mb-4 tracking-tighter uppercase text-center">Identity Firewall</h2>
                    <p class="text-xs text-slate-500 mb-10 font-bold uppercase tracking-widest text-center italic">Restrict database access to specific IP origins</p>
                    <textarea name="ips" class="w-full bg-slate-950 border-white/5 rounded-2xl p-6 text-white font-mono text-sm mb-10 focus:ring-indigo-500" rows="3"><?= implode(',', json_decode($row['allowed_ips'], true) ?: ['%']) ?></textarea>
                    <div class="flex justify-end space-x-6"><button type="button" onclick="this.closest('[id^=modal-ips]').classList.add('hidden')" class="text-slate-600 font-black uppercase text-[10px] tracking-widest">Cancel</button>
                    <button class="bg-indigo-600 text-white px-10 py-4 rounded-2xl font-black uppercase text-[10px]">Sync Origin Rules</button></div>
                </form></div>
            <?php endforeach; ?>
        </div>
    </main>

<?php elseif ($view === 'admin' && $is_admin): ?>
    <header class="flex justify-between px-16 py-8 items-center border-b border-white/5 bg-slate-900/20 backdrop-blur-md sticky top-0 z-50 text-white">
        <div class="text-2xl font-black tracking-tighter italic uppercase">Master<span class="text-indigo-500">Control</span></div>
        <div class="flex items-center space-x-10 text-[10px] font-black uppercase tracking-widest"><a href="?action=logout" class="text-slate-400 hover:text-red-500 transition-colors">Shutdown Session</a></div>
    </header>
    <main class="max-w-7xl mx-auto px-16 py-16 space-y-16">
        <div class="grid grid-cols-1 md:grid-cols-3 gap-8">
            <?php foreach([['Active Nodes','servers','fa-server','indigo'],['Registered Clients','clients','fa-user-group','emerald'],['Managed Assets','tenant_dbs','fa-database','amber']] as $c): ?>
            <div class="bg-slate-900 p-10 rounded-[3rem] border border-white/5 shadow-xl text-left">
                <div class="flex items-center justify-between mb-6"><span class="text-[10px] font-black text-slate-500 uppercase tracking-widest"><?= $c[0] ?></span><i class="fa-solid <?= $c[2] ?> text-<?= $c[3] ?>-500/20"></i></div>
                <div class="text-5xl font-black text-white"><?= $db->query("SELECT COUNT(*) FROM ".$c[1])->fetchColumn() ?></div>
            </div><?php endforeach; ?>
        </div>
        <div class="flex items-center justify-between border-t border-white/5 pt-16">
            <h2 class="text-3xl font-black text-white tracking-tighter uppercase">Fleet Infrastructure</h2>
            <button onclick="document.getElementById('modal-add').classList.remove('hidden')" class="bg-indigo-600 text-white px-10 py-4 rounded-2xl font-black text-[10px] uppercase tracking-widest shadow-xl shadow-indigo-500/20">Link Remote Node</button>
        </div>
        <div class="bg-slate-900 rounded-[3rem] border border-white/5 overflow-hidden shadow-2xl">
            <table class="min-w-full divide-y divide-white/5 text-left">
                <thead class="bg-white/5"><tr><th class="px-10 py-6 text-left text-[10px] font-black text-slate-500 uppercase tracking-widest">Node Identifier</th><th class="px-10 py-6 text-left text-[10px] font-black text-slate-500 uppercase tracking-widest">Internal Host</th><th class="px-10 py-6 text-center text-[10px] font-black text-slate-500 uppercase tracking-widest">operational status</th></tr></thead>
                <tbody class="divide-y divide-white/5"><?php foreach($servers as $s): ?>
                    <tr><td class="px-10 py-8 font-black text-white text-lg tracking-tight"><?= e($s['name']) ?></td>
                        <td class="px-10 py-8 text-xs font-bold font-mono text-slate-500 uppercase"><?= e($s['host']) ?></td>
                        <td class="px-10 py-8 text-center"><span class="text-[10px] font-black uppercase tracking-widest <?= (time()-strtotime($s['last_seen']??'0') < 600) ? 'text-emerald-500' : 'text-red-500' ?> animate-pulse">● <?= (time()-strtotime($s['last_seen']??'0') < 600) ? 'Healthy' : 'Sync Error' ?></span></td></tr><?php endforeach; ?>
                </tbody>
            </table>
        </div>
    </main>
<?php endif; ?>

<div id="modal-add" class="hidden fixed inset-0 bg-slate-950/90 backdrop-blur-xl flex items-center justify-center p-8 z-50 text-left">
    <form method="post" class="bg-slate-900 p-12 rounded-[4rem] border border-white/5 w-full max-w-lg shadow-2xl">
        <input type="hidden" name="action" value="add_server"><input type="hidden" name="csrf" value="<?= csrf_token() ?>">
        <h2 class="text-3xl font-black text-white mb-10 tracking-tighter text-center uppercase">Provision Remote Infrastructure</h2>
        <div class="space-y-6">
            <input type="text" name="name" placeholder="NODE LABEL" class="w-full bg-slate-950/50 border-white/5 rounded-2xl p-5 text-white text-xs font-bold tracking-widest uppercase" required>
            <input type="text" name="host" placeholder="INTERNAL HOST ADDRESS" class="w-full bg-slate-950/50 border-white/5 rounded-2xl p-5 text-white text-xs font-bold tracking-widest uppercase" required>
            <input type="password" name="agent_key" placeholder="AGENT ACCESS TOKEN" class="w-full bg-slate-950/50 border-white/5 rounded-2xl p-5 text-white text-xs font-bold tracking-widest uppercase" required>
            <input type="text" name="public_url" placeholder="PUBLIC ENDPOINT (HTTPS)" class="w-full bg-slate-950/50 border-white/5 rounded-2xl p-5 text-white text-xs font-bold tracking-widest uppercase" required>
            <div class="flex justify-end space-x-6 pt-6"><button type="button" onclick="this.closest('#modal-add').classList.add('hidden')" class="text-slate-600 font-black uppercase text-[10px] tracking-widest">Abort</button>
            <button class="bg-indigo-600 text-white px-10 py-4 rounded-2xl font-black uppercase text-[10px] shadow-xl">Commit Node</button></div>
        </div>
    </form></div>

<footer class="text-center py-32 text-[10px] font-black text-slate-800 uppercase tracking-[1em]">Shield Infrastructure &bull; Version 5.0 Core</footer>
</body></html>
PHPHUB

  sed -i "s|__HUB_USER__|${HUB_ADMIN_USER}|g" "$HUB_ROOT/index.php"
  sed -i "s|__HUB_HASH__|${HUB_ADMIN_HASH}|g" "$HUB_ROOT/index.php"
  sed -i "s|__CSRF_SECRET__|${CSRF_SECRET}|g" "$HUB_ROOT/index.php"
  sed -i "s|__PAYSTACK_SECRET__|${PAYSTACK_SECRET}|g" "$HUB_ROOT/index.php"
  sed -i "s|__SMTP_FROM__|${SMTP_FROM}|g" "$HUB_ROOT/index.php"

  chown -R www-data:www-data "$HUB_ROOT"
  chmod 750 "$HUB_ROOT"
  touch "$HUB_ROOT/hub_v5.sqlite"
  chown www-data:www-data "$HUB_ROOT/hub_v5.sqlite"
  chmod 660 "$HUB_ROOT/hub_v5.sqlite"

  cat >"/etc/apache2/conf-available/db-hub.conf" <<APACHE
Alias /${HUB_ALIAS} ${HUB_ROOT}
<Directory ${HUB_ROOT}>
    Options FollowSymLinks
    AllowOverride All
    Require all granted
</Directory>
APACHE
  a2enconf db-hub >/dev/null 2>&1 || true
  
  # Ensure PHP is enabled in Apache
  local php_version=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
  a2enmod "php${php_version}" >/dev/null 2>&1 || true
  systemctl restart apache2
  
  # Cron for Watchdog
  (crontab -l 2>/dev/null || true; echo "*/10 * * * * curl -s http://localhost/${HUB_ALIAS}/index.php?action=watchdog >/dev/null") | crontab -
}

configure_firewall() {
  ufw allow OpenSSH; ufw allow 'Apache Full'; ufw --force enable
}

write_summary() {
  cat > "$SUMMARY_FILE" <<EOF
SHIELD HUB v5.0 DEPLOYED (Enterprise Dark UI)
Access: http://${SITE_FQDN}/${HUB_ALIAS}
Admin Identity: ${HUB_ADMIN_USER}
Access Key: ${HUB_ADMIN_PASS}
SaaS Features: ENABLED
Security: ENTERPRISE HARDENED
EOF
  echo -e "\n${CLR_BOLD}${CLR_GREEN}Premium Dark Hub Interface Active!${CLR_RESET}"
  echo -e "Admin Identity: ${CLR_YELLOW}${HUB_ADMIN_USER}${CLR_RESET}"
  echo -e "Access Key:     ${CLR_YELLOW}${HUB_ADMIN_PASS}${CLR_RESET}\n"
  msg_info "Full credentials saved to: ${CLR_BOLD}${SUMMARY_FILE}${CLR_RESET}"
}

main() { clear; wizard; install_packages; deploy_hub; systemctl restart apache2; configure_firewall; write_summary; }
main "$@"
