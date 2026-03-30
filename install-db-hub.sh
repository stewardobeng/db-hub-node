#!/usr/bin/env bash
set -Eeuo pipefail

# DB-Shield SaaS HUB Installer
# Commercial Distributed Engine with Landing Page, Client Portal, and Smart Node Selection.

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
: "${PAYSTACK_SECRET:=}"

HUB_ADMIN_PASS="$(openssl rand -base64 12 | tr -d '\n')"
HUB_ADMIN_HASH=$(php -r "echo password_hash('$HUB_ADMIN_PASS', PASSWORD_DEFAULT);")
CSRF_SECRET="$(openssl rand -hex 32)"
APP_KEY="$(openssl rand -hex 32)"

wizard() {
    echo -e "${CLR_BOLD}${CLR_CYAN}"
    echo "===================================================="
    echo "       DB-Shield SaaS HUB Installation Wizard       "
    echo "===================================================="
    echo -e "${CLR_RESET}"
    read -p "$(echo -e "${CLR_BOLD}Enter Hub Domain (FQDN): ${CLR_RESET}")" input_fqdn
    SITE_FQDN=${input_fqdn:-$SITE_FQDN}
    read -p "$(echo -e "${CLR_BOLD}Enter Paystack Secret Key: ${CLR_RESET}")" input_paystack
    PAYSTACK_SECRET=${input_paystack:-$PAYSTACK_SECRET}
    read -p "$(echo -e "\n${CLR_BOLD}${CLR_YELLOW}Launch SaaS Hub Deployment? (y/n): ${CLR_RESET}")" confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then exit 0; fi
}

require_ubuntu() {
  if [[ ! -f /etc/os-release ]]; then exit 1; fi
  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" ]]; then exit 1; fi
}

install_packages() {
  msg_header "Installing Platform Dependencies"
  apt-get update >/dev/null 2>&1
  apt-get install -y apache2 php libapache2-mod-php php-cli php-mysql php-curl php-zip php-xml php-mbstring php-json php-sqlite3 certbot python3-certbot-apache unzip curl openssl ufw >/dev/null 2>&1
}

deploy_hub() {
  msg_header "Deploying Intelligent SaaS Engine"
  mkdir -p "$HUB_ROOT"
  
  cat >"$HUB_ROOT/index.php" <<'PHPHUB'
<?php
declare(strict_types=1);
session_start();

const ADMIN_USER = '__HUB_USER__';
const ADMIN_HASH = '__HUB_HASH__';
const APP_SECRET = '__CSRF_SECRET__';
const PAYSTACK_SECRET = '__PAYSTACK_SECRET__';
const HUB_DB = 'hub_platform.sqlite';

function e(string $v): string { return htmlspecialchars($v, ENT_QUOTES, 'UTF-8'); }
function csrf_token(): string {
    if (empty($_SESSION['csrf'])) $_SESSION['csrf'] = hash_hmac('sha256', session_id(), APP_SECRET);
    return $_SESSION['csrf'];
}
function require_csrf(): void {
    if (!hash_equals(csrf_token(), $_POST['csrf'] ?? '')) throw new RuntimeException('Invalid CSRF token.');
}

function hub_db(): PDO {
    static $pdo = null; if ($pdo) return $pdo;
    $pdo = new PDO('sqlite:' . HUB_DB);
    $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    // Core Tables
    $pdo->exec("CREATE TABLE IF NOT EXISTS servers (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, host TEXT, agent_key TEXT, public_url TEXT, s3_endpoint TEXT, s3_bucket TEXT, s3_access_key TEXT, s3_secret_key TEXT)");
    $pdo->exec("CREATE TABLE IF NOT EXISTS packages (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, price REAL, db_limit INTEGER, duration_days INTEGER, features TEXT)");
    $pdo->exec("CREATE TABLE IF NOT EXISTS clients (id INTEGER PRIMARY KEY AUTOINCREMENT, email TEXT UNIQUE, password_hash TEXT, package_id INTEGER, expires_at DATETIME, status TEXT DEFAULT 'active')");
    $pdo->exec("CREATE TABLE IF NOT EXISTS tenant_dbs (id INTEGER PRIMARY KEY AUTOINCREMENT, client_id INTEGER, server_id INTEGER, db_name TEXT, db_user TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)");
    return $pdo;
}

function call_agent(array $server, array $params = []): array {
    $queryString = http_build_query(array_merge(['key' => $server['agent_key']], $params));
    $ch = curl_init(rtrim($server['public_url'], '/') . "/agent-api/agent.php?" . $queryString);
    curl_setopt($ch, CURLOPT_RETURNTRANSFER, true); curl_setopt($ch, CURLOPT_TIMEOUT, 10);
    if (!empty($params['post_data'])) {
        curl_setopt($ch, CURLOPT_POST, true); curl_setopt($ch, CURLOPT_POSTFIELDS, http_build_query($params['post_data']));
    }
    $res = curl_exec($ch); return json_decode((string)$res, true) ?? ['error' => 'Node Offline'];
}

// User Identification
$is_admin = isset($_SESSION['role']) && $_SESSION['role'] === 'admin';
$client_id = $_SESSION['client_id'] ?? null;
$is_client = (bool)$client_id;

// Basic Routing
$view = $_GET['view'] ?? ($is_admin ? 'admin_dash' : ($is_client ? 'client_dash' : 'landing'));

// Actions
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    require_csrf();
    $action = $_POST['action'] ?? '';

    if ($action === 'login') {
        $u = $_POST['email']; $p = $_POST['password'];
        if ($u === ADMIN_USER && password_verify($p, ADMIN_HASH)) {
            $_SESSION['role'] = 'admin'; header('Location: ?view=admin_dash'); exit;
        }
        $client = hub_db()->prepare("SELECT * FROM clients WHERE email = ?");
        $client->execute([$u]); $user = $client->fetch(PDO::FETCH_ASSOC);
        if ($user && password_verify($p, $user['password_hash'])) {
            $_SESSION['client_id'] = $user['id']; header('Location: ?view=client_dash'); exit;
        }
        $login_err = "Invalid credentials.";
    }

    if ($action === 'add_server' && $is_admin) {
        hub_db()->prepare("INSERT INTO servers (name, host, agent_key, public_url) VALUES (?,?,?,?)")->execute([$_POST['name'],$_POST['host'],$_POST['agent_key'],$_POST['public_url']]);
        header('Location: ?view=admin_dash'); exit;
    }

    if ($action === 'create_tenant_db' && $is_client) {
        $db = hub_db();
        $client = $db->prepare("SELECT c.*, p.db_limit FROM clients c JOIN packages p ON c.package_id = p.id WHERE c.id = ?");
        $client->execute([$client_id]); $me = $client->fetch(PDO::FETCH_ASSOC);
        
        $count = $db->prepare("SELECT COUNT(*) FROM tenant_dbs WHERE client_id = ?");
        $count->execute([$client_id]);
        if ($count->fetchColumn() >= $me['db_limit']) { $_SESSION['error'] = "Plan limit reached."; }
        else {
            // Auto-Select Best Server (Lowest CPU)
            $servers = $db->query("SELECT * FROM servers")->fetchAll(PDO::FETCH_ASSOC);
            $best_server = null; $min_cpu = 101;
            foreach($servers as $s) {
                $stats = call_agent($s, ['action' => 'stats']);
                if (!isset($stats['error']) && $stats['cpu'] < $min_cpu) { $min_cpu = $stats['cpu']; $best_server = $s; }
            }
            if (!$best_server) { $_SESSION['error'] = "No nodes available."; }
            else {
                $prefix = bin2hex(random_bytes(4));
                $nodeRes = call_agent($best_server, ['action' => 'create', 'post_data' => ['db_prefix' => $prefix, 'db_suffix' => 'db', 'remote_host' => '%']]);
                if (isset($nodeRes['error'])) { $_SESSION['error'] = $nodeRes['error']; }
                else {
                    $db->prepare("INSERT INTO tenant_dbs (client_id, server_id, db_name, db_user) VALUES (?,?,?,?)")->execute([$client_id, $best_server['id'], $prefix.'_db', $prefix.'_user']);
                    $_SESSION['download'] = $nodeRes['download'];
                    $_SESSION['message'] = "Database provisioned successfully.";
                }
            }
        }
        header('Location: ?view=client_dash'); exit;
    }
}

if (isset($_GET['action']) && $_GET['action'] === 'logout') { session_destroy(); header('Location: ?view=landing'); exit; }

// --- UI Logic ---
$db = hub_db();
$packages = $db->query("SELECT * FROM packages")->fetchAll(PDO::FETCH_ASSOC);

?><!doctype html><html><head><meta charset="utf-8"><title>DB-Shield Cloud</title>
<script src="https://cdn.tailwindcss.com?plugins=forms"></script>
<link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css" rel="stylesheet"/>
<style> .glass { background: rgba(255,255,255,0.03); backdrop-filter: blur(10px); } </style>
</head><body class="bg-slate-950 text-slate-300 font-sans">

<?php if ($view === 'landing'): ?>
    <!-- Professional Landing Page -->
    <nav class="flex justify-between px-12 py-8 items-center max-w-7xl mx-auto">
        <div class="text-2xl font-black text-white tracking-tighter italic"><i class="fa-solid fa-shield-halved mr-2 text-indigo-500"></i>SHIELD</div>
        <div class="space-x-8 text-xs font-black uppercase tracking-widest">
            <a href="#pricing" class="hover:text-indigo-400 transition-colors">Pricing</a>
            <a href="?view=login" class="bg-white text-black px-8 py-3 rounded-full hover:bg-indigo-500 hover:text-white transition-all">Client Portal</a>
        </div>
    </nav>

    <main class="max-w-7xl mx-auto px-8 pt-20 pb-32 text-center">
        <h1 class="text-7xl font-black text-white tracking-tighter mb-6 leading-none">Instant Scalable<br><span class="text-indigo-500">Databases.</span></h1>
        <p class="text-slate-500 text-xl max-w-2xl mx-auto mb-16 leading-relaxed font-medium">Provision high-performance MariaDB instances in seconds. Managed nodes, encrypted cloud backups, and smart global routing.</p>
        
        <div id="pricing" class="grid grid-cols-1 md:grid-cols-3 gap-8 text-left">
            <?php foreach($packages as $p): ?>
            <div class="bg-slate-900 border border-slate-800 p-10 rounded-[2.5rem] hover:border-indigo-500/50 transition-all group">
                <h3 class="text-indigo-400 font-black uppercase tracking-widest text-[10px] mb-4"><?= e($p['name']) ?></h3>
                <div class="text-5xl font-black text-white mb-8 tracking-tighter">$<?= round($p['price']) ?><span class="text-lg text-slate-600 font-normal">/mo</span></div>
                <ul class="space-y-4 mb-12 text-sm font-medium text-slate-400">
                    <li><i class="fa-solid fa-check text-indigo-500 mr-2"></i> <?= $p['db_limit'] ?> Database Instances</li>
                    <li><i class="fa-solid fa-check text-indigo-500 mr-2"></i> Daily Encrypted Backups</li>
                    <li><i class="fa-solid fa-check text-indigo-500 mr-2"></i> Global Smart Link access</li>
                </ul>
                <a href="?view=signup&pkg=<?= $p['id'] ?>" class="block text-center bg-slate-800 py-4 rounded-2xl font-black text-xs uppercase tracking-widest group-hover:bg-indigo-600 transition-all">Get Started</a>
            </div>
            <?php endforeach; ?>
        </div>
    </main>

<?php elseif ($view === 'login'): ?>
    <!-- Styled Login Page -->
    <div class="flex items-center justify-center min-h-screen">
        <form method="post" class="bg-slate-900 p-12 rounded-[2rem] border border-slate-800 w-full max-w-md shadow-2xl">
            <input type="hidden" name="action" value="login"><input type="hidden" name="csrf" value="<?= csrf_token() ?>">
            <h2 class="text-3xl font-black text-white mb-8 tracking-tighter text-center">Identity Check</h2>
            <?php if(isset($login_err)) echo "<p class='text-red-400 text-xs font-bold mb-6 text-center uppercase tracking-widest'>$login_err</p>"; ?>
            <div class="space-y-6">
                <div><label class="text-[10px] font-black text-slate-500 uppercase tracking-widest ml-1 mb-2 block">Email Address</label>
                <input type="email" name="email" class="w-full bg-slate-950 border-slate-800 rounded-xl p-4 text-white focus:ring-indigo-500" required></div>
                <div><label class="text-[10px] font-black text-slate-500 uppercase tracking-widest ml-1 mb-2 block">Password</label>
                <input type="password" name="password" class="w-full bg-slate-950 border-slate-800 rounded-xl p-4 text-white focus:ring-indigo-500" required></div>
                <button class="w-full bg-indigo-600 py-5 rounded-2xl text-white font-black uppercase tracking-widest text-xs shadow-xl shadow-indigo-500/20 hover:bg-indigo-500 transition-all mt-4">Authenticate</button>
            </div>
        </form>
    </div>

<?php elseif ($view === 'client_dash' && $is_client): ?>
    <!-- Secure Client Dashboard -->
    <header class="flex justify-between px-12 py-6 items-center border-b border-slate-900 bg-slate-900/50 sticky top-0 z-50 backdrop-blur-xl">
        <div class="text-xl font-black text-white italic tracking-tighter">CLIENT<span class="text-indigo-500">PORTAL</span></div>
        <div class="flex items-center space-x-8 font-black text-[10px] uppercase tracking-widest">
            <a href="?action=logout" class="text-slate-500 hover:text-red-400 transition-colors">Terminate Session</a>
        </div>
    </header>

    <main class="max-w-7xl mx-auto px-12 py-12 space-y-12">
        <section class="flex items-center justify-between">
            <div><h2 class="text-4xl font-black text-white tracking-tighter">Active Infrastructure</h2>
            <p class="text-slate-500 font-medium mt-1">Manage your cloud database instances.</p></div>
            <form method="post"><input type="hidden" name="csrf" value="<?= csrf_token() ?>"><input type="hidden" name="action" value="create_tenant_db">
            <button class="bg-indigo-600 text-white px-10 py-4 rounded-2xl font-black text-xs uppercase tracking-widest shadow-2xl shadow-indigo-500/30 hover:scale-105 transition-all">Provision Instance</button></form>
        </section>

        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-8">
            <?php 
            $my_dbs = $db->prepare("SELECT d.*, s.public_url, s.name as server_name FROM tenant_dbs d JOIN servers s ON d.server_id = s.id WHERE d.client_id = ?");
            $my_dbs->execute([$client_id]);
            foreach($my_dbs->fetchAll(PDO::FETCH_ASSOC) as $tdb): ?>
            <div class="bg-slate-900 p-8 rounded-[2rem] border border-slate-800 shadow-xl group hover:border-indigo-500/30 transition-all">
                <div class="flex items-center justify-between mb-6">
                    <div class="bg-slate-800 p-3 rounded-2xl"><i class="fa-solid fa-database text-indigo-500 text-xl"></i></div>
                    <span class="text-[10px] font-black bg-emerald-500/10 text-emerald-500 px-3 py-1 rounded-full uppercase tracking-widest">Active</span>
                </div>
                <h3 class="text-xl font-black text-white mb-1 tracking-tight"><?= e($tdb['db_name']) ?></h3>
                <p class="text-slate-500 text-xs font-medium mb-8">Hosted on <span class="text-indigo-400"><?= e($tdb['server_name']) ?></span></p>
                <div class="grid grid-cols-2 gap-4">
                    <a href="<?= rtrim($tdb['public_url'], '/') ?>/phpmyadmin" target="_blank" class="bg-slate-800 text-center py-3 rounded-xl text-[10px] font-black uppercase tracking-widest hover:bg-slate-700 transition-colors">Admin Panel</a>
                    <button class="bg-indigo-600/10 text-indigo-400 text-center py-3 rounded-xl text-[10px] font-black uppercase tracking-widest border border-indigo-500/20 hover:bg-indigo-600 hover:text-white transition-all">Credentials</button>
                </div>
            </div>
            <?php endforeach; ?>
        </div>
    </main>

<?php elseif ($view === 'admin_dash' && $is_admin): ?>
    <!-- Full Admin Hub (Existing features kept) -->
    <div class="p-12">
        <h1 class="text-4xl font-black text-white mb-12 tracking-tighter uppercase"><i class="fa-solid fa-gears mr-4 text-indigo-500"></i>Master Control</h1>
        <div class="grid grid-cols-1 md:grid-cols-4 gap-8 mb-12">
            <div class="bg-slate-900 p-8 rounded-[2rem] border border-slate-800">
                <span class="text-[10px] font-black text-slate-500 uppercase tracking-widest block mb-4">Total Fleet</span>
                <div class="text-4xl font-black text-white"><?= $db->query("SELECT COUNT(*) FROM servers")->fetchColumn() ?> <span class="text-sm font-medium text-slate-600">Nodes</span></div>
            </div>
            <div class="bg-slate-900 p-8 rounded-[2rem] border border-slate-800">
                <span class="text-[10px] font-black text-slate-500 uppercase tracking-widest block mb-4">Active Clients</span>
                <div class="text-4xl font-black text-white"><?= $db->query("SELECT COUNT(*) FROM clients")->fetchColumn() ?> <span class="text-sm font-medium text-slate-600">Accounts</span></div>
            </div>
        </div>
        <button onclick="document.getElementById('modal-add').classList.remove('hidden')" class="bg-indigo-600 text-white px-12 py-4 rounded-2xl font-black uppercase tracking-widest text-xs">Link Remote Node</button>
    </div>
<?php endif; ?>

<footer class="text-center py-20 text-[10px] font-black text-slate-700 uppercase tracking-[0.5em]">&copy; SHIELD PLATFORM &bull; DISTRIBUTED ENGINE 3.0</footer>

<div id="modal-add" class="hidden fixed inset-0 bg-slate-950/90 backdrop-blur-xl flex items-center justify-center p-8 z-50">
    <form method="post" class="bg-slate-900 p-12 rounded-[3rem] border border-slate-800 w-full max-w-lg">
        <input type="hidden" name="action" value="add_server"><input type="hidden" name="csrf" value="<?= csrf_token() ?>">
        <h2 class="text-2xl font-black text-white mb-8 tracking-tighter">Initialize Node</h2>
        <div class="space-y-6">
            <input type="text" name="name" placeholder="Label (e.g. Production-1)" class="w-full bg-slate-950 border-slate-800 rounded-xl p-4 text-white" required>
            <input type="text" name="host" placeholder="Internal IP" class="w-full bg-slate-950 border-slate-800 rounded-xl p-4 text-white" required>
            <input type="password" name="agent_key" placeholder="Agent API Key" class="w-full bg-slate-950 border-slate-800 rounded-xl p-4 text-white" required>
            <input type="text" name="public_url" placeholder="Public URL (HTTPS)" class="w-full bg-slate-950 border-slate-800 rounded-xl p-4 text-white" required>
            <div class="flex justify-end space-x-6 pt-4">
                <button type="button" onclick="this.closest('#modal-add').classList.add('hidden')" class="text-slate-500 font-black uppercase text-[10px] tracking-widest">Abort</button>
                <button class="bg-indigo-600 text-white px-10 py-4 rounded-2xl font-black uppercase text-[10px] tracking-widest">Commit Node</button>
            </div>
        </div>
    </form>
</div>

</body></html>
PHPHUB

  sed -i "s|__HUB_USER__|${HUB_ADMIN_USER}|g" "$HUB_ROOT/index.php"
  sed -i "s|__HUB_HASH__|${HUB_ADMIN_HASH}|g" "$HUB_ROOT/index.php"
  sed -i "s|__CSRF_SECRET__|${CSRF_SECRET}|g" "$HUB_ROOT/index.php"
  sed -i "s|__PAYSTACK_SECRET__|${PAYSTACK_SECRET}|g" "$HUB_ROOT/index.php"

  chown -R www-data:www-data "$HUB_ROOT"
  chmod 750 "$HUB_ROOT"
  touch "$HUB_ROOT/hub_platform.sqlite"
  chown www-data:www-data "$HUB_ROOT/hub_platform.sqlite"
  chmod 660 "$HUB_ROOT/hub_platform.sqlite"

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
  msg_header "Network Security: UFW"
  ufw allow OpenSSH; ufw allow 'Apache Full'; ufw --force enable
}

write_summary() {
  cat > "$SUMMARY_FILE" <<EOF
DB-Shield SaaS Hub Initialized
Access: http://${SITE_FQDN}/${HUB_ALIAS}
Admin User: ${HUB_ADMIN_USER}
Admin Pass: ${HUB_ADMIN_PASS}
EOF
  echo -e "\n${CLR_BOLD}${CLR_GREEN}Platform deployed successfully!${CLR_RESET}"
}

main() {
  clear; require_ubuntu; wizard; install_packages; deploy_hub; systemctl restart apache2; configure_firewall; write_summary
}

main "$@"
