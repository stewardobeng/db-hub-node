#!/usr/bin/env bash
set -Eeuo pipefail

# DB Platform HUB Installer (Central Management Console)
# Now with Multi-Server S3/R2 Backup Management.

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
        public_url TEXT,
        s3_endpoint TEXT,
        s3_bucket TEXT,
        s3_access_key TEXT,
        s3_secret_key TEXT
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
    <body class="bg-gray-100 flex items-center justify-center min-h-screen">
    <div class="bg-white p-8 rounded-xl shadow-lg border border-gray-200 w-full max-w-md text-center">
        <div class="bg-indigo-600 text-white w-16 h-16 rounded-full flex items-center justify-center mx-auto mb-4"><i class="fa-solid fa-vault text-2xl"></i></div>
        <h1 class="text-2xl font-bold mb-6">Management Hub</h1>
        <?php if (isset($error)) echo "<div class='bg-red-50 text-red-700 p-3 rounded mb-4 text-sm'>$error</div>"; ?>
        <form method="post" class="space-y-4 text-left">
            <input type="hidden" name="action" value="login"><input type="hidden" name="csrf" value="<?= csrf_token() ?>">
            <label class="block text-xs font-bold text-gray-400 uppercase">Username</label>
            <input type="text" name="username" class="w-full rounded-md border-gray-300" required autofocus>
            <label class="block text-xs font-bold text-gray-400 uppercase">Password</label>
            <input type="password" name="password" class="w-full rounded-md border-gray-300" required>
            <button class="w-full bg-indigo-600 text-white font-bold py-3 rounded shadow-lg hover:bg-indigo-700 transition-all">Unlock Dashboard</button>
        </form></div></body></html><?php exit;
}

$db = hub_db();
$message = $_SESSION['message'] ?? ''; unset($_SESSION['message']);
$error = $_SESSION['error'] ?? ''; unset($_SESSION['error']);
$view = $_GET['view'] ?? 'dashboard';

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
        $_SESSION['message'] = "S3 Settings Saved locally.";
        header('Location: ' . $_SERVER['PHP_SELF'] . "?view=backups"); exit;
    }
}

$servers = $db->query("SELECT * FROM servers")->fetchAll(PDO::FETCH_ASSOC);
$active_id = $_SESSION['active_server_id'] ?? ($servers[0]['id'] ?? null);
$active_server = null;
foreach($servers as $s) { if($s['id'] == $active_id) $active_server = $s; }

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

?><!doctype html><html><head><meta charset="utf-8"><title>DB Hub Dashboard</title>
<script src="https://cdn.tailwindcss.com?plugins=forms"></script>
<link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css" rel="stylesheet"/>
</head><body class="bg-gray-50 font-sans antialiased text-gray-800">

<header class="bg-gray-900 text-white flex items-center justify-between px-6 py-3 shadow-lg">
    <h1 class="text-lg font-black tracking-tighter uppercase"><i class="fa-solid fa-shield-halved mr-2 text-indigo-400"></i>DB-Shield Hub</h1>
    <div class="flex items-center space-x-6">
        <form method="post" class="flex items-center bg-gray-800 rounded px-2 py-1 border border-gray-700">
            <input type="hidden" name="csrf" value="<?= csrf_token() ?>"><input type="hidden" name="action" value="select_server">
            <select name="server_id" onchange="this.form.submit()" class="bg-transparent border-none text-xs text-white focus:ring-0 cursor-pointer">
                <option value="" disabled <?= !$active_id ? 'selected' : '' ?>>Switch Server...</option>
                <?php foreach($servers as $s): ?><option value="<?= $s['id'] ?>" <?= $s['id'] == $active_id ? 'selected' : '' ?> class="text-black"><?= e($s['name']) ?></option><?php endforeach; ?>
            </select>
        </form>
        <button onclick="document.getElementById('modal-add').classList.remove('hidden')" class="text-gray-400 hover:text-white"><i class="fa-solid fa-plus-circle"></i></button>
        <a href="?action=logout" class="text-gray-400 hover:text-white"><i class="fa-solid fa-power-off"></i></a>
    </div>
</header>

<main class="max-w-7xl mx-auto px-4 py-6 space-y-6">
    <?php if ($message): ?><div class="bg-green-100 border border-green-200 text-green-800 px-4 py-3 rounded-lg flex items-center shadow-sm"><i class="fa-solid fa-check-circle mr-2"></i><?= e($message) ?></div><?php endif; ?>
    <?php if ($error): ?><div class="bg-red-100 border border-red-200 text-red-800 px-4 py-3 rounded-lg flex items-center shadow-sm"><i class="fa-solid fa-circle-exclamation mr-2"></i><?= e($error) ?></div><?php endif; ?>
    
    <div class="flex space-x-1 bg-white p-1 rounded-lg border border-gray-200 shadow-sm w-fit">
        <a href="?view=dashboard" class="px-6 py-2 text-xs font-black uppercase tracking-widest rounded-md <?= $view === 'dashboard' ? 'bg-indigo-600 text-white shadow-md' : 'text-gray-400 hover:text-gray-600' ?>">Dashboard</a>
        <a href="?view=backups" class="px-6 py-2 text-xs font-black uppercase tracking-widest rounded-md <?= $view === 'backups' ? 'bg-indigo-600 text-white shadow-md' : 'text-gray-400 hover:text-gray-600' ?>">Recovery</a>
    </div>

    <?php if (!$active_server): ?>
        <div class="bg-white p-20 rounded-3xl text-center border-2 border-dashed border-gray-300 shadow-sm">
            <i class="fa-solid fa-server text-6xl text-gray-100 mb-6"></i><h2 class="text-2xl font-black text-gray-400">Zero Nodes Detected</h2>
            <p class="text-gray-400 mb-10 max-w-sm mx-auto">Connect your first remote database server to start leveraging automated provisioning and cloud backups.</p>
            <button onclick="document.getElementById('modal-add').classList.remove('hidden')" class="bg-indigo-600 text-white px-10 py-4 rounded-xl font-black shadow-xl hover:scale-105 transition-all">Add Production Server</button>
        </div>
    <?php elseif ($view === 'backups'): ?>
        <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
            <div class="lg:col-span-2 space-y-6">
                <section class="bg-white rounded-2xl border border-gray-200 shadow-sm overflow-hidden">
                    <div class="px-6 py-4 border-b border-gray-100 bg-gray-50 flex items-center justify-between">
                        <h2 class="font-black text-gray-900">Local Recovery Points</h2>
                        <form method="post"><input type="hidden" name="csrf" value="<?= csrf_token() ?>"><input type="hidden" name="node_action" value="trigger_backup"><button class="bg-indigo-600 text-white px-4 py-1.5 rounded-lg font-bold text-xs shadow-sm hover:bg-indigo-700">Snapshot Now</button></form>
                    </div>
                    <div class="overflow-x-auto">
                        <table class="min-w-full divide-y divide-gray-100">
                            <thead class="bg-gray-50"><tr><th class="px-6 py-3 text-left text-[10px] font-black text-gray-400 uppercase">Filename</th><th class="px-6 py-3 text-left text-[10px] font-black text-gray-400 uppercase">Size</th><th class="px-6 py-3 text-center text-[10px] font-black text-gray-400 uppercase">Action</th></tr></thead>
                            <tbody class="divide-y divide-gray-50">
                                <?php foreach($backups as $b): if(isset($b['error'])) continue; ?>
                                <tr class="hover:bg-gray-50 transition-colors">
                                    <td class="px-6 py-4 whitespace-nowrap text-sm font-bold text-gray-700"><?= e($b['name']) ?></td>
                                    <td class="px-6 py-4 whitespace-nowrap text-xs text-gray-400"><?= e($b['size']) ?></td>
                                    <td class="px-6 py-4 whitespace-nowrap text-center">
                                        <form method="post" onsubmit="return confirm('DESTROY CURRENT DATA AND RESTORE?');" class="inline">
                                            <input type="hidden" name="csrf" value="<?= csrf_token() ?>"><input type="hidden" name="node_action" value="restore"><input type="hidden" name="filename" value="<?= e($b['name']) ?>">
                                            <button class="text-red-600 hover:text-red-800 font-black text-xs uppercase tracking-tighter">Restore</button>
                                        </form>
                                    </td>
                                </tr>
                                <?php endforeach; ?>
                            </tbody>
                        </table>
                    </div>
                </section>
            </div>
            <div class="space-y-6">
                <section class="bg-white p-6 rounded-2xl border border-gray-200 shadow-sm">
                    <h2 class="font-black text-gray-900 mb-6 flex items-center"><i class="fa-solid fa-cloud mr-2 text-indigo-500"></i>Cloud Sync (S3/R2)</h2>
                    <form method="post" class="space-y-4">
                        <input type="hidden" name="csrf" value="<?= csrf_token() ?>"><input type="hidden" name="action" value="update_s3"><input type="hidden" name="server_id" value="<?= $active_server['id'] ?>">
                        <div><label class="text-[10px] font-black text-gray-400 uppercase block mb-1">Endpoint URL</label><input type="text" name="s3_endpoint" value="<?= e($active_server['s3_endpoint'] ?? '') ?>" placeholder="e.g. https://<id>.r2.cloudflarestorage.com" class="w-full rounded-lg border-gray-300 text-sm"></div>
                        <div><label class="text-[10px] font-black text-gray-400 uppercase block mb-1">Bucket Name</label><input type="text" name="s3_bucket" value="<?= e($active_server['s3_bucket'] ?? '') ?>" class="w-full rounded-lg border-gray-300 text-sm"></div>
                        <div><label class="text-[10px] font-black text-gray-400 uppercase block mb-1">Access Key</label><input type="text" name="s3_access_key" value="<?= e($active_server['s3_access_key'] ?? '') ?>" class="w-full rounded-lg border-gray-300 text-sm"></div>
                        <div><label class="text-[10px] font-black text-gray-400 uppercase block mb-1">Secret Key</label><input type="password" name="s3_secret_key" value="<?= e($active_server['s3_secret_key'] ?? '') ?>" class="w-full rounded-lg border-gray-300 text-sm"></div>
                        <button type="submit" class="w-full bg-gray-900 text-white py-3 rounded-xl font-black text-xs uppercase tracking-widest shadow-lg hover:bg-black transition-all">Save Local Config</button>
                    </form>
                    <form method="post" class="mt-4">
                        <input type="hidden" name="csrf" value="<?= csrf_token() ?>"><input type="hidden" name="node_action" value="save_s3_config">
                        <?php foreach(['s3_endpoint','s3_bucket','s3_access_key','s3_secret_key'] as $f): ?> <input type="hidden" name="<?= $f ?>" value="<?= e($active_server[$f] ?? '') ?>"> <?php endforeach; ?>
                        <button class="w-full bg-indigo-50 text-indigo-600 border border-indigo-100 py-3 rounded-xl font-black text-xs uppercase tracking-widest hover:bg-indigo-600 hover:text-white transition-all">Push to Remote Node</button>
                    </form>
                </section>
            </div>
        </div>
    <?php else: ?>
        <!-- Server Analytics -->
        <section class="grid grid-cols-1 md:grid-cols-4 gap-4">
            <div class="bg-white p-5 rounded-2xl border border-gray-200 shadow-sm">
                <span class="text-[10px] font-black text-gray-400 uppercase tracking-widest block mb-1">System Health</span>
                <div class="text-2xl font-black text-gray-900"><?= $stats['cpu'] ?? '?' ?><span class="text-xs font-normal text-gray-400 ml-1">CPU %</span></div>
                <div class="w-full bg-gray-100 h-1 rounded-full mt-3"><div class="bg-indigo-600 h-full rounded-full" style="width: <?= $stats['cpu'] ?? 0 ?>%"></div></div>
            </div>
            <div class="bg-white p-5 rounded-2xl border border-gray-200 shadow-sm">
                <span class="text-[10px] font-black text-gray-400 uppercase tracking-widest block mb-1">Memory Pool</span>
                <div class="text-2xl font-black text-gray-900"><?= $stats['ram'] ?? '?' ?><span class="text-xs font-normal text-gray-400 ml-1">Used %</span></div>
                <div class="text-[10px] text-gray-400 mt-1"><?= $stats['ram_text'] ?? 'Calculating...' ?></div>
            </div>
            <div class="bg-white p-5 rounded-2xl border border-gray-200 shadow-sm">
                <span class="text-[10px] font-black text-gray-400 uppercase tracking-widest block mb-1">Disk Array</span>
                <div class="text-2xl font-black text-gray-900"><?= $stats['disk'] ?? '?' ?><span class="text-xs font-normal text-gray-400 ml-1">Full %</span></div>
                <div class="text-[10px] text-gray-400 mt-1"><?= $stats['disk_text'] ?? '' ?></div>
            </div>
            <div class="bg-white p-5 rounded-2xl border border-gray-200 shadow-sm border-l-4 border-l-green-500">
                <span class="text-[10px] font-black text-gray-400 uppercase tracking-widest block mb-1">Connectivity</span>
                <div class="text-2xl font-black text-green-600 uppercase">ONLINE</div>
                <div class="text-[10px] text-gray-400 mt-1"><?= e($active_server['host']) ?></div>
            </div>
        </section>

        <!-- Node management -->
        <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
            <section class="bg-white p-8 rounded-2xl border border-gray-200 shadow-sm">
                <h2 class="font-black text-gray-900 mb-6 flex items-center uppercase tracking-tighter"><i class="fa-solid fa-plus-circle mr-2 text-indigo-600 text-xl"></i>Provision New Tenant</h2>
                <form method="post" class="space-y-4">
                    <input type="hidden" name="csrf" value="<?= csrf_token() ?>"><input type="hidden" name="node_action" value="create">
                    <div class="grid grid-cols-2 gap-4">
                        <div><label class="text-[10px] font-black text-gray-400 uppercase ml-1">Prefix</label><input type="text" name="db_prefix" placeholder="clienta" class="w-full rounded-lg border-gray-300 text-sm" required></div>
                        <div><label class="text-[10px] font-black text-gray-400 uppercase ml-1">Suffix</label><input type="text" name="db_suffix" value="db" class="w-full rounded-lg border-gray-300 text-sm" required></div>
                    </div>
                    <div><label class="text-[10px] font-black text-gray-400 uppercase ml-1">Remote Host Access</label><input type="text" name="remote_host" value="localhost" class="w-full rounded-lg border-gray-300 text-sm" required></div>
                    <button class="w-full bg-indigo-600 text-white font-black py-3 rounded-xl uppercase tracking-widest text-xs shadow-xl hover:bg-indigo-700 transition-all">Execute Provisioning</button>
                </form>
            </section>
            
            <section class="bg-white p-8 rounded-2xl border border-gray-200 shadow-sm overflow-hidden">
                <h2 class="font-black text-gray-900 mb-6 flex items-center uppercase tracking-tighter"><i class="fa-solid fa-database mr-2 text-indigo-600 text-xl"></i>Active Databases</h2>
                <div class="max-h-[240px] overflow-y-auto pr-2">
                    <table class="min-w-full divide-y divide-gray-100">
                        <tbody class="divide-y divide-gray-50">
                            <?php foreach($tenants as $t): if(isset($t['error'])) continue; ?>
                            <tr>
                                <td class="py-3 font-bold text-sm text-gray-900"><?= e($t['db']) ?></td>
                                <td class="py-3 text-right">
                                    <a href="<?= rtrim($active_server['public_url'], '/') ?>/phpmyadmin" target="_blank" class="text-indigo-600 font-black text-[10px] uppercase border border-indigo-100 px-3 py-1 rounded hover:bg-indigo-600 hover:text-white transition-all">PMA Login</a>
                                </td>
                            </tr>
                            <?php endforeach; ?>
                        </tbody>
                    </table>
                </div>
            </section>
        </div>
    <?php endif; ?>

    <!-- Add Server Modal -->
    <div id="modal-add" class="hidden fixed inset-0 bg-gray-900/80 backdrop-blur-sm flex items-center justify-center p-4 z-50">
        <form method="post" class="bg-white p-10 rounded-3xl shadow-2xl w-full max-w-md border border-gray-100">
            <input type="hidden" name="csrf" value="<?= csrf_token() ?>"><input type="hidden" name="action" value="add_server">
            <h2 class="text-2xl font-black mb-8 text-gray-900 tracking-tighter">Add Remote Node</h2>
            <div class="space-y-5">
                <div><label class="text-[10px] font-black text-gray-400 uppercase ml-1">Server Label</label><input type="text" name="name" class="w-full rounded-xl border-gray-200 p-3 shadow-sm" required></div>
                <div><label class="text-[10px] font-black text-gray-400 uppercase ml-1">Node IP/Domain</label><input type="text" name="host" class="w-full rounded-xl border-gray-200 p-3 shadow-sm" required></div>
                <div><label class="text-[10px] font-black text-gray-400 uppercase ml-1">Agent Security Key</label><input type="password" name="agent_key" class="w-full rounded-xl border-gray-200 p-3 shadow-sm" required></div>
                <div><label class="text-[10px] font-black text-gray-400 uppercase ml-1">Public URL (HTTPS)</label><input type="text" name="public_url" class="w-full rounded-xl border-gray-200 p-3 shadow-sm font-mono text-xs" required></div>
            </div>
            <div class="flex justify-end space-x-4 mt-10">
                <button type="button" onclick="document.getElementById('modal-add').classList.add('hidden')" class="px-6 py-2 text-gray-400 font-bold uppercase tracking-widest text-xs">Cancel</button>
                <button type="submit" class="bg-indigo-600 text-white px-8 py-3 rounded-xl font-black uppercase tracking-widest text-xs shadow-lg hover:bg-indigo-700">Link Server</button>
            </div>
        </form>
    </div>
</main>
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
