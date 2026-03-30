#!/usr/bin/env bash
set -Eeuo pipefail

# DB-Shield SaaS HUB v5.0 (Enterprise Automation Edition)
# Complete SaaS: Landing Page, Paystack, Brute-Force Shield, Watchdog, Resource Quotas.
# Professional Shadcn-inspired UI.

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
    echo -e "\n${CLR_BOLD}${CLR_YELLOW}Deploy Enterprise Hub v5.0? (y/n): ${CLR_RESET}"
    read -p "" confirm; if [[ ! "$confirm" =~ ^[Yy]$ ]]; then exit 0; fi
}

install_packages() {
  msg_header "Finalizing Hub Stack"
  apt-get update >/dev/null 2>&1
  apt-get install -y apache2 libapache2-mod-php php php-cli php-mysql php-curl php-sqlite3 php-mbstring php-xml unzip curl openssl ufw cron >/dev/null 2>&1
}

deploy_hub() {
  msg_header "Deploying Intelligent Platform Hub"
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
header("Content-Security-Policy: default-src 'self' https://cdn.tailwindcss.com https://cdnjs.cloudflare.com https://fonts.googleapis.com https://fonts.gstatic.com; style-src 'self' 'unsafe-inline' https://cdnjs.cloudflare.com https://fonts.googleapis.com; font-src 'self' https://cdnjs.cloudflare.com https://fonts.gstatic.com;");

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
        else { $_SESSION['error'] = "Invalid credentials."; }
        header('Location: ?view=login'); exit;
    }

    if ($action === 'signup') {
        $email = $_POST['email']; $pass = password_hash($_POST['password'], PASSWORD_DEFAULT);
        $pkg_id = (int)$_POST['package_id'];
        try {
            hub_db()->prepare("INSERT INTO clients (email, password_hash, package_id) VALUES (?,?,?)")->execute([$email, $pass, $pkg_id]);
            $_SESSION['message'] = "Account created. Proceed to payment.";
            header('Location: ?view=payment&email='.$email.'&pkg='.$pkg_id); exit;
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

?><!doctype html><html><head><meta charset="utf-8"><title>Shield Hub</title>
<script src="https://cdn.tailwindcss.com?plugins=forms"></script>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Geist:wght@100..900&display=swap" rel="stylesheet">
<link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css" rel="stylesheet"/>
<script>
    tailwind.config = {
      theme: {
        extend: {
          fontFamily: { sans: ['Geist', 'sans-serif'] },
          colors: { border: 'hsl(240 5.9% 90%)', input: 'hsl(240 5.9% 90%)', ring: 'hsl(240 5.9% 10%)', background: 'hsl(0 0% 100%)', foreground: 'hsl(240 10% 3.9%)', primary: { DEFAULT: 'hsl(240 5.9% 10%)', foreground: 'hsl(0 0% 98%)' }, secondary: { DEFAULT: 'hsl(240 4.8% 95.9%)', foreground: 'hsl(240 5.9% 10%)' }, muted: { DEFAULT: 'hsl(240 4.8% 95.9%)', foreground: 'hsl(240 3.8% 46.1%)' }, accent: { DEFAULT: 'hsl(240 4.8% 95.9%)', foreground: 'hsl(240 5.9% 10%)' } }
        }
      }
    }
</script>
<style>
    body { font-family: 'Geist', sans-serif; }
    .btn-primary { @apply inline-flex items-center justify-center whitespace-nowrap rounded-md text-sm font-medium transition-colors focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring disabled:pointer-events-none disabled:opacity-50 bg-primary text-primary-foreground shadow hover:bg-primary/90 h-9 px-4 py-2; }
    .input-base { @apply flex h-9 w-full rounded-md border border-input bg-transparent px-3 py-1 text-sm shadow-sm transition-colors file:border-0 file:bg-transparent file:text-sm file:font-medium placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring disabled:cursor-not-allowed disabled:opacity-50; }
    .card-base { @apply rounded-xl border bg-card text-card-foreground shadow; }
</style>
</head><body class="bg-background text-foreground antialiased">

<?php if ($view === 'landing'): ?>
    <div class="relative flex min-h-screen flex-col">
        <header class="sticky top-0 z-50 w-full border-b bg-background/95 backdrop-blur supports-[backdrop-filter]:bg-background/60">
            <div class="container flex h-14 items-center max-w-7xl mx-auto px-4">
                <div class="flex items-center space-x-2 mr-4 font-bold tracking-tighter text-xl">
                    <i class="fa-solid fa-shield-halved text-primary"></i><span>Shield Hub</span>
                </div>
                <div class="flex flex-1 items-center justify-end space-x-4">
                    <nav class="flex items-center space-x-6 text-sm font-medium">
                        <a href="#pricing" class="transition-colors hover:text-foreground/80 text-foreground/60">Pricing</a>
                        <a href="?view=login" class="btn-primary">Sign In</a>
                    </nav>
                </div>
            </div>
        </header>
        <main class="flex-1">
            <section class="container max-w-7xl mx-auto px-4 py-24 text-center space-y-8">
                <h1 class="text-4xl font-bold tracking-tighter sm:text-5xl md:text-6xl lg:text-7xl">Secure. Scalable.<br><span class="text-muted-foreground">Databases.</span></h1>
                <p class="mx-auto max-w-[700px] text-muted-foreground md:text-xl">High-performance MariaDB instances with real-time brute-force protection and automated cloud snapshots.</p>
                <div class="flex justify-center space-x-4">
                    <a href="#pricing" class="btn-primary px-8 h-11 text-base">Get Started</a>
                </div>
            </section>
            <section id="pricing" class="container max-w-7xl mx-auto px-4 py-24 space-y-12">
                <div class="grid grid-cols-1 md:grid-cols-3 gap-8">
                    <?php foreach($packages as $p): ?>
                    <div class="card-base p-8 space-y-6 flex flex-col justify-between hover:border-foreground/20 transition-all">
                        <div class="space-y-2">
                            <h3 class="font-bold text-lg"><?= e($p['name']) ?></h3>
                            <div class="text-4xl font-bold tracking-tighter">$<?= round($p['price']) ?><span class="text-sm font-normal text-muted-foreground ml-1">/mo</span></div>
                        </div>
                        <ul class="space-y-2 text-sm text-muted-foreground flex-1 mt-6">
                            <li class="flex items-center"><i class="fa-solid fa-check text-primary mr-2 text-[10px]"></i> <?= $p['db_limit'] ?> Databases</li>
                            <li class="flex items-center"><i class="fa-solid fa-check text-primary mr-2 text-[10px]"></i> <?= $p['disk_quota_gb'] ?>GB NVMe Storage</li>
                            <li class="flex items-center"><i class="fa-solid fa-check text-primary mr-2 text-[10px]"></i> Connection Isolation</li>
                        </ul>
                        <a href="?view=signup&pkg=<?= $p['id'] ?>" class="btn-primary w-full mt-8">Choose Plan</a>
                    </div>
                    <?php endforeach; ?>
                </div>
            </section>
        </main>
    </div>

<?php elseif ($view === 'login' || $view === 'signup'): ?>
    <div class="flex min-h-screen items-center justify-center px-4 bg-slate-50/50">
        <div class="card-base w-full max-w-[400px] p-8 space-y-6 bg-white">
            <div class="flex flex-col space-y-2 text-center">
                <div class="mx-auto flex h-10 w-10 items-center justify-center rounded-full bg-slate-100 mb-2">
                    <i class="fa-solid fa-lock text-sm"></i>
                </div>
                <h1 class="text-2xl font-semibold tracking-tight"><?= $view === 'login' ? 'Welcome back' : 'Create an account' ?></h1>
                <p class="text-sm text-muted-foreground"><?= $view === 'login' ? 'Enter your credentials to access your cluster' : 'Choose a secure access key' ?></p>
            </div>
            <?php if($error) echo "<div class='text-xs font-medium text-red-500 bg-red-50 p-3 rounded-md text-center border border-red-100'>$error</div>"; ?>
            <form method="post" class="space-y-4">
                <input type="hidden" name="csrf" value="<?= csrf_token() ?>">
                <input type="hidden" name="action" value="<?= $view ?>">
                <?php if($view === 'signup'): ?><input type="hidden" name="package_id" value="<?= $_GET['pkg'] ?? 1 ?>"><?php endif; ?>
                <div class="space-y-2">
                    <label class="text-sm font-medium leading-none">Identity</label>
                    <input type="<?= $view === 'signup' ? 'email' : 'text' ?>" name="email" class="input-base" placeholder="<?= $view === 'signup' ? 'name@example.com' : 'admin' ?>" required autofocus>
                </div>
                <div class="space-y-2">
                    <label class="text-sm font-medium leading-none">Access Key</label>
                    <input type="password" name="password" class="input-base" placeholder="••••••••" required>
                </div>
                <button class="btn-primary w-full h-10"><?= $view === 'login' ? 'Sign In' : 'Register' ?></button>
            </form>
            <div class="text-center text-xs text-muted-foreground mt-4">
                <a href="?" class="hover:underline">← Back to home</a>
            </div>
        </div>
    </div>

<?php elseif ($view === 'client' && $client_id): ?>
    <div class="min-h-screen flex flex-col">
        <header class="border-b bg-white">
            <div class="container flex h-16 items-center max-w-7xl mx-auto px-4 justify-between">
                <div class="flex items-center space-x-2 font-bold tracking-tighter text-xl">
                    <i class="fa-solid fa-shield-halved"></i><span>Shield Hub</span>
                </div>
                <div class="flex items-center space-x-4">
                    <span class="text-xs text-muted-foreground font-medium mr-2">Client Portal</span>
                    <a href="?action=logout" class="text-xs font-semibold hover:text-red-500 transition-colors">Logout</a>
                </div>
            </div>
        </header>
        <main class="flex-1 container max-w-7xl mx-auto px-4 py-12 space-y-12">
            <div class="flex items-center justify-between">
                <div><h2 class="text-3xl font-bold tracking-tight">Infrastructure</h2><p class="text-sm text-muted-foreground">Manage your provisioned database instances</p></div>
                <form method="post"><input type="hidden" name="csrf" value="<?= csrf_token() ?>"><input type="hidden" name="action" value="provision">
                <button class="btn-primary rounded-lg h-10 px-6 shadow-none">New Instance</button></form>
            </div>
            
            <?php if (!empty($_SESSION['download'])): ?>
            <div class="card-base bg-slate-950 text-white p-6 flex items-center justify-between animate-in fade-in slide-in-from-top-4">
                <div class="space-y-1">
                    <h3 class="font-bold text-lg">Provisioning Complete</h3>
                    <p class="text-sm text-slate-400">Download your secure environment file now.</p>
                </div>
                <a href="?download=1" class="btn-primary bg-white text-black hover:bg-slate-200">Download .env</a>
            </div>
            <?php endif; ?>

            <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
                <?php 
                $dbs = $db->prepare("SELECT t.*, s.public_url, s.name as server_name FROM tenant_dbs t JOIN servers s ON t.server_id = s.id WHERE t.client_id = ?"); $dbs->execute([$client_id]);
                foreach($dbs->fetchAll(PDO::FETCH_ASSOC) as $row): ?>
                <div class="card-base flex flex-col p-6 space-y-6">
                    <div class="flex items-center justify-between">
                        <div class="flex h-10 w-10 items-center justify-center rounded-lg bg-slate-100 text-slate-900"><i class="fa-solid fa-database text-xs"></i></div>
                        <span class="text-[10px] font-bold uppercase tracking-widest bg-emerald-50 text-emerald-700 px-2 py-1 rounded border border-emerald-100">Healthy</span>
                    </div>
                    <div>
                        <h3 class="font-bold tracking-tight"><?= e($row['db_name']) ?></h3>
                        <p class="text-[10px] text-muted-foreground font-semibold mt-1">NODE: <?= e($row['server_name']) ?> &bull; <?= $row['last_size_mb'] ?> MB</p>
                    </div>
                    <div class="grid grid-cols-2 gap-2">
                        <a href="<?= rtrim($row['public_url'], '/') ?>/phpmyadmin" target="_blank" class="btn-primary bg-slate-50 text-slate-900 border hover:bg-slate-100 shadow-none h-8 text-[10px] font-bold tracking-widest uppercase">Admin</a>
                        <button onclick="document.getElementById('modal-ips-<?= $row['id'] ?>').classList.remove('hidden')" class="btn-primary bg-white text-slate-900 border hover:bg-slate-50 shadow-none h-8 text-[10px] font-bold tracking-widest uppercase">Firewall</button>
                    </div>
                </div>
                <!-- IP Modal -->
                <div id="modal-ips-<?= $row['id'] ?>" class="hidden fixed inset-0 bg-slate-950/40 backdrop-blur-sm flex items-center justify-center p-4 z-50">
                    <form method="post" class="card-base bg-white w-full max-w-[450px] p-8 space-y-6">
                        <input type="hidden" name="action" value="update_whitelist"><input type="hidden" name="csrf" value="<?= csrf_token() ?>"><input type="hidden" name="tdb_id" value="<?= $row['id'] ?>">
                        <div class="space-y-2">
                            <h2 class="text-xl font-bold tracking-tight uppercase">Node Guard</h2>
                            <p class="text-xs text-muted-foreground font-medium">Whitelist specific IP addresses for <strong><?= e($row['db_name']) ?></strong></p>
                        </div>
                        <textarea name="ips" class="input-base h-24 p-3 font-mono text-xs" placeholder="1.2.3.4, 5.6.7.8"><?= implode(',', json_decode($row['allowed_ips'], true) ?: ['%']) ?></textarea>
                        <div class="flex justify-end space-x-2 pt-2">
                            <button type="button" onclick="this.closest('[id^=modal-ips]').classList.add('hidden')" class="px-4 py-2 text-xs font-bold text-muted-foreground uppercase">Cancel</button>
                            <button class="btn-primary h-9 px-6 rounded-lg">Apply Rules</button>
                        </div>
                    </form></div>
                <?php endforeach; ?>
            </div>
        </main>
    </div>

<?php elseif ($view === 'admin' && $is_admin): ?>
    <div class="min-h-screen flex flex-col">
        <header class="border-b bg-slate-950 text-white">
            <div class="container flex h-16 items-center max-w-7xl mx-auto px-4 justify-between">
                <div class="flex items-center space-x-2 font-bold tracking-tighter text-xl text-white">
                    <i class="fa-solid fa-shield-halved text-indigo-400"></i><span>Shield Hub</span>
                </div>
                <div class="flex items-center space-x-4">
                    <span class="text-xs text-slate-400 font-bold tracking-widest uppercase mr-4">Master Control</span>
                    <a href="?action=logout" class="text-xs font-semibold hover:text-red-400">Exit Hub</a>
                </div>
            </div>
        </header>
        <main class="flex-1 container max-w-7xl mx-auto px-4 py-12 space-y-12">
            <div class="grid grid-cols-1 md:grid-cols-3 gap-6">
                <?php foreach([['Infrastructure Nodes','servers','fa-server'],['Active Accounts','clients','fa-user-group'],['Provisioned Assets','tenant_dbs','fa-database']] as $c): ?>
                <div class="card-base p-6 flex flex-col justify-between space-y-4">
                    <div class="flex items-center justify-between"><span class="text-[10px] font-black uppercase text-muted-foreground tracking-widest"><?= $c[0] ?></span><i class="fa-solid <?= $c[2] ?> text-muted-foreground/30 text-xs"></i></div>
                    <div class="text-3xl font-bold tracking-tighter"><?= $db->query("SELECT COUNT(*) FROM ".$c[1])->fetchColumn() ?></div>
                </div><?php endforeach; ?>
            </div>
            <div class="flex items-center justify-between border-t pt-12">
                <h2 class="text-2xl font-bold tracking-tight">Fleet Network</h2>
                <button onclick="document.getElementById('modal-add').classList.remove('hidden')" class="btn-primary h-9 rounded-lg px-6">Add Server Node</button>
            </div>
            <div class="card-base overflow-hidden">
                <table class="w-full text-sm">
                    <thead class="bg-slate-50 border-b">
                        <tr><th class="px-6 py-4 text-left font-bold text-muted-foreground uppercase text-[10px] tracking-widest">Identifier</th><th class="px-6 py-4 text-left font-bold text-muted-foreground uppercase text-[10px] tracking-widest">Internal Host</th><th class="px-6 py-4 text-center font-bold text-muted-foreground uppercase text-[10px] tracking-widest">Network Pulse</th></tr>
                    </thead>
                    <tbody class="divide-y">
                        <?php foreach($servers as $s): ?>
                        <tr class="hover:bg-slate-50/50">
                            <td class="px-6 py-4 font-semibold"><?= e($s['name']) ?></td>
                            <td class="px-6 py-4 font-mono text-xs text-muted-foreground"><?= e($s['host']) ?></td>
                            <td class="px-6 py-4 text-center">
                                <span class="inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-bold uppercase tracking-tighter <?= (time()-strtotime($s['last_seen']??'0') < 600) ? 'text-emerald-600 bg-emerald-50 border border-emerald-100' : 'text-red-600 bg-red-50 border border-red-100' ?>">
                                    <?= (time()-strtotime($s['last_seen']??'0') < 600) ? '● Healthy' : '● Unreachable' ?>
                                </span>
                            </td>
                        </tr>
                        <?php endforeach; ?>
                    </tbody>
                </table>
            </div>
        </main>
    </div>
<?php endif; ?>

<div id="modal-add" class="hidden fixed inset-0 bg-slate-950/40 backdrop-blur-sm flex items-center justify-center p-4 z-50">
    <form method="post" class="card-base bg-white w-full max-w-[450px] p-10 space-y-6">
        <input type="hidden" name="action" value="add_server"><input type="hidden" name="csrf" value="<?= csrf_token() ?>">
        <div class="text-center space-y-2">
            <h2 class="text-2xl font-bold tracking-tight uppercase">Link Infrastructure</h2>
            <p class="text-xs text-muted-foreground font-medium">Add a new remote database node to the fleet</p>
        </div>
        <div class="space-y-4">
            <input type="text" name="name" placeholder="NODE IDENTIFIER (E.G. EU-WEST-1)" class="input-base uppercase font-bold tracking-widest text-[10px]" required>
            <input type="text" name="host" placeholder="INTERNAL IP ADDRESS" class="input-base font-mono text-xs" required>
            <input type="password" name="agent_key" placeholder="AGENT SECURITY TOKEN" class="input-base font-mono text-xs" required>
            <input type="text" name="public_url" placeholder="PUBLIC HTTPS URL" class="input-base font-mono text-xs" required>
        </div>
        <div class="flex justify-end space-x-3 pt-4">
            <button type="button" onclick="this.closest('#modal-add').classList.add('hidden')" class="px-4 py-2 text-xs font-bold text-muted-foreground uppercase tracking-widest">Abort</button>
            <button class="btn-primary h-10 px-8 rounded-lg">Authorize Node</button>
        </div>
    </form></div>

<footer class="container max-w-7xl mx-auto px-4 py-24 text-center">
    <p class="text-[10px] font-bold text-muted-foreground uppercase tracking-[0.5em]">&copy; 2026 SHIELD CLOUD INFRASTRUCTURE &bull; V5.0 ENGINE</p>
</footer>
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
  
  # Cron for Watchdog
  (crontab -l 2>/dev/null || true; echo "*/10 * * * * curl -s http://localhost/${HUB_ALIAS}/index.php?action=watchdog >/dev/null") | crontab -
}

configure_firewall() {
  ufw allow OpenSSH; ufw allow 'Apache Full'; ufw --force enable
}

write_summary() {
  cat > "$SUMMARY_FILE" <<EOF
SHIELD HUB v5.0 DEPLOYED (Enterprise Professional UI)
Access: http://${SITE_FQDN}/${HUB_ALIAS}
Admin Pass: ${HUB_ADMIN_PASS}
SaaS Features: ENABLED
Security: ENTERPRISE HARDENED
EOF
  echo -e "\n${CLR_BOLD}${CLR_GREEN}Professional Hub Interface Active!${CLR_RESET}"
}

main() { clear; wizard; install_packages; deploy_hub; systemctl restart apache2; configure_firewall; write_summary; }
main "$@"
