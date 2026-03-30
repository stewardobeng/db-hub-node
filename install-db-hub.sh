#!/usr/bin/env bash
set -Eeuo pipefail

# DB Platform HUB Installer (Central Management Console)
# Redesigned for API-based Remote Management and Smart Links.

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

HUB_ADMIN_PASS="$(openssl rand -base64 12 | tr -d '\n')"
HUB_ADMIN_HASH=$(php -r "echo password_hash('$HUB_ADMIN_PASS', PASSWORD_DEFAULT);")
CSRF_SECRET="$(openssl rand -hex 32)"
APP_KEY="$(openssl rand -hex 32)"

wizard() {
    echo -e "${CLR_BOLD}${CLR_CYAN}"
    echo "===================================================="
    echo "       DB Platform HUB Installation Wizard         "
    echo "===================================================="
    echo -e "${CLR_RESET}"
    read -p "$(echo -e "${CLR_BOLD}Enter Hub Domain (FQDN) [${SITE_FQDN}]: ${CLR_RESET}")" input_fqdn
    SITE_FQDN=${input_fqdn:-$SITE_FQDN}
    read -p "$(echo -e "${CLR_BOLD}Enter SSL Email (optional): ${CLR_RESET}")" input_email
    LETSENCRYPT_EMAIL=${input_email:-$LETSENCRYPT_EMAIL}
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
        name TEXT,
        host TEXT,
        agent_key TEXT,
        public_url TEXT
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

// Login/Logout
if (isset($_POST['action']) && $_POST['action'] === 'login') {
    if (($_POST['username'] ?? '') === APP_USER && password_verify($_POST['password'] ?? '', APP_HASH)) {
        $_SESSION['logged_in'] = true;
        header('Location: ' . $_SERVER['PHP_SELF']); exit;
    }
    $error = "Invalid credentials.";
}
if (isset($_GET['action']) && $_GET['action'] === 'logout') { session_destroy(); header('Location: ' . $_SERVER['PHP_SELF']); exit; }

if (!is_logged_in()) {
    ?><!doctype html><html><head><title>Login - DB Hub</title><script src="https://cdn.tailwindcss.com?plugins=forms"></script>
    <link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css" rel="stylesheet"/></head>
    <body class="bg-gray-100 flex items-center justify-center min-h-screen">
    <div class="bg-white p-8 rounded-xl shadow-lg border border-gray-200 w-full max-w-md">
        <div class="text-center mb-8"><div class="bg-indigo-600 text-white w-16 h-16 rounded-full flex items-center justify-center mx-auto mb-4"><i class="fa-solid fa-server text-2xl"></i></div>
        <h1 class="text-2xl font-bold">DB Management Hub</h1></div>
        <?php if (isset($error)) echo "<div class='bg-red-50 text-red-700 p-3 rounded mb-4 text-center text-sm'>$error</div>"; ?>
        <form method="post" class="space-y-4">
            <input type="hidden" name="action" value="login">
            <input type="text" name="username" placeholder="Username" class="w-full rounded-md border-gray-300" required autofocus>
            <input type="password" name="password" placeholder="Password" class="w-full rounded-md border-gray-300" required>
            <button class="w-full bg-indigo-600 text-white font-bold py-2 rounded shadow">Sign In</button>
        </form></div></body></html><?php exit;
}

$db = hub_db();
$message = $_SESSION['message'] ?? ''; unset($_SESSION['message']);
$error = $_SESSION['error'] ?? ''; unset($_SESSION['error']);

// Handle Hub Actions
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    require_csrf();
    $action = $_POST['action'] ?? '';
    
    if ($action === 'add_server') {
        $stmt = $db->prepare("INSERT INTO servers (name, host, agent_key, public_url) VALUES (?, ?, ?, ?)");
        $stmt->execute([$_POST['name'], $_POST['host'], $_POST['agent_key'], $_POST['public_url']]);
        $_SESSION['message'] = "Server added.";
        header('Location: ' . $_SERVER['PHP_SELF']); exit;
    }
    
    if ($action === 'select_server') {
        $_SESSION['active_server_id'] = (int)$_POST['server_id'];
        header('Location: ' . $_SERVER['PHP_SELF']); exit;
    }

    if ($action === 'delete_server') {
        $stmt = $db->prepare("DELETE FROM servers WHERE id = ?");
        $stmt->execute([$_POST['id']]);
        unset($_SESSION['active_server_id']);
        header('Location: ' . $_SERVER['PHP_SELF']); exit;
    }
}

$servers = $db->query("SELECT * FROM servers")->fetchAll(PDO::FETCH_ASSOC);
$active_id = $_SESSION['active_server_id'] ?? ($servers[0]['id'] ?? null);
$active_server = null;
foreach($servers as $s) { if($s['id'] == $active_id) $active_server = $s; }

// Remote Node Actions
if ($active_server && isset($_POST['node_action'])) {
    require_csrf();
    $nodeRes = call_agent($active_server, ['action' => $_POST['node_action'], 'post_data' => $_POST]);
    if (isset($nodeRes['error'])) { $_SESSION['error'] = $nodeRes['error']; }
    else {
        $_SESSION['message'] = $nodeRes['message'] ?? 'Action completed.';
        if (isset($nodeRes['download'])) $_SESSION['download'] = $nodeRes['download'];
    }
    header('Location: ' . $_SERVER['PHP_SELF']); exit;
}

if (isset($_GET['download']) && !empty($_SESSION['download'])) {
    header('Content-Type: text/plain');
    header('Content-Disposition: attachment; filename="' . $_SESSION['download']['filename'] . '"');
    echo $_SESSION['download']['content']; unset($_SESSION['download']); exit;
}

$stats = $active_server ? call_agent($active_server, ['action' => 'stats']) : null;
$tenants = ($active_server && !isset($stats['error'])) ? call_agent($active_server, ['action' => 'list_tenants']) : [];

?><!doctype html><html><head><meta charset="utf-8"><title>DB Hub Dashboard</title>
<script src="https://cdn.tailwindcss.com?plugins=forms"></script>
<link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css" rel="stylesheet"/>
<style> .brand-nav { background: #111827; } .brand-bg { background: #f3f4f6; } </style>
</head><body class="brand-bg font-sans antialiased text-gray-800">

<header class="brand-nav text-white flex items-center justify-between px-6 py-3 shadow-lg">
    <div class="flex items-center space-x-4"><h1 class="text-lg font-bold tracking-tight"><i class="fa-solid fa-gauge-high mr-2"></i>Management Hub</h1></div>
    <div class="flex items-center space-x-6">
        <form method="post" class="flex items-center bg-gray-800 rounded px-3 py-1 border border-gray-700">
            <input type="hidden" name="csrf" value="<?= csrf_token() ?>"><input type="hidden" name="action" value="select_server">
            <select name="server_id" onchange="this.form.submit()" class="bg-transparent border-none text-sm text-white focus:ring-0 cursor-pointer">
                <option value="" disabled <?= !$active_id ? 'selected' : '' ?>>Select Server...</option>
                <?php foreach($servers as $s): ?>
                    <option value="<?= $s['id'] ?>" <?= $s['id'] == $active_id ? 'selected' : '' ?> class="text-black"><?= e($s['name']) ?> (<?= e($s['host']) ?>)</option>
                <?php endforeach; ?>
            </select>
        </form>
        <button onclick="document.getElementById('modal-add').classList.remove('hidden')" class="text-gray-300 hover:text-white" title="Add Server"><i class="fa-solid fa-plus-circle text-xl"></i></button>
        <a href="?action=logout" class="text-gray-300 hover:text-white"><i class="fa-solid fa-right-from-bracket text-xl"></i></a>
    </div>
</header>

<main class="max-w-7xl mx-auto px-4 py-6 space-y-6">
    <?php if ($message): ?><div class="bg-green-100 border border-green-200 text-green-800 px-4 py-3 rounded-md shadow-sm flex items-center"><i class="fa-solid fa-check-circle mr-2"></i><?= e($message) ?></div><?php endif; ?>
    <?php if ($error): ?><div class="bg-red-100 border border-red-200 text-red-800 px-4 py-3 rounded-md shadow-sm flex items-center"><i class="fa-solid fa-circle-exclamation mr-2"></i><?= e($error) ?></div><?php endif; ?>
    
    <?php if (!empty($_SESSION['download'])): ?>
    <div class="bg-amber-50 border border-amber-200 p-4 rounded-lg flex items-center justify-between shadow-sm">
        <div><p class="font-bold text-amber-800">New Credentials Ready!</p><p class="text-sm text-amber-700">Download the .env file for the new database password.</p></div>
        <a href="?download=1" class="bg-amber-600 text-white px-6 py-2 rounded-md font-bold hover:bg-amber-700 transition-colors"><i class="fa-solid fa-download mr-2"></i>Download .env</a>
    </div>
    <?php endif; ?>

    <?php if (!$active_server): ?>
        <div class="bg-white p-12 rounded-xl text-center border-2 border-dashed border-gray-300 shadow-sm">
            <i class="fa-solid fa-cloud-upload text-5xl text-gray-200 mb-4"></i><h2 class="text-xl font-bold text-gray-500">No Servers Connected</h2>
            <p class="text-gray-400 mb-8">Link your database nodes to start remote management.</p>
            <button onclick="document.getElementById('modal-add').classList.remove('hidden')" class="bg-indigo-600 text-white px-8 py-3 rounded-lg font-bold shadow-lg">Connect First Server</button>
        </div>
    <?php else: ?>
        <!-- Server Analytics -->
        <section class="grid grid-cols-1 md:grid-cols-4 gap-4">
            <div class="bg-white p-5 rounded-xl border border-gray-200 shadow-sm">
                <span class="text-[10px] font-bold text-gray-400 uppercase tracking-widest block mb-1">Server Resources</span>
                <div class="text-2xl font-black text-gray-900"><?= $stats['cpu'] ?? '?' ?><span class="text-sm font-normal text-gray-400">% CPU</span></div>
                <div class="w-full bg-gray-100 h-1.5 rounded-full mt-3 overflow-hidden"><div class="bg-indigo-600 h-full" style="width: <?= $stats['cpu'] ?? 0 ?>%"></div></div>
            </div>
            <div class="bg-white p-5 rounded-xl border border-gray-200 shadow-sm">
                <span class="text-[10px] font-bold text-gray-400 uppercase tracking-widest block mb-1">Memory Usage</span>
                <div class="text-2xl font-black text-gray-900"><?= $stats['ram'] ?? '?' ?><span class="text-sm font-normal text-gray-400">%</span></div>
                <div class="text-[10px] text-gray-400 mt-1 truncate"><?= $stats['ram_text'] ?? 'Connecting...' ?></div>
            </div>
            <div class="bg-white p-5 rounded-xl border border-gray-200 shadow-sm">
                <span class="text-[10px] font-bold text-gray-400 uppercase tracking-widest block mb-1">Disk Status</span>
                <div class="text-2xl font-black text-gray-900"><?= $stats['disk'] ?? '?' ?><span class="text-sm font-normal text-gray-400">% Used</span></div>
                <div class="text-[10px] text-gray-400 mt-1 truncate"><?= $stats['disk_text'] ?? '' ?></div>
            </div>
            <div class="bg-white p-5 rounded-xl border border-gray-200 shadow-sm">
                <span class="text-[10px] font-bold text-gray-400 uppercase tracking-widest block mb-1">Node Connectivity</span>
                <div class="text-2xl font-black text-green-600 flex items-center">ONLINE <span class="relative flex h-2 w-2 ml-2"><span class="animate-ping absolute h-full w-full rounded-full bg-green-400 opacity-75"></span><span class="relative rounded-full h-2 w-2 bg-green-500"></span></span></div>
                <div class="text-[10px] text-gray-400 mt-1"><?= e($active_server['public_url']) ?></div>
            </div>
        </section>

        <!-- Remote Management Forms -->
        <div class="grid grid-cols-1 md:grid-cols-3 gap-6">
            <section class="bg-white p-6 rounded-xl border border-gray-200 shadow-sm">
                <h2 class="font-bold text-gray-900 mb-4 flex items-center"><i class="fa-solid fa-plus-circle mr-2 text-indigo-600"></i>Create Database</h2>
                <form method="post" class="space-y-3">
                    <input type="hidden" name="csrf" value="<?= csrf_token() ?>"><input type="hidden" name="node_action" value="create">
                    <input type="text" name="db_prefix" placeholder="Prefix (e.g. clienta)" class="w-full rounded-md border-gray-300 text-sm" required>
                    <input type="text" name="db_suffix" value="db" class="w-full rounded-md border-gray-300 text-sm" required>
                    <input type="text" name="remote_host" value="localhost" class="w-full rounded-md border-gray-300 text-sm" required>
                    <button class="w-full bg-indigo-600 text-white font-bold py-2 rounded hover:bg-indigo-700 transition-colors text-sm shadow-sm">Provision Tenant</button>
                </form>
            </section>
            <section class="bg-white p-6 rounded-xl border border-gray-200 shadow-sm">
                <h2 class="font-bold text-gray-900 mb-4 flex items-center"><i class="fa-solid fa-key mr-2 text-indigo-600"></i>Rotate Security</h2>
                <form method="post" class="space-y-3">
                    <input type="hidden" name="csrf" value="<?= csrf_token() ?>"><input type="hidden" name="node_action" value="rotate">
                    <input type="text" name="db_user" placeholder="User Name (e.g. clienta_user)" class="w-full rounded-md border-gray-300 text-sm" required>
                    <input type="text" name="db_host" value="localhost" class="w-full rounded-md border-gray-300 text-sm" required>
                    <button class="w-full bg-gray-800 text-white font-bold py-2 rounded hover:bg-black transition-colors text-sm shadow-sm">Reset Password</button>
                </form>
            </section>
            <section class="bg-white p-6 rounded-xl border border-gray-200 shadow-sm">
                <h2 class="font-bold text-gray-900 mb-4 flex items-center"><i class="fa-solid fa-trash-can mr-2 text-red-600"></i>Delete Assets</h2>
                <form method="post" class="space-y-3" onsubmit="return confirm('Destroy database and user?');">
                    <input type="hidden" name="csrf" value="<?= csrf_token() ?>"><input type="hidden" name="node_action" value="delete">
                    <input type="text" name="db_name" placeholder="Database Name" class="w-full rounded-md border-gray-300 text-sm" required>
                    <input type="text" name="db_user" placeholder="User Name" class="w-full rounded-md border-gray-300 text-sm" required>
                    <input type="text" name="db_host" value="localhost" class="w-full rounded-md border-gray-300 text-sm" required>
                    <button class="w-full bg-red-50 text-red-600 font-bold py-2 rounded border border-red-200 hover:bg-red-100 transition-colors text-sm">Purge Data</button>
                </form>
            </section>
        </div>

        <!-- Smart Links Table -->
        <section class="bg-white rounded-xl border border-gray-200 shadow-sm overflow-hidden">
            <div class="px-6 py-4 border-b border-gray-100 bg-gray-50 flex items-center justify-between">
                <h2 class="font-bold text-gray-900 text-lg">Known Tenants on <?= e($active_server['name']) ?></h2>
                <span class="bg-indigo-100 text-indigo-700 px-3 py-1 rounded-full text-xs font-bold"><?= count($tenants) ?> Databases</span>
            </div>
            <div class="overflow-x-auto">
                <table class="min-w-full divide-y divide-gray-200">
                    <thead class="bg-gray-50">
                        <tr>
                            <th class="px-6 py-3 text-left text-xs font-bold text-gray-500 uppercase">Database</th>
                            <th class="px-6 py-3 text-left text-xs font-bold text-gray-500 uppercase">Primary User</th>
                            <th class="px-6 py-3 text-left text-xs font-bold text-gray-500 uppercase">Active Hosts</th>
                            <th class="px-6 py-3 text-center text-xs font-bold text-gray-500 uppercase">Smart Access</th>
                        </tr>
                    </thead>
                    <tbody class="divide-y divide-gray-100">
                        <?php foreach($tenants as $t): if(isset($t['error'])) continue; ?>
                        <tr class="hover:bg-gray-50 transition-colors">
                            <td class="px-6 py-4 whitespace-nowrap font-semibold text-gray-900"><?= e($t['db']) ?></td>
                            <td class="px-6 py-4 whitespace-nowrap text-sm"><code><?= e($t['user']) ?></code></td>
                            <td class="px-6 py-4 whitespace-nowrap space-x-1">
                                <?php foreach($t['users'] as $u): ?>
                                    <span class="bg-gray-100 text-gray-600 px-2 py-0.5 rounded text-[10px] border border-gray-200"><?= e($u['Host']) ?></span>
                                <?php endforeach; ?>
                            </td>
                            <td class="px-6 py-4 whitespace-nowrap text-center">
                                <a href="<?= rtrim($active_server['public_url'], '/') ?>/phpmyadmin" target="_blank" class="bg-blue-50 text-blue-600 px-4 py-1.5 rounded-md text-xs font-bold border border-blue-100 hover:bg-blue-600 hover:text-white transition-all">
                                    <i class="fa-solid fa-external-link mr-1"></i> Login to Node PMA
                                </a>
                            </td>
                        </tr>
                        <?php endforeach; ?>
                        <?php if (empty($tenants)): ?><tr><td colspan="4" class="px-6 py-12 text-center text-gray-400 italic">No remote tenants found.</td></tr><?php endif; ?>
                    </tbody>
                </table>
            </div>
        </section>
    <?php endif; ?>

    <!-- Add Server Modal -->
    <div id="modal-add" class="hidden fixed inset-0 bg-black/60 backdrop-blur-sm flex items-center justify-center p-4 z-50">
        <form method="post" class="bg-white p-8 rounded-2xl shadow-2xl w-full max-w-md border border-gray-200">
            <input type="hidden" name="csrf" value="<?= csrf_token() ?>"><input type="hidden" name="action" value="add_server">
            <h2 class="text-xl font-black mb-6 text-gray-900 tracking-tight">Connect New Database Node</h2>
            <div class="space-y-4">
                <div><label class="text-[10px] font-bold text-gray-400 uppercase ml-1">Display Name</label><input type="text" name="name" placeholder="e.g. US-East Production" class="w-full rounded-lg border-gray-300" required></div>
                <div><label class="text-[10px] font-bold text-gray-400 uppercase ml-1">Internal IP/Host</label><input type="text" name="host" placeholder="10.0.0.5" class="w-full rounded-lg border-gray-300" required></div>
                <div><label class="text-[10px] font-bold text-gray-400 uppercase ml-1">Agent API Key</label><input type="password" name="agent_key" placeholder="From Node summary" class="w-full rounded-lg border-gray-300" required></div>
                <div><label class="text-[10px] font-bold text-gray-400 uppercase ml-1">Public URL (for Smart Links)</label><input type="text" name="public_url" placeholder="https://db1.example.com" class="w-full rounded-lg border-gray-300 font-mono text-xs" required></div>
            </div>
            <div class="flex justify-end space-x-3 mt-8">
                <button type="button" onclick="document.getElementById('modal-add').classList.add('hidden')" class="px-6 py-2 text-gray-400 font-bold hover:text-gray-600">Cancel</button>
                <button type="submit" class="bg-indigo-600 text-white px-8 py-2 rounded-lg font-bold shadow-lg hover:bg-indigo-700 transition-colors">Add Server</button>
            </div>
        </form>
    </div>
</main>
<footer class="text-center py-10 text-[10px] text-gray-400 font-bold uppercase tracking-widest tracking-widest">&copy; <?= date('Y') ?> Database Management System &bull; Version 2.0 Hub</footer>
</body></html>
PHPHUB

  sed -i "s|__HUB_USER__|${HUB_ADMIN_USER}|g" "$HUB_ROOT/index.php"
  sed -i "s|__HUB_HASH__|${HUB_ADMIN_HASH}|g" "$HUB_ROOT/index.php"
  sed -i "s|__CSRF_SECRET__|${CSRF_SECRET}|g" "$HUB_ROOT/index.php"

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
  msg_ok "Hub deployed successfully"
}

configure_firewall() {
  msg_header "Configuring Firewall"
  ufw allow OpenSSH
  ufw allow 'Apache Full'
  ufw --force enable
}

write_summary() {
  cat > "$SUMMARY_FILE" <<EOF
DB HUB INSTALLATION COMPLETE
Access URL: http://${SITE_FQDN}/${HUB_ALIAS}
Admin User: ${HUB_ADMIN_USER}
Admin Pass: ${HUB_ADMIN_PASS}
EOF
  echo -e "\n${CLR_BOLD}${CLR_GREEN}Hub is ready!${CLR_RESET}"
  echo -e "Login Pass: ${CLR_YELLOW}${HUB_ADMIN_PASS}${CLR_RESET}"
}

main() {
  clear
  require_ubuntu
  wizard
  install_packages
  deploy_hub
  systemctl restart apache2
  configure_firewall
  write_summary
}

main "$@"
