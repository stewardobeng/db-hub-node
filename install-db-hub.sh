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

sed_escape() { printf '%s' "$1" | sed -e 's/[|&\\]/\\&/g'; }

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
: "${ADMIN_EMAIL:=}"
: "${PAYSTACK_SECRET:=}"
: "${PAYSTACK_CURRENCY:=NGN}"
: "${SMTP_HOST:=}"
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
    read -p "Admin Alert Email: " input_admin_email; ADMIN_EMAIL=${input_admin_email:-$ADMIN_EMAIL}
    read -p "Paystack Secret (leave blank to disable billing): " input_paystack; PAYSTACK_SECRET=${input_paystack:-$PAYSTACK_SECRET}
    read -p "Paystack Currency [$PAYSTACK_CURRENCY]: " input_currency; PAYSTACK_CURRENCY=${input_currency:-$PAYSTACK_CURRENCY}
    msg_header "SMTP Notification Config"
    read -p "SMTP Host [$SMTP_HOST]: " input_host; SMTP_HOST=${input_host:-$SMTP_HOST}
    read -p "SMTP Port [$SMTP_PORT]: " input_port; SMTP_PORT=${input_port:-$SMTP_PORT}
    [[ "$SMTP_PORT" =~ ^[0-9]+$ ]] || SMTP_PORT=587
    read -p "SMTP User: " input_smtp_user; SMTP_USER=${input_smtp_user:-$SMTP_USER}
    read -p "SMTP Pass: " input_smtp_pass; SMTP_PASS=${input_smtp_pass:-$SMTP_PASS}
    read -p "SMTP From [$SMTP_FROM]: " input_from; SMTP_FROM=${input_from:-$SMTP_FROM}
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
const ADMIN_EMAIL = '__ADMIN_EMAIL__';
const APP_SECRET = '__CSRF_SECRET__';
const PAYSTACK_SECRET = '__PAYSTACK_SECRET__';
const PAYSTACK_CURRENCY = '__PAYSTACK_CURRENCY__';
const HUB_DB = 'hub_v5.sqlite';
const SMTP_HOST = '__SMTP_HOST__';
const SMTP_PORT = __SMTP_PORT__;
const SMTP_USER = '__SMTP_USER__';
const SMTP_PASS = '__SMTP_PASS__';
const SMTP_FROM = '__SMTP_FROM__';

header("X-Frame-Options: DENY");
header("X-Content-Type-Options: nosniff");
header("Referrer-Policy: no-referrer");
header("Content-Security-Policy: default-src 'self' https://cdn.tailwindcss.com https://cdnjs.cloudflare.com; script-src 'self' 'unsafe-inline' https://cdn.tailwindcss.com https://cdnjs.cloudflare.com; style-src 'self' 'unsafe-inline' https://cdnjs.cloudflare.com; font-src 'self' https://cdnjs.cloudflare.com data:;");

function e(string $v): string { return htmlspecialchars($v, ENT_QUOTES, 'UTF-8'); }
function flash(string $key, string $message): void { $_SESSION[$key] = $message; }
function consume_flash(string $key): string {
    $value = $_SESSION[$key] ?? '';
    unset($_SESSION[$key]);
    return $value;
}
function alert_html(string $message, string $type = 'info'): string {
    if ($message === '') return '';
    $palette = $type === 'error'
        ? 'bg-red-500/10 border-red-500/20 text-red-300'
        : 'bg-emerald-500/10 border-emerald-500/20 text-emerald-200';
    return '<div class="' . $palette . ' border rounded-3xl px-6 py-5 text-sm font-bold tracking-wide">' . e($message) . '</div>';
}
function client_ip(): string { return $_SERVER['REMOTE_ADDR'] ?? '0.0.0.0'; }
function csrf_token(): string {
    if (empty($_SESSION['csrf'])) $_SESSION['csrf'] = hash_hmac('sha256', session_id(), APP_SECRET);
    return $_SESSION['csrf'];
}
function require_csrf(): void {
    if (!hash_equals(csrf_token(), $_POST['csrf'] ?? '')) throw new RuntimeException('Security violation.');
}
function app_url(array $query = []): string {
    $scheme = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off') ? 'https' : 'http';
    $host = $_SERVER['HTTP_HOST'] ?? 'localhost';
    $path = strtok($_SERVER['REQUEST_URI'] ?? '/index.php', '?') ?: '/index.php';
    return $scheme . '://' . $host . $path . ($query ? '?' . http_build_query($query) : '');
}
function seed_default_packages(PDO $pdo): void {
    if ((int)$pdo->query("SELECT COUNT(*) FROM packages")->fetchColumn() > 0) return;
    $stmt = $pdo->prepare("INSERT INTO packages (name, price, db_limit, disk_quota_gb, max_conns, duration_days) VALUES (?,?,?,?,?,?)");
    foreach ([['Starter', 15000, 1, 1, 10, 30], ['Growth', 35000, 5, 5, 25, 30], ['Scale', 75000, 20, 20, 75, 30]] as $pkg) $stmt->execute($pkg);
}
function hub_db(): PDO {
    static $pdo = null; if ($pdo instanceof PDO) return $pdo;
    $pdo = new PDO('sqlite:' . __DIR__ . DIRECTORY_SEPARATOR . HUB_DB);
    $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    $pdo->exec("CREATE TABLE IF NOT EXISTS servers (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, host TEXT, agent_key TEXT, public_url TEXT, pma_alias TEXT DEFAULT 'phpmyadmin', last_seen DATETIME, s3_endpoint TEXT, s3_bucket TEXT, s3_access_key TEXT, s3_secret_key TEXT)");
    $pdo->exec("CREATE TABLE IF NOT EXISTS packages (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, price REAL, db_limit INTEGER, disk_quota_gb INTEGER DEFAULT 1, max_conns INTEGER DEFAULT 10, duration_days INTEGER DEFAULT 30)");
    $pdo->exec("CREATE TABLE IF NOT EXISTS clients (id INTEGER PRIMARY KEY AUTOINCREMENT, email TEXT UNIQUE, password_hash TEXT, package_id INTEGER, expires_at DATETIME, status TEXT DEFAULT 'pending')");
    $pdo->exec("CREATE TABLE IF NOT EXISTS tenant_dbs (id INTEGER PRIMARY KEY AUTOINCREMENT, client_id INTEGER, server_id INTEGER, db_name TEXT, db_user TEXT, allowed_ips TEXT DEFAULT '[\"%\"]', last_size_mb REAL DEFAULT 0)");
    $pdo->exec("CREATE TABLE IF NOT EXISTS security_log (ip TEXT UNIQUE, attempts INTEGER DEFAULT 0, last_attempt DATETIME)");
    try { $pdo->exec("ALTER TABLE servers ADD COLUMN pma_alias TEXT DEFAULT 'phpmyadmin'"); } catch (Throwable $e) {}
    seed_default_packages($pdo);
    return $pdo;
}
function refresh_expired_clients(PDO $db): void {
    $db->exec("UPDATE clients SET status = 'expired' WHERE status = 'active' AND expires_at IS NOT NULL AND expires_at != '' AND expires_at < datetime('now')");
}
function is_client_active(array $client): bool {
    if (($client['status'] ?? '') !== 'active') return false;
    if (!empty($client['expires_at']) && strtotime((string)$client['expires_at']) < time()) return false;
    return true;
}
function is_ip_locked(PDO $db, string $ip): bool {
    $stmt = $db->prepare("SELECT attempts, last_attempt FROM security_log WHERE ip = ?");
    $stmt->execute([$ip]);
    $row = $stmt->fetch(PDO::FETCH_ASSOC);
    if (!$row) return false;
    $last = strtotime((string)$row['last_attempt']);
    if ($last === false || (time() - $last) > 900) {
        $db->prepare("DELETE FROM security_log WHERE ip = ?")->execute([$ip]);
        return false;
    }
    return (int)$row['attempts'] >= 5;
}
function record_failed_login(PDO $db, string $ip): void {
    $stmt = $db->prepare("SELECT attempts, last_attempt FROM security_log WHERE ip = ?");
    $stmt->execute([$ip]);
    $row = $stmt->fetch(PDO::FETCH_ASSOC);
    $now = date('Y-m-d H:i:s');
    if (!$row || (($last = strtotime((string)$row['last_attempt'])) !== false && (time() - $last) > 900)) {
        $db->prepare("INSERT INTO security_log (ip, attempts, last_attempt) VALUES (?, 1, ?) ON CONFLICT(ip) DO UPDATE SET attempts = 1, last_attempt = excluded.last_attempt")->execute([$ip, $now]);
        return;
    }
    $db->prepare("UPDATE security_log SET attempts = attempts + 1, last_attempt = ? WHERE ip = ?")->execute([$now, $ip]);
}
function clear_failed_login(PDO $db, string $ip): void {
    $db->prepare("DELETE FROM security_log WHERE ip = ?")->execute([$ip]);
}
function call_agent(array $server, array $params = []): array {
    if (empty($server['public_url']) || empty($server['agent_key'])) return ['error' => 'Server configuration is incomplete.'];
    $query = array_merge(['key' => $server['agent_key']], array_diff_key($params, ['post_data' => true, 'timeout' => true]));
    $ch = curl_init(rtrim((string)$server['public_url'], '/') . "/agent-api/agent.php?" . http_build_query($query));
    curl_setopt($ch, CURLOPT_RETURNTRANSFER, true); curl_setopt($ch, CURLOPT_TIMEOUT, max(5, (int)($params['timeout'] ?? 5)));
    if (!empty($params['post_data'])) {
        curl_setopt($ch, CURLOPT_POST, true); curl_setopt($ch, CURLOPT_POSTFIELDS, http_build_query($params['post_data']));
    }
    $res = curl_exec($ch);
    if ($res === false) {
        $error = curl_error($ch) ?: 'Node Unreachable';
        curl_close($ch);
        return ['error' => $error];
    }
    curl_close($ch);
    $decoded = json_decode((string)$res, true);
    return is_array($decoded) ? $decoded : ['error' => 'Invalid node response'];
}
function smtp_write($socket, string $command): void { fwrite($socket, $command . "\r\n"); }
function smtp_expect($socket, array $codes): string {
    $response = '';
    while (($line = fgets($socket)) !== false) {
        $response .= $line;
        if (isset($line[3]) && $line[3] === ' ') break;
    }
    $code = (int)substr($response, 0, 3);
    if (!in_array($code, $codes, true)) throw new RuntimeException(trim($response));
    return $response;
}
function send_mail(string $to, string $subj, string $msg): void {
    if ($to === '') return;
    $headers = "MIME-Version: 1.0\r\nContent-type:text/html;charset=UTF-8\r\nFrom: " . SMTP_FROM . "\r\n";
    $body = "<html><body style='font-family:sans-serif;'>" . $msg . "</body></html>";
    if (SMTP_HOST !== '') {
        try {
            $remote = (SMTP_PORT === 465 ? 'tls://' : '') . SMTP_HOST . ':' . SMTP_PORT;
            $socket = @stream_socket_client($remote, $errno, $errstr, 15);
            if (!$socket) throw new RuntimeException($errstr ?: 'SMTP unavailable');
            stream_set_timeout($socket, 15);
            smtp_expect($socket, [220]);
            smtp_write($socket, 'EHLO db-shield');
            smtp_expect($socket, [250]);
            if (SMTP_PORT !== 465) {
                smtp_write($socket, 'STARTTLS');
                $response = smtp_expect($socket, [220, 454]);
                if (str_starts_with($response, '220') && @stream_socket_enable_crypto($socket, true, STREAM_CRYPTO_METHOD_TLS_CLIENT)) {
                    smtp_write($socket, 'EHLO db-shield');
                    smtp_expect($socket, [250]);
                }
            }
            if (SMTP_USER !== '' || SMTP_PASS !== '') {
                smtp_write($socket, 'AUTH LOGIN');
                smtp_expect($socket, [334]);
                smtp_write($socket, base64_encode(SMTP_USER));
                smtp_expect($socket, [334]);
                smtp_write($socket, base64_encode(SMTP_PASS));
                smtp_expect($socket, [235]);
            }
            smtp_write($socket, 'MAIL FROM:<' . SMTP_FROM . '>');
            smtp_expect($socket, [250]);
            smtp_write($socket, 'RCPT TO:<' . $to . '>');
            smtp_expect($socket, [250, 251]);
            smtp_write($socket, 'DATA');
            smtp_expect($socket, [354]);
            fwrite($socket, "Subject: {$subj}\r\n{$headers}\r\n{$body}\r\n.\r\n");
            smtp_expect($socket, [250]);
            smtp_write($socket, 'QUIT');
            fclose($socket);
            return;
        } catch (Throwable $e) {
        }
    }
    @mail($to, $subj, $body, $headers);
}

function paystack_enabled(): bool { return PAYSTACK_SECRET !== ''; }
function paystack_initialize(array $package, string $email): array {
    if (!paystack_enabled()) return ['error' => 'Billing provider is not configured.'];
    $amount = (int)round(((float)$package['price']) * 100);
    if ($amount <= 0) return ['authorization_url' => ''];
    $payload = json_encode([
        'email' => $email,
        'amount' => $amount,
        'currency' => PAYSTACK_CURRENCY,
        'callback_url' => app_url(['view' => 'login', 'payment' => 'pending']),
        'metadata' => ['package_id' => (int)$package['id']],
    ]);
    $ch = curl_init('https://api.paystack.co/transaction/initialize');
    curl_setopt_array($ch, [
        CURLOPT_POST => true,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT => 15,
        CURLOPT_HTTPHEADER => [
            'Authorization: Bearer ' . PAYSTACK_SECRET,
            'Content-Type: application/json',
        ],
        CURLOPT_POSTFIELDS => $payload,
    ]);
    $res = curl_exec($ch);
    if ($res === false) {
        $error = curl_error($ch) ?: 'Unable to initialize payment';
        curl_close($ch);
        return ['error' => $error];
    }
    curl_close($ch);
    $decoded = json_decode((string)$res, true);
    return isset($decoded['data']) && is_array($decoded['data'])
        ? $decoded['data']
        : ['error' => $decoded['message'] ?? 'Unable to initialize payment'];
}
function sync_client_usage(PDO $db, int $clientId): void {
    $stmt = $db->prepare("SELECT t.id, t.db_name, t.server_id, s.agent_key, s.public_url FROM tenant_dbs t JOIN servers s ON t.server_id = s.id WHERE t.client_id = ? ORDER BY t.server_id");
    $stmt->execute([$clientId]);
    $rows = $stmt->fetchAll(PDO::FETCH_ASSOC);
    if (!$rows) return;
    $grouped = [];
    foreach ($rows as $row) {
        $grouped[$row['server_id']]['server'] = ['agent_key' => $row['agent_key'], 'public_url' => $row['public_url']];
        $grouped[$row['server_id']]['rows'][] = $row;
    }
    $update = $db->prepare("UPDATE tenant_dbs SET last_size_mb = ? WHERE id = ?");
    foreach ($grouped as $bundle) {
        $inventory = call_agent($bundle['server'], ['action' => 'list_tenants']);
        if (!is_array($inventory) || isset($inventory['error'])) continue;
        $sizes = [];
        foreach ($inventory as $tenant) {
            if (isset($tenant['db'])) $sizes[$tenant['db']] = (float)($tenant['size_mb'] ?? 0);
        }
        foreach ($bundle['rows'] as $row) {
            $update->execute([$sizes[$row['db_name']] ?? 0, $row['id']]);
        }
    }
}
function load_package(PDO $db, int $packageId): ?array {
    $stmt = $db->prepare("SELECT * FROM packages WHERE id = ?");
    $stmt->execute([$packageId]);
    $package = $stmt->fetch(PDO::FETCH_ASSOC);
    return $package ?: null;
}
function normalise_client_status(string $status): string {
    return in_array($status, ['active', 'pending', 'expired'], true) ? $status : 'active';
}
function resolve_client_expiry(array $package, string $status, string $value): ?string {
    $value = trim($value);
    if ($value !== '') {
        $ts = strtotime($value);
        if ($ts === false) throw new InvalidArgumentException('Provide a valid expiry date.');
        return date('Y-m-d H:i:s', $ts);
    }
    if ($status === 'active') return date('Y-m-d H:i:s', strtotime('+' . ((int)($package['duration_days'] ?: 30)) . ' days'));
    if ($status === 'expired') return date('Y-m-d H:i:s', time() - 60);
    return null;
}
function datetime_local_value(?string $value): string {
    if (!$value) return '';
    $ts = strtotime($value);
    return $ts === false ? '' : date('Y-m-d\TH:i', $ts);
}
function upsert_env_value(string $content, string $key, string $value): string {
    $pattern = '/^' . preg_quote($key, '/') . '=.*$/m';
    if (preg_match($pattern, $content)) {
        return (string)preg_replace_callback($pattern, static fn() => $key . '=' . $value, $content, 1);
    }
    $content = rtrim($content, "\r\n");
    return $content === '' ? $key . '=' . $value : $content . "\n" . $key . '=' . $value;
}
function server_database_endpoint(array $server): array {
    $publicHost = (string)(parse_url((string)($server['public_url'] ?? ''), PHP_URL_HOST) ?: '');
    $configuredHost = trim((string)($server['host'] ?? ''));
    $host = $configuredHost !== '' ? $configuredHost : $publicHost;
    $port = 3306;
    if ($configuredHost !== '') {
        if (preg_match('/^\[(.+)\]:(\d{1,5})$/', $configuredHost, $m)) {
            $host = $m[1];
            $port = (int)$m[2];
        } elseif (substr_count($configuredHost, ':') === 1 && preg_match('/^([^:]+):(\d{1,5})$/', $configuredHost, $m)) {
            $host = $m[1];
            $port = (int)$m[2];
        }
    }
    return ['host' => $host !== '' ? $host : 'localhost', 'port' => $port > 0 ? $port : 3306];
}
function enrich_download_env(?array $download, array $server): ?array {
    if (!$download) return null;
    $endpoint = server_database_endpoint($server);
    $content = (string)($download['content'] ?? '');
    $content = upsert_env_value($content, 'DB_HOST', $endpoint['host']);
    $content = upsert_env_value($content, 'DB_PORT', (string)$endpoint['port']);
    $download['content'] = rtrim($content, "\r\n") . "\n";
    return $download;
}
function queue_backup(array $server, array $dbNames = []): array {
    $postData = [];
    $dbNames = array_values(array_unique(array_filter(array_map('trim', $dbNames))));
    if (count($dbNames) === 1) $postData['db_name'] = $dbNames[0];
    elseif ($dbNames) $postData['db_names'] = json_encode($dbNames);
    return call_agent($server, ['action' => 'trigger_backup', 'post_data' => $postData, 'timeout' => 15]);
}
function queue_backup_for_database(PDO $db, int $tdbId, ?int $clientId = null): array {
    $sql = "SELECT t.db_name, t.client_id, s.name AS server_name, s.agent_key, s.public_url
            FROM tenant_dbs t
            JOIN servers s ON s.id = t.server_id
            WHERE t.id = ?";
    $params = [$tdbId];
    if ($clientId !== null) {
        $sql .= " AND t.client_id = ?";
        $params[] = $clientId;
    }
    $stmt = $db->prepare($sql);
    $stmt->execute($params);
    $row = $stmt->fetch(PDO::FETCH_ASSOC);
    if (!$row) return ['error' => 'Database asset not found.'];
    $backup = queue_backup($row, [(string)$row['db_name']]);
    if (isset($backup['error'])) return ['error' => (string)$backup['error']];
    $message = 'Backup queued for ' . $row['db_name'] . ' on ' . $row['server_name'] . '.';
    if (!empty($backup['file'])) $message .= ' File: ' . $backup['file'];
    return ['message' => $message];
}
function queue_backup_for_client(PDO $db, int $clientId): array {
    $stmt = $db->prepare("SELECT t.db_name, s.name AS server_name, s.agent_key, s.public_url
                          FROM tenant_dbs t
                          JOIN servers s ON s.id = t.server_id
                          WHERE t.client_id = ?
                          ORDER BY t.id");
    $stmt->execute([$clientId]);
    $rows = $stmt->fetchAll(PDO::FETCH_ASSOC);
    if (!$rows) return ['error' => 'This client does not have any provisioned databases yet.'];
    $count = 0;
    $latestFile = '';
    $firstError = '';
    foreach ($rows as $row) {
        $backup = queue_backup($row, [(string)$row['db_name']]);
        if (isset($backup['error'])) {
            if ($firstError === '') $firstError = $row['db_name'] . ': ' . (string)$backup['error'];
            continue;
        }
        $count++;
        if (!empty($backup['file'])) $latestFile = (string)$backup['file'];
    }
    if ($count === 0) return ['error' => $firstError !== '' ? $firstError : 'Unable to queue a backup for this client.'];
    $message = $count === 1 ? 'Backup queued for 1 database.' : "Backup queued for {$count} databases.";
    if ($latestFile !== '') $message .= ' Latest file: ' . $latestFile;
    if ($firstError !== '') $message .= ' One or more databases failed to queue.';
    return ['message' => $message];
}
function queue_backup_for_server(PDO $db, int $serverId): array {
    $stmt = $db->prepare("SELECT * FROM servers WHERE id = ?");
    $stmt->execute([$serverId]);
    $server = $stmt->fetch(PDO::FETCH_ASSOC);
    if (!$server) return ['error' => 'Node not found.'];
    $backup = queue_backup($server);
    if (isset($backup['error'])) return ['error' => (string)$backup['error']];
    $message = 'Full-node backup queued for ' . $server['name'] . '.';
    if (!empty($backup['file'])) $message .= ' File: ' . $backup['file'];
    return ['message' => $message];
}
function provision_database_for_client(PDO $db, int $clientId): array {
    $me_stmt = $db->prepare("SELECT c.*, p.db_limit, p.disk_quota_gb, p.max_conns FROM clients c JOIN packages p ON c.package_id = p.id WHERE c.id = ?");
    $me_stmt->execute([$clientId]);
    $me = $me_stmt->fetch(PDO::FETCH_ASSOC);
    if (!$me) return ['error' => 'Client account was not found.'];
    if (!is_client_active($me)) return ['error' => 'Client account is not active.'];

    $countStmt = $db->prepare("SELECT COUNT(*) FROM tenant_dbs WHERE client_id = ?");
    $countStmt->execute([$clientId]);
    if ((int)$countStmt->fetchColumn() >= (int)$me['db_limit']) return ['error' => 'Database limit reached for this package.'];

    sync_client_usage($db, $clientId);
    $usageStmt = $db->prepare("SELECT COALESCE(SUM(last_size_mb), 0) FROM tenant_dbs WHERE client_id = ?");
    $usageStmt->execute([$clientId]);
    if ((float)$usageStmt->fetchColumn() >= ((int)$me['disk_quota_gb'] * 1024)) return ['error' => 'Disk quota reached for this package.'];

    $servers = $db->query("SELECT * FROM servers")->fetchAll(PDO::FETCH_ASSOC);
    $best = null; $min = 101;
    foreach($servers as $s) {
        $stats = call_agent($s, ['action' => 'stats']);
        if (!isset($stats['error']) && (int)($stats['cpu'] ?? 101) < $min) { $min = (int)$stats['cpu']; $best = $s; }
    }
    if (!$best) return ['error' => 'No online nodes are available right now.'];

    $prefix = bin2hex(random_bytes(4));
    $dbName = $prefix . '_db';
    $dbUser = $prefix . '_user';
    $node = call_agent($best, ['action' => 'create', 'post_data' => ['db_prefix' => $prefix, 'db_suffix' => 'db', 'remote_host' => '%', 'max_conns' => $me['max_conns']]]);
    if (isset($node['error'])) return ['error' => (string)$node['error']];

    $db->prepare("INSERT INTO tenant_dbs (client_id, server_id, db_name, db_user, allowed_ips, last_size_mb) VALUES (?,?,?,?,?,0)")->execute([$clientId, $best['id'], $dbName, $dbUser, json_encode(['%'])]);
    return ['message' => 'Database provisioned successfully.', 'download' => enrich_download_env($node['download'] ?? null, $best)];
}

if (isset($_GET['action']) && $_GET['action'] === 'watchdog') {
    $db = hub_db();
    refresh_expired_clients($db);
    foreach($db->query("SELECT * FROM servers")->fetchAll(PDO::FETCH_ASSOC) as $s) {
        $stats = call_agent($s, ['action' => 'stats']);
        if (isset($stats['error'])) send_mail(ADMIN_EMAIL, "NODE OFFLINE: " . $s['name'], "Node " . e((string)$s['name']) . " is unreachable.");
        else $db->prepare("UPDATE servers SET last_seen = CURRENT_TIMESTAMP WHERE id = ?")->execute([$s['id']]);
    }
    exit;
}

if (isset($_GET['action']) && $_GET['action'] === 'paystack_webhook') {
    if (!paystack_enabled()) exit;
    $input = file_get_contents("php://input");
    $sig = $_SERVER['HTTP_X_PAYSTACK_SIGNATURE'] ?? '';
    if ($sig !== hash_hmac('sha256', $input, PAYSTACK_SECRET)) exit;
    $event = json_decode($input, true);
    if (is_array($event) && ($event['event'] ?? '') === 'charge.success') {
        $email = $event['data']['customer']['email'] ?? '';
        $pkg_id = (int)($event['data']['metadata']['package_id'] ?? 1);
        if ($email !== '') {
            $db = hub_db();
            $pkg = $db->prepare("SELECT duration_days FROM packages WHERE id = ?");
            $pkg->execute([$pkg_id]);
            $days = (int)($pkg->fetchColumn() ?: 30);
            $expiry = date('Y-m-d H:i:s', strtotime("+{$days} days"));
            $db->prepare("UPDATE clients SET package_id = ?, expires_at = ?, status = 'active' WHERE email = ?")->execute([$pkg_id, $expiry, $email]);
            send_mail($email, "Subscription Active", "Your Shield Hub account is ready.");
        }
    }
    exit;
}

if (($_GET['payment'] ?? '') === 'pending') flash('message', 'Payment initiated. Your account will activate after Paystack confirms the charge.');

$is_admin = isset($_SESSION['role']) && $_SESSION['role'] === 'admin';
$client_id = $_SESSION['client_id'] ?? null;
$view = $_GET['view'] ?? ($is_admin ? 'admin' : ($client_id ? 'client' : 'landing'));

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $db = hub_db();
    refresh_expired_clients($db);
    require_csrf(); $action = $_POST['action'] ?? '';

    if ($action === 'login') {
        $ip = client_ip();
        if (is_ip_locked($db, $ip)) { flash('error', 'Too many failed login attempts. Try again in 15 minutes.'); header('Location: ?view=login'); exit; }
        $u = trim((string)($_POST['email'] ?? '')); $p = (string)($_POST['password'] ?? '');
        if ($u === ADMIN_USER && password_verify($p, ADMIN_HASH)) {
            clear_failed_login($db, $ip);
            session_regenerate_id(true);
            $_SESSION['role'] = 'admin';
            unset($_SESSION['client_id']);
            header('Location: ?view=admin');
            exit;
        }
        $user = $db->prepare("SELECT * FROM clients WHERE email = ?");
        $user->execute([$u]); $c = $user->fetch(PDO::FETCH_ASSOC);
        if ($c && password_verify($p, $c['password_hash'])) {
            clear_failed_login($db, $ip);
            if (!is_client_active($c)) flash('error', ($c['status'] ?? '') === 'pending' ? 'Account pending payment.' : 'Account access has expired.');
            else {
                session_regenerate_id(true);
                unset($_SESSION['role']);
                $_SESSION['client_id'] = $c['id'];
                header('Location: ?view=client');
                exit;
            }
        }
        else {
            record_failed_login($db, $ip);
            flash('error', 'Invalid access credentials.');
        }
        header('Location: ?view=login');
        exit;
    }

    if ($action === 'signup') {
        $email = trim((string)($_POST['email'] ?? ''));
        $plainPassword = (string)($_POST['password'] ?? '');
        $pkg_id = (int)($_POST['package_id'] ?? 0);
        $package = load_package($db, $pkg_id);
        if (!$package || !filter_var($email, FILTER_VALIDATE_EMAIL) || $plainPassword === '') {
            flash('error', 'Provide a valid email, password, and package.');
            header('Location: ?view=landing');
            exit;
        }
        $status = (!paystack_enabled() || (float)$package['price'] <= 0) ? 'active' : 'pending';
        $expiry = $status === 'active' ? date('Y-m-d H:i:s', strtotime('+' . ((int)($package['duration_days'] ?: 30)) . ' days')) : null;
        try {
            $db->prepare("INSERT INTO clients (email, password_hash, package_id, expires_at, status) VALUES (?,?,?,?,?)")->execute([$email, password_hash($plainPassword, PASSWORD_DEFAULT), $pkg_id, $expiry, $status]);
        } catch(Throwable $e) {
            flash('error', 'Account already exists.');
            header('Location: ?view=landing');
            exit;
        }
        if ($status === 'active') {
            flash('message', 'Account created. You can log in immediately.');
            header('Location: ?view=login');
            exit;
        }
        $checkout = paystack_initialize($package, $email);
        if (!empty($checkout['authorization_url'])) { header('Location: ' . $checkout['authorization_url']); exit; }
        flash('message', 'Account created. Complete payment to activate it.');
        if (!empty($checkout['error'])) flash('error', (string)$checkout['error']);
        header('Location: ?view=login');
        exit;
    }

    if ($action === 'add_server' && $is_admin) {
        $name = trim((string)($_POST['name'] ?? ''));
        $host = trim((string)($_POST['host'] ?? ''));
        $agent_key = trim((string)($_POST['agent_key'] ?? ''));
        $public_url = rtrim(trim((string)($_POST['public_url'] ?? '')), '/');
        $pma_alias = trim((string)($_POST['pma_alias'] ?? 'phpmyadmin'), '/');
        if ($name === '' || $host === '' || $agent_key === '' || !filter_var($public_url, FILTER_VALIDATE_URL) || !preg_match('/^[A-Za-z0-9_-]+$/', $pma_alias)) {
            flash('error', 'Provide valid node details.');
            header('Location: ?view=admin');
            exit;
        }
        $exists = $db->prepare("SELECT id FROM servers WHERE host = ? OR public_url = ?");
        $exists->execute([$host, $public_url]);
        if ($exists->fetchColumn()) {
            flash('error', 'That node is already registered.');
            header('Location: ?view=admin');
            exit;
        }
        $probe = call_agent(['agent_key' => $agent_key, 'public_url' => $public_url], ['action' => 'stats']);
        $last_seen = isset($probe['error']) ? null : date('Y-m-d H:i:s');
        $db->prepare("INSERT INTO servers (name, host, agent_key, public_url, pma_alias, last_seen) VALUES (?,?,?,?,?,?)")->execute([$name, $host, $agent_key, $public_url, $pma_alias, $last_seen]);
        flash(isset($probe['error']) ? 'error' : 'message', isset($probe['error']) ? 'Node saved, but the initial health check failed.' : 'Node linked and reachable.');
        header('Location: ?view=admin');
        exit;
    }

    if ($action === 'update_server' && $is_admin) {
        $server_id = (int)($_POST['server_id'] ?? 0);
        $name = trim((string)($_POST['name'] ?? ''));
        $host = trim((string)($_POST['host'] ?? ''));
        $agent_key = trim((string)($_POST['agent_key'] ?? ''));
        $public_url = rtrim(trim((string)($_POST['public_url'] ?? '')), '/');
        $pma_alias = trim((string)($_POST['pma_alias'] ?? 'phpmyadmin'), '/');
        if ($server_id < 1 || $name === '' || $host === '' || $agent_key === '' || !filter_var($public_url, FILTER_VALIDATE_URL) || !preg_match('/^[A-Za-z0-9_-]+$/', $pma_alias)) {
            flash('error', 'Provide valid node details.');
            header('Location: ?view=admin');
            exit;
        }
        $serverStmt = $db->prepare("SELECT * FROM servers WHERE id = ?");
        $serverStmt->execute([$server_id]);
        if (!$serverStmt->fetch(PDO::FETCH_ASSOC)) {
            flash('error', 'Node not found.');
            header('Location: ?view=admin');
            exit;
        }
        $exists = $db->prepare("SELECT id FROM servers WHERE id != ? AND (host = ? OR public_url = ?)");
        $exists->execute([$server_id, $host, $public_url]);
        if ($exists->fetchColumn()) {
            flash('error', 'Another node already uses that host or endpoint.');
            header('Location: ?view=admin');
            exit;
        }
        $probe = call_agent(['agent_key' => $agent_key, 'public_url' => $public_url], ['action' => 'stats']);
        $last_seen = isset($probe['error']) ? null : date('Y-m-d H:i:s');
        $db->prepare("UPDATE servers SET name = ?, host = ?, agent_key = ?, public_url = ?, pma_alias = ?, last_seen = ? WHERE id = ?")->execute([$name, $host, $agent_key, $public_url, $pma_alias, $last_seen, $server_id]);
        flash(isset($probe['error']) ? 'error' : 'message', isset($probe['error']) ? 'Node updated, but the health check failed.' : 'Node updated and reachable.');
        header('Location: ?view=admin');
        exit;
    }

    if ($action === 'delete_server' && $is_admin) {
        $server_id = (int)($_POST['server_id'] ?? 0);
        $assetStmt = $db->prepare("SELECT COUNT(*) FROM tenant_dbs WHERE server_id = ?");
        $assetStmt->execute([$server_id]);
        if ((int)$assetStmt->fetchColumn() > 0) {
            flash('error', 'Cannot delete a node that still has provisioned databases.');
            header('Location: ?view=admin');
            exit;
        }
        $db->prepare("DELETE FROM servers WHERE id = ?")->execute([$server_id]);
        flash('message', 'Node removed.');
        header('Location: ?view=admin');
        exit;
    }

    if ($action === 'create_client' && $is_admin) {
        $email = trim((string)($_POST['email'] ?? ''));
        $plainPassword = (string)($_POST['password'] ?? '');
        $pkg_id = (int)($_POST['package_id'] ?? 0);
        $status = normalise_client_status((string)($_POST['status'] ?? 'active'));
        $package = load_package($db, $pkg_id);
        if (!$package || !filter_var($email, FILTER_VALIDATE_EMAIL) || $plainPassword === '') {
            flash('error', 'Provide a valid email, password, and package.');
            header('Location: ?view=admin');
            exit;
        }
        try {
            $expiry = resolve_client_expiry($package, $status, (string)($_POST['expires_at'] ?? ''));
            $db->prepare("INSERT INTO clients (email, password_hash, package_id, expires_at, status) VALUES (?,?,?,?,?)")->execute([$email, password_hash($plainPassword, PASSWORD_DEFAULT), $pkg_id, $expiry, $status]);
            flash('message', 'Client account created.');
        } catch (InvalidArgumentException $e) {
            flash('error', $e->getMessage());
        } catch (Throwable $e) {
            flash('error', 'Client account already exists.');
        }
        header('Location: ?view=admin');
        exit;
    }

    if ($action === 'update_client' && $is_admin) {
        $client_target = (int)($_POST['client_id'] ?? 0);
        $email = trim((string)($_POST['email'] ?? ''));
        $plainPassword = (string)($_POST['password'] ?? '');
        $pkg_id = (int)($_POST['package_id'] ?? 0);
        $status = normalise_client_status((string)($_POST['status'] ?? 'active'));
        $package = load_package($db, $pkg_id);
        $clientStmt = $db->prepare("SELECT * FROM clients WHERE id = ?");
        $clientStmt->execute([$client_target]);
        if (!$clientStmt->fetch(PDO::FETCH_ASSOC) || !$package || !filter_var($email, FILTER_VALIDATE_EMAIL)) {
            flash('error', 'Provide valid client details.');
            header('Location: ?view=admin');
            exit;
        }
        try {
            $expiry = resolve_client_expiry($package, $status, (string)($_POST['expires_at'] ?? ''));
            if ($plainPassword !== '') {
                $db->prepare("UPDATE clients SET email = ?, password_hash = ?, package_id = ?, expires_at = ?, status = ? WHERE id = ?")->execute([$email, password_hash($plainPassword, PASSWORD_DEFAULT), $pkg_id, $expiry, $status, $client_target]);
            } else {
                $db->prepare("UPDATE clients SET email = ?, package_id = ?, expires_at = ?, status = ? WHERE id = ?")->execute([$email, $pkg_id, $expiry, $status, $client_target]);
            }
            flash('message', 'Client account updated.');
        } catch (InvalidArgumentException $e) {
            flash('error', $e->getMessage());
        } catch (Throwable $e) {
            flash('error', 'Unable to update the client account.');
        }
        header('Location: ?view=admin');
        exit;
    }

    if ($action === 'delete_client' && $is_admin) {
        $client_target = (int)($_POST['client_id'] ?? 0);
        $assetStmt = $db->prepare("SELECT COUNT(*) FROM tenant_dbs WHERE client_id = ?");
        $assetStmt->execute([$client_target]);
        if ((int)$assetStmt->fetchColumn() > 0) {
            flash('error', 'Cannot delete a client that still owns provisioned databases.');
            header('Location: ?view=admin');
            exit;
        }
        $db->prepare("DELETE FROM clients WHERE id = ?")->execute([$client_target]);
        flash('message', 'Client account removed.');
        header('Location: ?view=admin');
        exit;
    }

    if ($action === 'admin_provision' && $is_admin) {
        $result = provision_database_for_client($db, (int)($_POST['client_id'] ?? 0));
        if (!empty($result['download'])) $_SESSION['download'] = $result['download'];
        flash(isset($result['error']) ? 'error' : 'message', (string)($result['error'] ?? $result['message'] ?? 'Provision request completed.'));
        header('Location: ?view=admin');
        exit;
    }

    if ($action === 'backup_server' && $is_admin) {
        $result = queue_backup_for_server($db, (int)($_POST['server_id'] ?? 0));
        flash(isset($result['error']) ? 'error' : 'message', (string)($result['error'] ?? $result['message'] ?? 'Backup request completed.'));
        header('Location: ?view=admin');
        exit;
    }

    if ($action === 'backup_client' && $is_admin) {
        $result = queue_backup_for_client($db, (int)($_POST['client_id'] ?? 0));
        flash(isset($result['error']) ? 'error' : 'message', (string)($result['error'] ?? $result['message'] ?? 'Backup request completed.'));
        header('Location: ?view=admin');
        exit;
    }

    if ($action === 'provision' && $client_id) {
        $result = provision_database_for_client($db, (int)$client_id);
        if (!empty($result['download'])) $_SESSION['download'] = $result['download'];
        flash(isset($result['error']) ? 'error' : 'message', (string)($result['error'] ?? $result['message'] ?? 'Provision request completed.'));
        header('Location: ?view=client');
        exit;
    }

    if ($action === 'backup_db' && $client_id) {
        $result = queue_backup_for_database($db, (int)($_POST['tdb_id'] ?? 0), (int)$client_id);
        flash(isset($result['error']) ? 'error' : 'message', (string)($result['error'] ?? $result['message'] ?? 'Backup request completed.'));
        header('Location: ?view=client');
        exit;
    }

    if ($action === 'update_whitelist' && $client_id) {
        $tdb_stmt = $db->prepare("SELECT t.*, s.agent_key, s.public_url FROM tenant_dbs t JOIN servers s ON t.server_id = s.id WHERE t.id = ? AND t.client_id = ?");
        $tdb_stmt->execute([$_POST['tdb_id'], $client_id]); $tdb = $tdb_stmt->fetch(PDO::FETCH_ASSOC);
        if ($tdb) {
            $ips = array_values(array_filter(array_map('trim', explode(',', (string)($_POST['ips'] ?? '')))));
            if (!$ips) $ips = ['%'];
            $nodeRes = call_agent($tdb, ['action' => 'update_hosts', 'post_data' => ['db_user' => $tdb['db_user'], 'hosts' => json_encode($ips)]]);
            if (!isset($nodeRes['error'])) {
                $db->prepare("UPDATE tenant_dbs SET allowed_ips = ? WHERE id = ?")->execute([json_encode($ips), $tdb['id']]);
                flash('message', 'IP whitelist updated.');
            } else flash('error', (string)$nodeRes['error']);
        }
        header('Location: ?view=client');
        exit;
    }
}

if (isset($_GET['action']) && $_GET['action'] === 'logout') { session_destroy(); header('Location: ?'); exit; }

if (isset($_GET['download']) && ($client_id || $is_admin) && !empty($_SESSION['download'])) {
    $download = $_SESSION['download'];
    unset($_SESSION['download']);
    header('Content-Type: text/plain; charset=utf-8');
    header('Content-Disposition: attachment; filename="' . preg_replace('/[^A-Za-z0-9._-]/', '_', (string)($download['filename'] ?? 'database.env')) . '"');
    header('Cache-Control: no-store');
    echo (string)($download['content'] ?? '');
    exit;
}

$db = hub_db();
refresh_expired_clients($db);
$client = null; $client_db_count = 0; $client_usage_mb = 0.0;
if ($client_id) {
    sync_client_usage($db, $client_id);
    $clientStmt = $db->prepare("SELECT c.email, c.status, c.expires_at, p.name AS package_name, p.db_limit, p.disk_quota_gb, p.max_conns FROM clients c LEFT JOIN packages p ON c.package_id = p.id WHERE c.id = ?");
    $clientStmt->execute([$client_id]);
    $client = $clientStmt->fetch(PDO::FETCH_ASSOC) ?: null;
    $usageStmt = $db->prepare("SELECT COUNT(*), COALESCE(SUM(last_size_mb), 0) FROM tenant_dbs WHERE client_id = ?");
    $usageStmt->execute([$client_id]);
    $usageRow = $usageStmt->fetch(PDO::FETCH_NUM) ?: [0, 0];
    $client_db_count = (int)$usageRow[0];
    $client_usage_mb = (float)$usageRow[1];
}
$servers = $db->query("SELECT s.*, COUNT(t.id) AS db_count FROM servers s LEFT JOIN tenant_dbs t ON t.server_id = s.id GROUP BY s.id ORDER BY s.name")->fetchAll(PDO::FETCH_ASSOC);
$packages = $db->query("SELECT * FROM packages")->fetchAll(PDO::FETCH_ASSOC);
$admin_clients = $is_admin
    ? $db->query("SELECT c.*, p.name AS package_name, COUNT(t.id) AS db_count, COALESCE(SUM(t.last_size_mb), 0) AS usage_mb FROM clients c LEFT JOIN packages p ON p.id = c.package_id LEFT JOIN tenant_dbs t ON t.client_id = c.id GROUP BY c.id ORDER BY c.id DESC")->fetchAll(PDO::FETCH_ASSOC)
    : [];
$message = consume_flash('message');
$error = consume_flash('error');

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
            <div class="max-w-3xl mx-auto space-y-4 mb-12"><?= alert_html($message) ?><?= alert_html($error, 'error') ?></div>
            <h1 class="text-[7rem] leading-none font-black text-white tracking-tight mb-8">Hardened<br><span class="text-indigo-500">Fleet.</span></h1>
            <p class="text-xl max-w-2xl mx-auto mb-24 font-medium text-slate-500">Autonomous MariaDB infrastructure with real-time brute-force resistance, isolation, and cloud snapshots.</p>
            <div id="tiers" class="grid grid-cols-1 md:grid-cols-3 gap-10 text-left">
                <?php foreach($packages as $p): ?>
                <div class="bg-slate-900/50 backdrop-blur-xl border border-white/5 p-12 rounded-[3.5rem] hover:border-indigo-500/40 transition-all shadow-2xl group">
                    <h3 class="text-indigo-400 font-black uppercase tracking-[0.4em] text-[9px] mb-8"><?= e($p['name']) ?></h3>
                    <div class="text-5xl font-black text-white mb-12 tracking-tighter group-hover:scale-105 transition-transform"><?= e(PAYSTACK_CURRENCY) ?> <?= number_format((float)$p['price'], 2) ?><span class="text-sm font-normal text-slate-700 ml-2">/cycle</span></div>
                    <ul class="space-y-6 mb-16 text-sm font-bold text-slate-500">
                        <li><i class="fa-solid fa-circle-check text-indigo-500 mr-3"></i> <?= $p['db_limit'] ?> Active Databases</li>
                        <li><i class="fa-solid fa-circle-check text-indigo-500 mr-3"></i> <?= $p['disk_quota_gb'] ?>GB NVMe Storage</li>
                        <li><i class="fa-solid fa-circle-check text-indigo-500 mr-3"></i> <?= $p['max_conns'] ?> Max User Connections</li>
                    </ul>
                    <a href="?view=signup&pkg=<?= $p['id'] ?>" class="block text-center bg-slate-800 text-white py-6 rounded-3xl font-black text-[10px] uppercase tracking-widest hover:bg-indigo-600 transition-all shadow-xl">Create Account</a>
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
            <div class="space-y-4 mb-8 text-left"><?= alert_html($message) ?><?= alert_html($error, 'error') ?></div>
            <div class="space-y-8 text-left">
                <div><label class="text-[9px] font-black text-slate-500 uppercase tracking-widest ml-1 mb-2 block">Identity</label>
                <input type="text" name="email" placeholder="Admin or client email" class="w-full bg-slate-950/50 border-white/5 rounded-2xl p-5 text-white focus:ring-indigo-500 text-xs font-bold tracking-widest" required autofocus></div>
                <div><label class="text-[9px] font-black text-slate-500 uppercase tracking-widest ml-1 mb-2 block">Security Token</label>
                <input type="password" name="password" placeholder="Enter password" class="w-full bg-slate-950/50 border-white/5 rounded-2xl p-5 text-white focus:ring-indigo-500 text-xs font-bold tracking-widest" required></div>
                <button class="w-full bg-indigo-600 py-6 rounded-3xl text-white font-black uppercase tracking-widest text-[10px] shadow-2xl shadow-indigo-500/20 hover:bg-indigo-500 transition-all">Unlock Environment</button>
            </div>
        </form>
    </div>

<?php elseif ($view === 'signup'): ?>
    <div class="flex items-center justify-center min-h-screen bg-slate-950">
        <form method="post" class="bg-slate-900/50 backdrop-blur-2xl p-16 rounded-[4rem] border border-white/5 w-full max-w-md shadow-2xl">
            <input type="hidden" name="action" value="signup"><input type="hidden" name="csrf" value="<?= csrf_token() ?>">
            <input type="hidden" name="package_id" value="<?= (int)($_GET['pkg'] ?? 1) ?>">
            <h2 class="text-3xl font-black text-white mb-10 tracking-tighter text-center uppercase">Create Tenant Account</h2>
            <div class="space-y-4 mb-8"><?= alert_html($message) ?><?= alert_html($error, 'error') ?></div>
            <div class="space-y-8">
                <input type="email" name="email" placeholder="name@example.com" class="w-full bg-slate-950/50 border-white/5 rounded-2xl p-5 text-white focus:ring-indigo-500 text-xs font-bold tracking-widest" required autofocus>
                <input type="password" name="password" placeholder="Choose a secure password" class="w-full bg-slate-950/50 border-white/5 rounded-2xl p-5 text-white focus:ring-indigo-500 text-xs font-bold tracking-widest" required>
                <button class="w-full bg-indigo-600 py-6 rounded-3xl text-white font-black uppercase tracking-widest text-[10px] shadow-2xl shadow-indigo-500/20 hover:bg-indigo-500 transition-all"><?= paystack_enabled() ? 'Continue To Billing' : 'Generate Account' ?></button>
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
        <div class="space-y-4"><?= alert_html($message) ?><?= alert_html($error, 'error') ?></div>
        <?php if (!empty($_SESSION['download'])): ?>
        <div class="bg-indigo-600 p-10 rounded-[3rem] shadow-2xl flex items-center justify-between">
            <div><h3 class="text-white font-black text-xl tracking-tighter uppercase">Vault Ready</h3><p class="text-indigo-200 text-[10px] font-black uppercase tracking-widest">Security environment file generated</p></div>
            <a href="?download=1" class="bg-white text-indigo-600 px-10 py-4 rounded-2xl font-black text-[10px] uppercase tracking-widest shadow-xl">Retrieve .env</a>
        </div>
        <?php endif; ?>
        <?php if ($client): ?>
        <div class="grid grid-cols-1 md:grid-cols-4 gap-6">
            <div class="bg-slate-900/50 border border-white/5 p-8 rounded-[2.5rem]"><div class="text-[10px] font-black uppercase tracking-widest text-slate-500 mb-4">Plan</div><div class="text-2xl font-black text-white"><?= e((string)$client['package_name']) ?></div></div>
            <div class="bg-slate-900/50 border border-white/5 p-8 rounded-[2.5rem]"><div class="text-[10px] font-black uppercase tracking-widest text-slate-500 mb-4">Databases</div><div class="text-2xl font-black text-white"><?= $client_db_count ?> / <?= (int)$client['db_limit'] ?></div></div>
            <div class="bg-slate-900/50 border border-white/5 p-8 rounded-[2.5rem]"><div class="text-[10px] font-black uppercase tracking-widest text-slate-500 mb-4">Storage Used</div><div class="text-2xl font-black text-white"><?= number_format($client_usage_mb / 1024, 2) ?>GB / <?= (int)$client['disk_quota_gb'] ?>GB</div></div>
            <div class="bg-slate-900/50 border border-white/5 p-8 rounded-[2.5rem]"><div class="text-[10px] font-black uppercase tracking-widest text-slate-500 mb-4">Expires</div><div class="text-2xl font-black text-white"><?= e((string)($client['expires_at'] ?: 'N/A')) ?></div></div>
        </div>
        <?php endif; ?>
        <div class="flex items-center justify-between">
            <div><h2 class="text-5xl font-black text-white tracking-tighter">Your Cluster</h2><p class="text-slate-500 font-bold uppercase tracking-widest text-[10px] mt-2">Active Database Inventory</p></div>
            <form method="post"><input type="hidden" name="csrf" value="<?= csrf_token() ?>"><input type="hidden" name="action" value="provision">
            <button class="bg-indigo-600 text-white px-12 py-5 rounded-3xl font-black text-[10px] uppercase tracking-widest shadow-2xl shadow-indigo-500/30 hover:scale-105 transition-all">Provision Instance</button></form>
        </div>
        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-10">
            <?php 
            $dbs = $db->prepare("SELECT t.*, s.public_url, s.pma_alias, s.name as server_name FROM tenant_dbs t JOIN servers s ON t.server_id = s.id WHERE t.client_id = ?"); $dbs->execute([$client_id]);
            foreach($dbs->fetchAll(PDO::FETCH_ASSOC) as $row): ?>
            <div class="bg-slate-900/50 border border-white/5 p-10 rounded-[3rem] shadow-xl group hover:border-indigo-500/30 transition-all text-left">
                <div class="flex items-center justify-between mb-8"><div class="bg-slate-800 p-4 rounded-3xl"><i class="fa-solid fa-database text-indigo-500 text-2xl"></i></div><span class="text-[10px] font-black text-emerald-500 uppercase tracking-widest flex items-center"><span class="w-2 h-2 bg-emerald-500 rounded-full mr-2 animate-ping"></span>Linked</span></div>
                <h3 class="text-2xl font-black text-white mb-2 tracking-tight"><?= e($row['db_name']) ?></h3>
                <p class="text-slate-600 text-[10px] font-black uppercase tracking-widest mb-3">Node: <span class="text-indigo-400"><?= e($row['server_name']) ?></span></p>
                <p class="text-slate-600 text-[10px] font-black uppercase tracking-widest mb-10">Usage: <span class="text-white"><?= number_format((float)$row['last_size_mb'], 2) ?>MB</span></p>
                <div class="grid grid-cols-1 gap-4">
                    <a href="<?= rtrim((string)$row['public_url'], '/') ?>/<?= e(trim((string)($row['pma_alias'] ?: 'phpmyadmin'), '/')) ?>" target="_blank" class="bg-slate-800 text-center py-4 rounded-2xl text-[10px] font-black uppercase tracking-widest hover:bg-slate-700 transition-all">Admin Gateway</a>
                    <form method="post">
                        <input type="hidden" name="csrf" value="<?= csrf_token() ?>">
                        <input type="hidden" name="action" value="backup_db">
                        <input type="hidden" name="tdb_id" value="<?= (int)$row['id'] ?>">
                        <button class="w-full bg-emerald-600 text-white text-center py-4 rounded-2xl text-[10px] font-black uppercase tracking-widest hover:bg-emerald-500 transition-all">Create Backup</button>
                    </form>
                    <button onclick="document.getElementById('modal-ips-<?= $row['id'] ?>').classList.remove('hidden')" class="border border-indigo-500/20 text-indigo-400 text-center py-4 rounded-2xl text-[10px] font-black uppercase tracking-widest hover:bg-indigo-600 hover:text-white transition-all">Node Guard</button>
                </div>
            </div>
            <div id="modal-ips-<?= $row['id'] ?>" class="hidden fixed inset-0 bg-slate-950/90 backdrop-blur-xl flex items-center justify-center p-8 z-50 text-left">
                <form method="post" class="bg-slate-900 p-12 rounded-[3rem] border border-white/5 w-full max-w-lg shadow-2xl">
                    <input type="hidden" name="action" value="update_whitelist"><input type="hidden" name="csrf" value="<?= csrf_token() ?>"><input type="hidden" name="tdb_id" value="<?= $row['id'] ?>">
                    <h2 class="text-2xl font-black text-white mb-4 tracking-tighter uppercase text-center">Identity Firewall</h2>
                    <p class="text-xs text-slate-500 mb-10 font-bold uppercase tracking-widest text-center italic">Restrict database access to specific IP origins</p>
                    <textarea name="ips" class="w-full bg-slate-950 border-white/5 rounded-2xl p-6 text-white font-mono text-sm mb-10 focus:ring-indigo-500" rows="3" placeholder="127.0.0.1, 203.0.113.10 or %"><?= implode(',', json_decode($row['allowed_ips'], true) ?: ['%']) ?></textarea>
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
        <div class="space-y-4"><?= alert_html($message) ?><?= alert_html($error, 'error') ?></div>
        <?php if (!empty($_SESSION['download'])): ?>
        <div class="bg-indigo-600 p-10 rounded-[3rem] shadow-2xl flex items-center justify-between">
            <div><h3 class="text-white font-black text-xl tracking-tighter uppercase">Provision Vault Ready</h3><p class="text-indigo-200 text-[10px] font-black uppercase tracking-widest">Latest generated tenant environment file is ready for download</p></div>
            <a href="?download=1" class="bg-white text-indigo-600 px-10 py-4 rounded-2xl font-black text-[10px] uppercase tracking-widest shadow-xl">Retrieve .env</a>
        </div>
        <?php endif; ?>
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
                <thead class="bg-white/5"><tr><th class="px-10 py-6 text-left text-[10px] font-black text-slate-500 uppercase tracking-widest">Node Identifier</th><th class="px-10 py-6 text-left text-[10px] font-black text-slate-500 uppercase tracking-widest">Database Host / IP</th><th class="px-10 py-6 text-left text-[10px] font-black text-slate-500 uppercase tracking-widest">Public Endpoint</th><th class="px-10 py-6 text-left text-[10px] font-black text-slate-500 uppercase tracking-widest">phpMyAdmin Alias</th><th class="px-10 py-6 text-left text-[10px] font-black text-slate-500 uppercase tracking-widest">Assets</th><th class="px-10 py-6 text-center text-[10px] font-black text-slate-500 uppercase tracking-widest">Operational Status</th><th class="px-10 py-6 text-right text-[10px] font-black text-slate-500 uppercase tracking-widest">Actions</th></tr></thead>
                <tbody class="divide-y divide-white/5"><?php if (!$servers): ?>
                    <tr><td colspan="7" class="px-10 py-12 text-center text-sm font-bold text-slate-500">No nodes linked yet.</td></tr>
                <?php else: foreach($servers as $s): $lastSeen = strtotime((string)($s['last_seen'] ?? '')); $healthy = $lastSeen !== false && (time() - $lastSeen < 600); $serverDeleteDisabled = (int)$s['db_count'] > 0; $serverBackupDisabled = !$healthy; ?>
                    <tr><td class="px-10 py-8 font-black text-white text-lg tracking-tight"><?= e($s['name']) ?></td>
                        <td class="px-10 py-8 text-xs font-bold font-mono text-slate-500"><?= e($s['host']) ?></td>
                        <td class="px-10 py-8 text-xs font-bold font-mono text-slate-500"><?= e($s['public_url']) ?></td>
                        <td class="px-10 py-8 text-xs font-bold font-mono text-slate-500"><?= e((string)($s['pma_alias'] ?: 'phpmyadmin')) ?></td>
                        <td class="px-10 py-8 text-xs font-bold text-slate-500 uppercase"><?= (int)$s['db_count'] ?> databases</td>
                        <td class="px-10 py-8 text-center"><span class="text-[10px] font-black uppercase tracking-widest <?= $healthy ? 'text-emerald-500' : 'text-red-500' ?>"><?= $healthy ? '&bull; Healthy' : '&bull; Sync Error' ?></span></td>
                        <td class="px-10 py-8"><div class="flex items-center justify-end gap-3">
                            <form method="post">
                                <input type="hidden" name="csrf" value="<?= csrf_token() ?>">
                                <input type="hidden" name="action" value="backup_server">
                                <input type="hidden" name="server_id" value="<?= (int)$s['id'] ?>">
                                <button class="<?= $serverBackupDisabled ? 'bg-slate-800 text-slate-600 cursor-not-allowed' : 'bg-emerald-600 text-white hover:bg-emerald-500' ?> px-5 py-3 rounded-2xl text-[10px] font-black uppercase tracking-widest transition-all" <?= $serverBackupDisabled ? 'disabled' : '' ?>>Backup</button>
                            </form>
                            <button type="button" onclick="document.getElementById('modal-server-<?= $s['id'] ?>').classList.remove('hidden')" class="bg-white/5 text-white px-5 py-3 rounded-2xl text-[10px] font-black uppercase tracking-widest hover:bg-white/10 transition-all">Edit</button>
                            <form method="post" onsubmit="return confirm('Remove this node from the hub?');">
                                <input type="hidden" name="csrf" value="<?= csrf_token() ?>">
                                <input type="hidden" name="action" value="delete_server">
                                <input type="hidden" name="server_id" value="<?= (int)$s['id'] ?>">
                                <button class="<?= $serverDeleteDisabled ? 'bg-slate-800 text-slate-600 cursor-not-allowed' : 'bg-red-500/10 text-red-300 hover:bg-red-500 hover:text-white' ?> px-5 py-3 rounded-2xl text-[10px] font-black uppercase tracking-widest transition-all" <?= $serverDeleteDisabled ? 'disabled' : '' ?>>Delete</button>
                            </form>
                        </div></td></tr><?php endforeach; endif; ?>
                </tbody>
            </table>
        </div>
        <div class="flex items-center justify-between border-t border-white/5 pt-16">
            <h2 class="text-3xl font-black text-white tracking-tighter uppercase">Tenant Accounts</h2>
            <button onclick="document.getElementById('modal-client-add').classList.remove('hidden')" class="bg-emerald-600 text-white px-10 py-4 rounded-2xl font-black text-[10px] uppercase tracking-widest shadow-xl shadow-emerald-500/20">Create Tenant</button>
        </div>
        <div class="bg-slate-900 rounded-[3rem] border border-white/5 overflow-hidden shadow-2xl">
            <table class="min-w-full divide-y divide-white/5 text-left">
                <thead class="bg-white/5"><tr><th class="px-10 py-6 text-left text-[10px] font-black text-slate-500 uppercase tracking-widest">Identity</th><th class="px-10 py-6 text-left text-[10px] font-black text-slate-500 uppercase tracking-widest">Package</th><th class="px-10 py-6 text-left text-[10px] font-black text-slate-500 uppercase tracking-widest">Status</th><th class="px-10 py-6 text-left text-[10px] font-black text-slate-500 uppercase tracking-widest">Expires</th><th class="px-10 py-6 text-left text-[10px] font-black text-slate-500 uppercase tracking-widest">Databases</th><th class="px-10 py-6 text-left text-[10px] font-black text-slate-500 uppercase tracking-widest">Storage</th><th class="px-10 py-6 text-right text-[10px] font-black text-slate-500 uppercase tracking-widest">Actions</th></tr></thead>
                <tbody class="divide-y divide-white/5"><?php if (!$admin_clients): ?>
                    <tr><td colspan="7" class="px-10 py-12 text-center text-sm font-bold text-slate-500">No tenant accounts created yet.</td></tr>
                <?php else: foreach($admin_clients as $adminClient): $clientDeleteDisabled = (int)$adminClient['db_count'] > 0; $clientHealthy = is_client_active($adminClient); $clientBackupDisabled = (int)$adminClient['db_count'] < 1; $statusClass = ($adminClient['status'] ?? '') === 'active' ? 'text-emerald-400' : (($adminClient['status'] ?? '') === 'pending' ? 'text-amber-400' : 'text-red-400'); ?>
                    <tr><td class="px-10 py-8"><div class="font-black text-white text-lg tracking-tight"><?= e($adminClient['email']) ?></div><div class="text-[10px] font-black uppercase tracking-widest text-slate-600">Client #<?= (int)$adminClient['id'] ?></div></td>
                        <td class="px-10 py-8 text-xs font-bold text-slate-400 uppercase"><?= e((string)($adminClient['package_name'] ?: 'Unassigned')) ?></td>
                        <td class="px-10 py-8"><span class="text-[10px] font-black uppercase tracking-widest <?= $statusClass ?>"><?= e((string)$adminClient['status']) ?></span></td>
                        <td class="px-10 py-8 text-xs font-bold text-slate-400"><?= e((string)($adminClient['expires_at'] ?: 'Not scheduled')) ?></td>
                        <td class="px-10 py-8 text-xs font-bold text-slate-400 uppercase"><?= (int)$adminClient['db_count'] ?> in use</td>
                        <td class="px-10 py-8 text-xs font-bold text-slate-400 uppercase"><?= number_format(((float)$adminClient['usage_mb']) / 1024, 2) ?>GB</td>
                        <td class="px-10 py-8"><div class="flex items-center justify-end gap-3">
                            <form method="post">
                                <input type="hidden" name="csrf" value="<?= csrf_token() ?>">
                                <input type="hidden" name="action" value="admin_provision">
                                <input type="hidden" name="client_id" value="<?= (int)$adminClient['id'] ?>">
                                <button class="<?= $clientHealthy ? 'bg-indigo-600 text-white hover:bg-indigo-500' : 'bg-slate-800 text-slate-600 cursor-not-allowed' ?> px-5 py-3 rounded-2xl text-[10px] font-black uppercase tracking-widest transition-all" <?= $clientHealthy ? '' : 'disabled' ?>>Provision</button>
                            </form>
                            <form method="post">
                                <input type="hidden" name="csrf" value="<?= csrf_token() ?>">
                                <input type="hidden" name="action" value="backup_client">
                                <input type="hidden" name="client_id" value="<?= (int)$adminClient['id'] ?>">
                                <button class="<?= $clientBackupDisabled ? 'bg-slate-800 text-slate-600 cursor-not-allowed' : 'bg-emerald-600 text-white hover:bg-emerald-500' ?> px-5 py-3 rounded-2xl text-[10px] font-black uppercase tracking-widest transition-all" <?= $clientBackupDisabled ? 'disabled' : '' ?>>Backup</button>
                            </form>
                            <button type="button" onclick="document.getElementById('modal-client-<?= $adminClient['id'] ?>').classList.remove('hidden')" class="bg-white/5 text-white px-5 py-3 rounded-2xl text-[10px] font-black uppercase tracking-widest hover:bg-white/10 transition-all">Edit</button>
                            <form method="post" onsubmit="return confirm('Delete this client account?');">
                                <input type="hidden" name="csrf" value="<?= csrf_token() ?>">
                                <input type="hidden" name="action" value="delete_client">
                                <input type="hidden" name="client_id" value="<?= (int)$adminClient['id'] ?>">
                                <button class="<?= $clientDeleteDisabled ? 'bg-slate-800 text-slate-600 cursor-not-allowed' : 'bg-red-500/10 text-red-300 hover:bg-red-500 hover:text-white' ?> px-5 py-3 rounded-2xl text-[10px] font-black uppercase tracking-widest transition-all" <?= $clientDeleteDisabled ? 'disabled' : '' ?>>Delete</button>
                            </form>
                        </div></td></tr><?php endforeach; endif; ?>
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
            <input type="text" name="name" placeholder="Node label" class="w-full bg-slate-950/50 border-white/5 rounded-2xl p-5 text-white text-xs font-bold tracking-widest" required>
            <input type="text" name="host" placeholder="Database host or IP" class="w-full bg-slate-950/50 border-white/5 rounded-2xl p-5 text-white text-xs font-bold tracking-widest" required>
            <input type="password" name="agent_key" placeholder="Agent access token" class="w-full bg-slate-950/50 border-white/5 rounded-2xl p-5 text-white text-xs font-bold tracking-widest" required>
            <input type="text" name="public_url" placeholder="Public endpoint (http or https)" class="w-full bg-slate-950/50 border-white/5 rounded-2xl p-5 text-white text-xs font-bold tracking-widest" required>
            <input type="text" name="pma_alias" value="phpmyadmin" placeholder="phpMyAdmin alias" class="w-full bg-slate-950/50 border-white/5 rounded-2xl p-5 text-white text-xs font-bold tracking-widest" required>
            <div class="flex justify-end space-x-6 pt-6"><button type="button" onclick="this.closest('#modal-add').classList.add('hidden')" class="text-slate-600 font-black uppercase text-[10px] tracking-widest">Abort</button>
            <button class="bg-indigo-600 text-white px-10 py-4 rounded-2xl font-black uppercase text-[10px] shadow-xl">Commit Node</button></div>
        </div>
    </form></div>

<?php foreach($servers as $s): ?>
<div id="modal-server-<?= $s['id'] ?>" class="hidden fixed inset-0 bg-slate-950/90 backdrop-blur-xl flex items-center justify-center p-8 z-50 text-left">
    <form method="post" class="bg-slate-900 p-12 rounded-[4rem] border border-white/5 w-full max-w-lg shadow-2xl">
        <input type="hidden" name="action" value="update_server"><input type="hidden" name="csrf" value="<?= csrf_token() ?>"><input type="hidden" name="server_id" value="<?= (int)$s['id'] ?>">
        <h2 class="text-3xl font-black text-white mb-10 tracking-tighter text-center uppercase">Edit Remote Node</h2>
        <div class="space-y-6">
            <input type="text" name="name" value="<?= e($s['name']) ?>" placeholder="Node label" class="w-full bg-slate-950/50 border-white/5 rounded-2xl p-5 text-white text-xs font-bold tracking-widest" required>
            <input type="text" name="host" value="<?= e($s['host']) ?>" placeholder="Database host or IP" class="w-full bg-slate-950/50 border-white/5 rounded-2xl p-5 text-white text-xs font-bold tracking-widest" required>
            <input type="text" name="agent_key" value="<?= e($s['agent_key']) ?>" placeholder="Agent access token" class="w-full bg-slate-950/50 border-white/5 rounded-2xl p-5 text-white text-xs font-bold tracking-widest" required>
            <input type="text" name="public_url" value="<?= e($s['public_url']) ?>" placeholder="Public endpoint (http or https)" class="w-full bg-slate-950/50 border-white/5 rounded-2xl p-5 text-white text-xs font-bold tracking-widest" required>
            <input type="text" name="pma_alias" value="<?= e((string)($s['pma_alias'] ?: 'phpmyadmin')) ?>" placeholder="phpMyAdmin alias" class="w-full bg-slate-950/50 border-white/5 rounded-2xl p-5 text-white text-xs font-bold tracking-widest" required>
            <p class="text-[10px] font-black uppercase tracking-widest text-slate-600">Attached Databases: <?= (int)$s['db_count'] ?></p>
            <div class="flex justify-end space-x-6 pt-6"><button type="button" onclick="this.closest('[id^=modal-server]').classList.add('hidden')" class="text-slate-600 font-black uppercase text-[10px] tracking-widest">Cancel</button>
            <button class="bg-indigo-600 text-white px-10 py-4 rounded-2xl font-black uppercase text-[10px] shadow-xl">Save Node</button></div>
        </div>
    </form>
</div>
<?php endforeach; ?>

<div id="modal-client-add" class="hidden fixed inset-0 bg-slate-950/90 backdrop-blur-xl flex items-center justify-center p-8 z-50 text-left">
    <form method="post" class="bg-slate-900 p-12 rounded-[4rem] border border-white/5 w-full max-w-lg shadow-2xl">
        <input type="hidden" name="action" value="create_client"><input type="hidden" name="csrf" value="<?= csrf_token() ?>">
        <h2 class="text-3xl font-black text-white mb-10 tracking-tighter text-center uppercase">Create Tenant Account</h2>
        <div class="space-y-6">
            <input type="email" name="email" placeholder="tenant@example.com" class="w-full bg-slate-950/50 border-white/5 rounded-2xl p-5 text-white text-xs font-bold tracking-widest" required>
            <input type="password" name="password" placeholder="Initial password" class="w-full bg-slate-950/50 border-white/5 rounded-2xl p-5 text-white text-xs font-bold tracking-widest" required>
            <select name="package_id" class="w-full bg-slate-950/50 border-white/5 rounded-2xl p-5 text-white text-xs font-bold tracking-widest" required>
                <?php foreach($packages as $pkg): ?><option value="<?= (int)$pkg['id'] ?>"><?= e($pkg['name']) ?> - <?= (int)$pkg['db_limit'] ?> DB</option><?php endforeach; ?>
            </select>
            <select name="status" class="w-full bg-slate-950/50 border-white/5 rounded-2xl p-5 text-white text-xs font-bold tracking-widest">
                <option value="active">Active</option>
                <option value="pending">Pending</option>
                <option value="expired">Expired</option>
            </select>
            <input type="datetime-local" name="expires_at" class="w-full bg-slate-950/50 border-white/5 rounded-2xl p-5 text-white text-xs font-bold tracking-widest">
            <p class="text-[10px] font-black uppercase tracking-widest text-slate-600">Leave expiry empty to auto-calculate it from the selected status and package.</p>
            <div class="flex justify-end space-x-6 pt-6"><button type="button" onclick="this.closest('#modal-client-add').classList.add('hidden')" class="text-slate-600 font-black uppercase text-[10px] tracking-widest">Cancel</button>
            <button class="bg-emerald-600 text-white px-10 py-4 rounded-2xl font-black uppercase text-[10px] shadow-xl">Create Client</button></div>
        </div>
    </form>
</div>

<?php foreach($admin_clients as $adminClient): ?>
<div id="modal-client-<?= $adminClient['id'] ?>" class="hidden fixed inset-0 bg-slate-950/90 backdrop-blur-xl flex items-center justify-center p-8 z-50 text-left">
    <form method="post" class="bg-slate-900 p-12 rounded-[4rem] border border-white/5 w-full max-w-lg shadow-2xl">
        <input type="hidden" name="action" value="update_client"><input type="hidden" name="csrf" value="<?= csrf_token() ?>"><input type="hidden" name="client_id" value="<?= (int)$adminClient['id'] ?>">
        <h2 class="text-3xl font-black text-white mb-10 tracking-tighter text-center uppercase">Edit Tenant Account</h2>
        <div class="space-y-6">
            <input type="email" name="email" value="<?= e($adminClient['email']) ?>" placeholder="tenant@example.com" class="w-full bg-slate-950/50 border-white/5 rounded-2xl p-5 text-white text-xs font-bold tracking-widest" required>
            <input type="password" name="password" placeholder="New password (optional)" class="w-full bg-slate-950/50 border-white/5 rounded-2xl p-5 text-white text-xs font-bold tracking-widest">
            <select name="package_id" class="w-full bg-slate-950/50 border-white/5 rounded-2xl p-5 text-white text-xs font-bold tracking-widest" required>
                <?php foreach($packages as $pkg): ?><option value="<?= (int)$pkg['id'] ?>" <?= (int)$pkg['id'] === (int)$adminClient['package_id'] ? 'selected' : '' ?>><?= e($pkg['name']) ?> - <?= (int)$pkg['db_limit'] ?> DB</option><?php endforeach; ?>
            </select>
            <select name="status" class="w-full bg-slate-950/50 border-white/5 rounded-2xl p-5 text-white text-xs font-bold tracking-widest">
                <option value="active" <?= ($adminClient['status'] ?? '') === 'active' ? 'selected' : '' ?>>Active</option>
                <option value="pending" <?= ($adminClient['status'] ?? '') === 'pending' ? 'selected' : '' ?>>Pending</option>
                <option value="expired" <?= ($adminClient['status'] ?? '') === 'expired' ? 'selected' : '' ?>>Expired</option>
            </select>
            <input type="datetime-local" name="expires_at" value="<?= e(datetime_local_value($adminClient['expires_at'] ?? null)) ?>" class="w-full bg-slate-950/50 border-white/5 rounded-2xl p-5 text-white text-xs font-bold tracking-widest">
            <p class="text-[10px] font-black uppercase tracking-widest text-slate-600">Leave password empty to keep the existing password hash unchanged.</p>
            <div class="flex justify-end space-x-6 pt-6"><button type="button" onclick="this.closest('[id^=modal-client]').classList.add('hidden')" class="text-slate-600 font-black uppercase text-[10px] tracking-widest">Cancel</button>
            <button class="bg-emerald-600 text-white px-10 py-4 rounded-2xl font-black uppercase text-[10px] shadow-xl">Save Client</button></div>
        </div>
    </form>
</div>
<?php endforeach; ?>

<footer class="text-center py-32 text-[10px] font-black text-slate-800 uppercase tracking-[1em]">Shield Infrastructure &bull; Version 5.0 Core</footer>
</body></html>
PHPHUB

  sed -i "s|__HUB_USER__|$(sed_escape "$HUB_ADMIN_USER")|g" "$HUB_ROOT/index.php"
  sed -i "s|__HUB_HASH__|$(sed_escape "$HUB_ADMIN_HASH")|g" "$HUB_ROOT/index.php"
  sed -i "s|__ADMIN_EMAIL__|$(sed_escape "$ADMIN_EMAIL")|g" "$HUB_ROOT/index.php"
  sed -i "s|__CSRF_SECRET__|$(sed_escape "$CSRF_SECRET")|g" "$HUB_ROOT/index.php"
  sed -i "s|__PAYSTACK_SECRET__|$(sed_escape "$PAYSTACK_SECRET")|g" "$HUB_ROOT/index.php"
  sed -i "s|__PAYSTACK_CURRENCY__|$(sed_escape "$PAYSTACK_CURRENCY")|g" "$HUB_ROOT/index.php"
  sed -i "s|__SMTP_HOST__|$(sed_escape "$SMTP_HOST")|g" "$HUB_ROOT/index.php"
  sed -i "s|__SMTP_PORT__|$(sed_escape "$SMTP_PORT")|g" "$HUB_ROOT/index.php"
  sed -i "s|__SMTP_USER__|$(sed_escape "$SMTP_USER")|g" "$HUB_ROOT/index.php"
  sed -i "s|__SMTP_PASS__|$(sed_escape "$SMTP_PASS")|g" "$HUB_ROOT/index.php"
  sed -i "s|__SMTP_FROM__|$(sed_escape "$SMTP_FROM")|g" "$HUB_ROOT/index.php"

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
  (crontab -l 2>/dev/null || true; echo "*/10 * * * * curl -fsS http://localhost/${HUB_ALIAS}/index.php?action=watchdog >/dev/null 2>&1") | crontab -
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
Admin Alerts: ${ADMIN_EMAIL:-disabled}
Billing Currency: ${PAYSTACK_CURRENCY}
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
