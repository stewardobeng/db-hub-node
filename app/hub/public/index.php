<?php
declare(strict_types=1);

require dirname(__DIR__) . DIRECTORY_SEPARATOR . 'bootstrap.php';

session_start();

header("X-Frame-Options: DENY");
header("X-Content-Type-Options: nosniff");
header("Referrer-Policy: no-referrer");
header("Content-Security-Policy: default-src 'self' https://cdn.tailwindcss.com https://fonts.googleapis.com https://fonts.gstatic.com; script-src 'self' 'unsafe-inline' https://cdn.tailwindcss.com; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com data:;");

function e(string $value): string {
    return htmlspecialchars($value, ENT_QUOTES, 'UTF-8');
}

function flash(string $key, string $message): void {
    $_SESSION[$key] = $message;
}

function consume_flash(string $key): string {
    $value = (string)($_SESSION[$key] ?? '');
    unset($_SESSION[$key]);
    return $value;
}

function client_ip(): string {
    return $_SERVER['REMOTE_ADDR'] ?? '0.0.0.0';
}

function csrf_token(): string {
    if (empty($_SESSION['csrf'])) {
        $_SESSION['csrf'] = hash_hmac('sha256', session_id(), APP_SECRET);
    }
    return (string)$_SESSION['csrf'];
}

function require_csrf(): void {
    if (!hash_equals(csrf_token(), (string)($_POST['csrf'] ?? ''))) {
        throw new RuntimeException('Security violation.');
    }
}

function page_url(string $view, array $params = []): string {
    return '?' . http_build_query(array_merge(['view' => $view], $params));
}

function app_url(array $query = []): string {
    $scheme = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off') ? 'https' : 'http';
    $host = $_SERVER['HTTP_HOST'] ?? 'localhost';
    $path = strtok($_SERVER['REQUEST_URI'] ?? '/index.php', '?') ?: '/index.php';
    return $scheme . '://' . $host . $path . ($query ? '?' . http_build_query($query) : '');
}

function format_money(float $amount): string {
    return PAYSTACK_CURRENCY . ' ' . number_format($amount, 2);
}

function format_datetime(?string $value): string {
    if (!$value) {
        return 'Not scheduled';
    }
    $ts = strtotime($value);
    return $ts === false ? 'Not scheduled' : date('M j, Y g:i A', $ts);
}

function datetime_local_value(?string $value): string {
    if (!$value) {
        return '';
    }
    $ts = strtotime($value);
    return $ts === false ? '' : date('Y-m-d\TH:i', $ts);
}

function relative_time(?string $value): string {
    if (!$value) {
        return 'Never';
    }
    $ts = strtotime($value);
    if ($ts === false) {
        return 'Unknown';
    }
    $diff = time() - $ts;
    if ($diff < 60) {
        return 'Just now';
    }
    if ($diff < 3600) {
        return floor($diff / 60) . ' mins ago';
    }
    if ($diff < 86400) {
        return floor($diff / 3600) . ' hrs ago';
    }
    if ($diff < 2592000) {
        return floor($diff / 86400) . ' days ago';
    }
    return date('M j, Y', $ts);
}

function format_storage_mb(float $mb): string {
    if ($mb >= 1024 * 1024) {
        return number_format($mb / 1024 / 1024, 2) . ' TB';
    }
    if ($mb >= 1024) {
        return number_format($mb / 1024, 2) . ' GB';
    }
    return number_format($mb, 2) . ' MB';
}

function ratio_percent(float $value, float $limit): int {
    if ($limit <= 0) {
        return 0;
    }
    return max(0, min(100, (int)round(($value / $limit) * 100)));
}

function local_return_to(string $fallback): string {
    $returnTo = trim((string)($_POST['return_to'] ?? ''));
    return preg_match('/^\?/', $returnTo) ? $returnTo : $fallback;
}

function seed_default_packages(PDO $pdo): void {
    if ((int)$pdo->query("SELECT COUNT(*) FROM packages")->fetchColumn() > 0) {
        return;
    }
    $stmt = $pdo->prepare("INSERT INTO packages (name, price, db_limit, disk_quota_gb, max_conns, duration_days) VALUES (?,?,?,?,?,?)");
    foreach ([['Starter', 15000, 1, 1, 10, 30], ['Growth', 35000, 5, 5, 25, 30], ['Scale', 75000, 20, 20, 75, 30]] as $package) {
        $stmt->execute($package);
    }
}

function hub_db(): PDO {
    static $pdo = null;
    if ($pdo instanceof PDO) {
        return $pdo;
    }
    $pdo = new PDO('sqlite:' . HUB_DB_PATH);
    $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    $pdo->exec("CREATE TABLE IF NOT EXISTS servers (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, host TEXT, agent_key TEXT, public_url TEXT, pma_alias TEXT DEFAULT 'phpmyadmin', last_seen DATETIME, s3_endpoint TEXT, s3_bucket TEXT, s3_access_key TEXT, s3_secret_key TEXT)");
    $pdo->exec("CREATE TABLE IF NOT EXISTS packages (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, price REAL, db_limit INTEGER, disk_quota_gb INTEGER DEFAULT 1, max_conns INTEGER DEFAULT 10, duration_days INTEGER DEFAULT 30)");
    $pdo->exec("CREATE TABLE IF NOT EXISTS clients (id INTEGER PRIMARY KEY AUTOINCREMENT, email TEXT UNIQUE, password_hash TEXT, package_id INTEGER, expires_at DATETIME, status TEXT DEFAULT 'pending')");
    $pdo->exec("CREATE TABLE IF NOT EXISTS tenant_dbs (id INTEGER PRIMARY KEY AUTOINCREMENT, client_id INTEGER, server_id INTEGER, db_name TEXT, db_user TEXT, db_pass_cipher TEXT, allowed_ips TEXT DEFAULT '[\"%\"]', last_size_mb REAL DEFAULT 0)");
    $pdo->exec("CREATE TABLE IF NOT EXISTS security_log (ip TEXT UNIQUE, attempts INTEGER DEFAULT 0, last_attempt DATETIME)");
    $pdo->exec("CREATE TABLE IF NOT EXISTS backup_jobs (id INTEGER PRIMARY KEY AUTOINCREMENT, scope TEXT, target_label TEXT, requested_by_role TEXT, requested_by_id INTEGER, server_id INTEGER, client_id INTEGER, tdb_id INTEGER, file_name TEXT, file_path TEXT, status TEXT DEFAULT 'queued', message TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)");
    $pdo->exec("CREATE TABLE IF NOT EXISTS activity_log (id INTEGER PRIMARY KEY AUTOINCREMENT, actor_role TEXT, actor_id INTEGER, event_type TEXT, entity_type TEXT, entity_id INTEGER, message TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)");
    try {
        $pdo->exec("ALTER TABLE servers ADD COLUMN pma_alias TEXT DEFAULT 'phpmyadmin'");
    } catch (Throwable $e) {
    }
    try {
        $pdo->exec("ALTER TABLE tenant_dbs ADD COLUMN db_pass_cipher TEXT");
    } catch (Throwable $e) {
    }
    seed_default_packages($pdo);
    return $pdo;
}

function refresh_expired_clients(PDO $db): void {
    $db->exec("UPDATE clients SET status = 'expired' WHERE status = 'active' AND expires_at IS NOT NULL AND expires_at != '' AND expires_at < datetime('now')");
}

function is_client_active(array $client): bool {
    if (($client['status'] ?? '') !== 'active') {
        return false;
    }
    if (!empty($client['expires_at']) && strtotime((string)$client['expires_at']) < time()) {
        return false;
    }
    return true;
}

function normalise_client_status(string $status): string {
    return in_array($status, ['active', 'pending', 'expired'], true) ? $status : 'active';
}

function resolve_client_expiry(array $package, string $status, string $value): ?string {
    $value = trim($value);
    if ($value !== '') {
        $ts = strtotime($value);
        if ($ts === false) {
            throw new InvalidArgumentException('Provide a valid expiry date.');
        }
        return date('Y-m-d H:i:s', $ts);
    }
    if ($status === 'active') {
        return date('Y-m-d H:i:s', strtotime('+' . ((int)($package['duration_days'] ?: 30)) . ' days'));
    }
    if ($status === 'expired') {
        return date('Y-m-d H:i:s', time() - 60);
    }
    return null;
}

function load_package(PDO $db, int $packageId): ?array {
    $stmt = $db->prepare("SELECT * FROM packages WHERE id = ?");
    $stmt->execute([$packageId]);
    $package = $stmt->fetch(PDO::FETCH_ASSOC);
    return $package ?: null;
}

function is_ip_locked(PDO $db, string $ip): bool {
    $stmt = $db->prepare("SELECT attempts, last_attempt FROM security_log WHERE ip = ?");
    $stmt->execute([$ip]);
    $row = $stmt->fetch(PDO::FETCH_ASSOC);
    if (!$row) {
        return false;
    }
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

function record_activity(PDO $db, string $actorRole, ?int $actorId, string $eventType, string $entityType, ?int $entityId, string $message): void {
    $db->prepare("INSERT INTO activity_log (actor_role, actor_id, event_type, entity_type, entity_id, message) VALUES (?,?,?,?,?,?)")->execute([$actorRole, $actorId, $eventType, $entityType, $entityId, $message]);
}

function record_backup_job(PDO $db, string $requestedByRole, ?int $requestedById, array $job): void {
    $db->prepare("INSERT INTO backup_jobs (scope, target_label, requested_by_role, requested_by_id, server_id, client_id, tdb_id, file_name, file_path, status, message) VALUES (?,?,?,?,?,?,?,?,?,?,?)")->execute([
        $job['scope'] ?? 'database',
        $job['target_label'] ?? '',
        $requestedByRole,
        $requestedById,
        $job['server_id'] ?? null,
        $job['client_id'] ?? null,
        $job['tdb_id'] ?? null,
        $job['file_name'] ?? '',
        $job['file_path'] ?? '',
        $job['status'] ?? 'queued',
        $job['message'] ?? '',
    ]);
}

function call_agent(array $server, array $params = []): array {
    if (empty($server['public_url']) || empty($server['agent_key'])) {
        return ['error' => 'Node configuration is incomplete.'];
    }
    $query = array_merge(['key' => $server['agent_key']], array_diff_key($params, ['post_data' => true, 'timeout' => true]));
    $ch = curl_init(rtrim((string)$server['public_url'], '/') . '/agent-api/agent.php?' . http_build_query($query));
    curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
    curl_setopt($ch, CURLOPT_TIMEOUT, max(5, (int)($params['timeout'] ?? 5)));
    if (!empty($params['post_data'])) {
        curl_setopt($ch, CURLOPT_POST, true);
        curl_setopt($ch, CURLOPT_POSTFIELDS, http_build_query($params['post_data']));
    }
    $res = curl_exec($ch);
    if ($res === false) {
        $error = curl_error($ch) ?: 'Node unreachable.';
        curl_close($ch);
        return ['error' => $error];
    }
    curl_close($ch);
    $decoded = json_decode((string)$res, true);
    return is_array($decoded) ? $decoded : ['error' => 'Invalid node response'];
}

function smtp_write($socket, string $command): void {
    fwrite($socket, $command . "\r\n");
}

function smtp_expect($socket, array $codes): string {
    $response = '';
    while (($line = fgets($socket)) !== false) {
        $response .= $line;
        if (isset($line[3]) && $line[3] === ' ') {
            break;
        }
    }
    $code = (int)substr($response, 0, 3);
    if (!in_array($code, $codes, true)) {
        throw new RuntimeException(trim($response));
    }
    return $response;
}

function send_mail(string $to, string $subject, string $message): void {
    if ($to === '') {
        return;
    }
    $headers = "MIME-Version: 1.0\r\nContent-type:text/html;charset=UTF-8\r\nFrom: " . SMTP_FROM . "\r\n";
    $body = "<html><body style='font-family:Inter,Arial,sans-serif'>" . $message . "</body></html>";
    if (SMTP_HOST !== '') {
        try {
            $port = (int)SMTP_PORT;
            $remote = (($port === 465) ? 'tls://' : '') . SMTP_HOST . ':' . $port;
            $socket = @stream_socket_client($remote, $errno, $errstr, 15);
            if (!$socket) {
                throw new RuntimeException($errstr ?: 'SMTP unavailable');
            }
            stream_set_timeout($socket, 15);
            smtp_expect($socket, [220]);
            smtp_write($socket, 'EHLO clouddb');
            smtp_expect($socket, [250]);
            if ($port !== 465) {
                smtp_write($socket, 'STARTTLS');
                $response = smtp_expect($socket, [220, 454]);
                if (str_starts_with($response, '220') && @stream_socket_enable_crypto($socket, true, STREAM_CRYPTO_METHOD_TLS_CLIENT)) {
                    smtp_write($socket, 'EHLO clouddb');
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
            fwrite($socket, "Subject: {$subject}\r\n{$headers}\r\n{$body}\r\n.\r\n");
            smtp_expect($socket, [250]);
            smtp_write($socket, 'QUIT');
            fclose($socket);
            return;
        } catch (Throwable $e) {
        }
    }
    @mail($to, $subject, $body, $headers);
}

function paystack_enabled(): bool {
    return PAYSTACK_SECRET !== '';
}

function paystack_initialize(array $package, string $email): array {
    if (!paystack_enabled()) {
        return ['error' => 'Billing provider is not configured.'];
    }
    $amount = (int)round(((float)$package['price']) * 100);
    if ($amount <= 0) {
        return ['authorization_url' => ''];
    }
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
    return isset($decoded['data']) && is_array($decoded['data']) ? $decoded['data'] : ['error' => $decoded['message'] ?? 'Unable to initialize payment'];
}

function cipher_key(): string {
    return hash('sha256', APP_SECRET, true);
}

function encrypt_secret(string $plain): string {
    if ($plain === '') {
        return '';
    }
    if (!function_exists('openssl_encrypt')) {
        return 'plain:' . base64_encode($plain);
    }
    $iv = random_bytes(16);
    $cipher = openssl_encrypt($plain, 'AES-256-CBC', cipher_key(), OPENSSL_RAW_DATA, $iv);
    if ($cipher === false) {
        return 'plain:' . base64_encode($plain);
    }
    return base64_encode($iv . $cipher);
}

function decrypt_secret(?string $cipherText): string {
    $cipherText = (string)$cipherText;
    if ($cipherText === '') {
        return '';
    }
    if (str_starts_with($cipherText, 'plain:')) {
        return (string)base64_decode(substr($cipherText, 6), true);
    }
    if (!function_exists('openssl_decrypt')) {
        return '';
    }
    $raw = base64_decode($cipherText, true);
    if ($raw === false || strlen($raw) < 17) {
        return '';
    }
    $iv = substr($raw, 0, 16);
    $cipher = substr($raw, 16);
    $plain = openssl_decrypt($cipher, 'AES-256-CBC', cipher_key(), OPENSSL_RAW_DATA, $iv);
    return $plain === false ? '' : $plain;
}

function env_value(string $content, string $key): string {
    if (preg_match('/^' . preg_quote($key, '/') . '=(.*)$/m', $content, $match)) {
        return trim((string)$match[1], " \t\n\r\0\x0B\"'");
    }
    return '';
}

function upsert_env_value(string $content, string $key, string $value): string {
    $pattern = '/^' . preg_quote($key, '/') . '=.*$/m';
    if (preg_match($pattern, $content)) {
        return (string)preg_replace($pattern, $key . '=' . $value, $content, 1);
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
        if (preg_match('/^\[(.+)\]:(\d{1,5})$/', $configuredHost, $match)) {
            $host = $match[1];
            $port = (int)$match[2];
        } elseif (substr_count($configuredHost, ':') === 1 && preg_match('/^([^:]+):(\d{1,5})$/', $configuredHost, $match)) {
            $host = $match[1];
            $port = (int)$match[2];
        }
    }
    return ['host' => $host !== '' ? $host : 'localhost', 'port' => $port > 0 ? $port : 3306];
}

function enrich_download_env(?array $download, array $server): ?array {
    if (!$download) {
        return null;
    }
    $endpoint = server_database_endpoint($server);
    $content = (string)($download['content'] ?? '');
    $content = upsert_env_value($content, 'DB_CONNECTION', 'mysql');
    $content = upsert_env_value($content, 'DB_HOST', $endpoint['host']);
    $content = upsert_env_value($content, 'DB_PORT', (string)$endpoint['port']);
    $download['content'] = rtrim($content, "\r\n") . "\n";
    return $download;
}

function build_env_download(array $database, array $server, string $password): array {
    $endpoint = server_database_endpoint($server);
    $content = implode("\n", [
        'DB_CONNECTION=mysql',
        'DB_HOST=' . $endpoint['host'],
        'DB_PORT=' . $endpoint['port'],
        'DB_DATABASE=' . $database['db_name'],
        'DB_USERNAME=' . $database['db_user'],
        'DB_PASSWORD=' . $password,
        '',
    ]);
    return ['filename' => $database['db_name'] . '.env', 'content' => $content];
}

function sync_client_usage(PDO $db, int $clientId): void {
    $stmt = $db->prepare("SELECT t.id, t.db_name, t.server_id, s.agent_key, s.public_url FROM tenant_dbs t JOIN servers s ON t.server_id = s.id WHERE t.client_id = ? ORDER BY t.server_id");
    $stmt->execute([$clientId]);
    $rows = $stmt->fetchAll(PDO::FETCH_ASSOC);
    if (!$rows) {
        return;
    }
    $grouped = [];
    foreach ($rows as $row) {
        $grouped[$row['server_id']]['server'] = ['agent_key' => $row['agent_key'], 'public_url' => $row['public_url']];
        $grouped[$row['server_id']]['rows'][] = $row;
    }
    $update = $db->prepare("UPDATE tenant_dbs SET last_size_mb = ? WHERE id = ?");
    foreach ($grouped as $bundle) {
        $inventory = call_agent($bundle['server'], ['action' => 'list_tenants']);
        if (!is_array($inventory) || isset($inventory['error'])) {
            continue;
        }
        $sizes = [];
        foreach ($inventory as $tenant) {
            if (isset($tenant['db'])) {
                $sizes[$tenant['db']] = (float)($tenant['size_mb'] ?? 0);
            }
        }
        foreach ($bundle['rows'] as $row) {
            $update->execute([$sizes[$row['db_name']] ?? 0, $row['id']]);
        }
    }
}

function queue_backup(array $server, array $dbNames = []): array {
    $postData = [];
    $dbNames = array_values(array_unique(array_filter(array_map('trim', $dbNames))));
    if (count($dbNames) === 1) {
        $postData['db_name'] = $dbNames[0];
    } elseif ($dbNames) {
        $postData['db_names'] = json_encode($dbNames);
    }
    return call_agent($server, ['action' => 'trigger_backup', 'post_data' => $postData, 'timeout' => 15]);
}

function queue_backup_for_database(PDO $db, int $tdbId, ?int $clientId = null): array {
    $sql = "SELECT t.id, t.db_name, t.client_id, t.server_id, s.name AS server_name, s.agent_key, s.public_url FROM tenant_dbs t JOIN servers s ON s.id = t.server_id WHERE t.id = ?";
    $params = [$tdbId];
    if ($clientId !== null) {
        $sql .= " AND t.client_id = ?";
        $params[] = $clientId;
    }
    $stmt = $db->prepare($sql);
    $stmt->execute($params);
    $row = $stmt->fetch(PDO::FETCH_ASSOC);
    if (!$row) {
        return ['error' => 'Database asset not found.'];
    }
    $backup = queue_backup($row, [(string)$row['db_name']]);
    if (isset($backup['error'])) {
        return ['error' => (string)$backup['error']];
    }
    $message = 'Backup queued for ' . $row['db_name'] . ' on ' . $row['server_name'] . '.';
    if (!empty($backup['file'])) {
        $message .= ' File: ' . $backup['file'];
    }
    return ['message' => $message, 'jobs' => [[
        'scope' => 'database',
        'target_label' => (string)$row['db_name'],
        'server_id' => (int)$row['server_id'],
        'client_id' => (int)$row['client_id'],
        'tdb_id' => (int)$row['id'],
        'file_name' => (string)($backup['file'] ?? ''),
        'file_path' => (string)($backup['path'] ?? ''),
        'status' => 'queued',
        'message' => $message,
    ]]];
}

function queue_backup_for_client(PDO $db, int $clientId): array {
    $clientStmt = $db->prepare("SELECT email FROM clients WHERE id = ?");
    $clientStmt->execute([$clientId]);
    $email = (string)($clientStmt->fetchColumn() ?: '');
    $stmt = $db->prepare("SELECT t.db_name, t.server_id, s.name AS server_name, s.agent_key, s.public_url FROM tenant_dbs t JOIN servers s ON s.id = t.server_id WHERE t.client_id = ? ORDER BY t.id");
    $stmt->execute([$clientId]);
    $rows = $stmt->fetchAll(PDO::FETCH_ASSOC);
    if (!$rows) {
        return ['error' => 'This tenant does not have any provisioned databases yet.'];
    }
    $count = 0;
    $latestFile = '';
    $firstError = '';
    $serverIds = [];
    foreach ($rows as $row) {
        $backup = queue_backup($row, [(string)$row['db_name']]);
        if (isset($backup['error'])) {
            if ($firstError === '') {
                $firstError = $row['db_name'] . ': ' . (string)$backup['error'];
            }
            continue;
        }
        $count++;
        $serverIds[] = (int)$row['server_id'];
        if (!empty($backup['file'])) {
            $latestFile = (string)$backup['file'];
        }
    }
    if ($count === 0) {
        return ['error' => $firstError !== '' ? $firstError : 'Unable to queue a backup for this tenant.'];
    }
    $message = $count === 1 ? 'Backup queued for 1 database.' : "Backup queued for {$count} databases.";
    if ($latestFile !== '') {
        $message .= ' Latest file: ' . $latestFile;
    }
    if ($firstError !== '') {
        $message .= ' One or more databases failed to queue.';
    }
    return ['message' => $message, 'jobs' => [[
        'scope' => 'tenant',
        'target_label' => $email !== '' ? $email : ('Tenant #' . $clientId),
        'server_id' => $serverIds ? $serverIds[0] : null,
        'client_id' => $clientId,
        'tdb_id' => null,
        'file_name' => $latestFile,
        'file_path' => '',
        'status' => 'queued',
        'message' => $message,
    ]]];
}

function queue_backup_for_server(PDO $db, int $serverId): array {
    $stmt = $db->prepare("SELECT * FROM servers WHERE id = ?");
    $stmt->execute([$serverId]);
    $server = $stmt->fetch(PDO::FETCH_ASSOC);
    if (!$server) {
        return ['error' => 'Node not found.'];
    }
    $backup = queue_backup($server);
    if (isset($backup['error'])) {
        return ['error' => (string)$backup['error']];
    }
    $message = 'Full-node backup queued for ' . $server['name'] . '.';
    if (!empty($backup['file'])) {
        $message .= ' File: ' . $backup['file'];
    }
    return ['message' => $message, 'jobs' => [[
        'scope' => 'node',
        'target_label' => (string)$server['name'],
        'server_id' => $serverId,
        'client_id' => null,
        'tdb_id' => null,
        'file_name' => (string)($backup['file'] ?? ''),
        'file_path' => (string)($backup['path'] ?? ''),
        'status' => 'queued',
        'message' => $message,
    ]]];
}

function persist_database_password(PDO $db, int $tdbId, string $password): void {
    if ($password === '') {
        return;
    }
    $db->prepare("UPDATE tenant_dbs SET db_pass_cipher = ? WHERE id = ?")->execute([encrypt_secret($password), $tdbId]);
}

function rotate_database_password(PDO $db, int $tdbId, ?int $clientId = null): array {
    $sql = "SELECT t.*, s.name AS server_name, s.host, s.agent_key, s.public_url, s.pma_alias FROM tenant_dbs t JOIN servers s ON s.id = t.server_id WHERE t.id = ?";
    $params = [$tdbId];
    if ($clientId !== null) {
        $sql .= " AND t.client_id = ?";
        $params[] = $clientId;
    }
    $stmt = $db->prepare($sql);
    $stmt->execute($params);
    $row = $stmt->fetch(PDO::FETCH_ASSOC);
    if (!$row) {
        return ['error' => 'Database asset not found.'];
    }
    $node = call_agent($row, ['action' => 'rotate_password', 'post_data' => ['db_user' => $row['db_user']]]);
    if (isset($node['error'])) {
        return ['error' => (string)$node['error']];
    }
    $download = enrich_download_env($node['download'] ?? null, $row);
    $password = env_value((string)($download['content'] ?? ''), 'DB_PASSWORD');
    persist_database_password($db, (int)$row['id'], $password);
    return ['message' => 'Password rotated for ' . $row['db_name'] . '.', 'download' => $download, 'database_name' => (string)$row['db_name'], 'client_id' => (int)$row['client_id'], 'tdb_id' => (int)$row['id']];
}

function download_env_for_database(PDO $db, int $tdbId, ?int $clientId = null): array {
    $sql = "SELECT t.*, s.host, s.public_url, s.pma_alias, s.agent_key FROM tenant_dbs t JOIN servers s ON s.id = t.server_id WHERE t.id = ?";
    $params = [$tdbId];
    if ($clientId !== null) {
        $sql .= " AND t.client_id = ?";
        $params[] = $clientId;
    }
    $stmt = $db->prepare($sql);
    $stmt->execute($params);
    $row = $stmt->fetch(PDO::FETCH_ASSOC);
    if (!$row) {
        return ['error' => 'Database asset not found.'];
    }
    $password = decrypt_secret((string)($row['db_pass_cipher'] ?? ''));
    if ($password === '') {
        $rotated = rotate_database_password($db, $tdbId, $clientId);
        if (isset($rotated['error'])) {
            return $rotated;
        }
        $rotated['message'] = 'Credential file refreshed for ' . $row['db_name'] . '.';
        return $rotated;
    }
    return ['message' => 'Credential file generated for ' . $row['db_name'] . '.', 'download' => build_env_download($row, $row, $password), 'database_name' => (string)$row['db_name'], 'client_id' => (int)$row['client_id'], 'tdb_id' => (int)$row['id']];
}

function provision_database_for_client(PDO $db, int $clientId): array {
    $meStmt = $db->prepare("SELECT c.*, p.db_limit, p.disk_quota_gb, p.max_conns FROM clients c JOIN packages p ON c.package_id = p.id WHERE c.id = ?");
    $meStmt->execute([$clientId]);
    $me = $meStmt->fetch(PDO::FETCH_ASSOC);
    if (!$me) {
        return ['error' => 'Tenant account was not found.'];
    }
    if (!is_client_active($me)) {
        return ['error' => 'Tenant account is not active.'];
    }
    $countStmt = $db->prepare("SELECT COUNT(*) FROM tenant_dbs WHERE client_id = ?");
    $countStmt->execute([$clientId]);
    if ((int)$countStmt->fetchColumn() >= (int)$me['db_limit']) {
        return ['error' => 'Database limit reached for this plan.'];
    }
    sync_client_usage($db, $clientId);
    $usageStmt = $db->prepare("SELECT COALESCE(SUM(last_size_mb), 0) FROM tenant_dbs WHERE client_id = ?");
    $usageStmt->execute([$clientId]);
    if ((float)$usageStmt->fetchColumn() >= ((int)$me['disk_quota_gb'] * 1024)) {
        return ['error' => 'Storage quota reached for this plan.'];
    }
    $servers = $db->query("SELECT * FROM servers")->fetchAll(PDO::FETCH_ASSOC);
    $best = null;
    $min = 101;
    foreach ($servers as $server) {
        $stats = call_agent($server, ['action' => 'stats']);
        if (!isset($stats['error']) && (int)($stats['cpu'] ?? 101) < $min) {
            $min = (int)$stats['cpu'];
            $best = $server;
        }
    }
    if (!$best) {
        return ['error' => 'No online nodes are available right now.'];
    }
    $prefix = bin2hex(random_bytes(4));
    $dbName = $prefix . '_db';
    $dbUser = $prefix . '_user';
    $node = call_agent($best, ['action' => 'create', 'post_data' => ['db_prefix' => $prefix, 'db_suffix' => 'db', 'remote_host' => '%', 'max_conns' => $me['max_conns']]]);
    if (isset($node['error'])) {
        return ['error' => (string)$node['error']];
    }
    $download = enrich_download_env($node['download'] ?? null, $best);
    $password = env_value((string)($download['content'] ?? ''), 'DB_PASSWORD');
    $db->prepare("INSERT INTO tenant_dbs (client_id, server_id, db_name, db_user, db_pass_cipher, allowed_ips, last_size_mb) VALUES (?,?,?,?,?,?,0)")->execute([$clientId, $best['id'], $dbName, $dbUser, encrypt_secret($password), json_encode(['%'])]);
    $tdbId = (int)$db->lastInsertId();
    return ['message' => 'Database provisioned successfully.', 'download' => $download, 'tdb_id' => $tdbId, 'database_name' => $dbName, 'server_id' => (int)$best['id'], 'client_id' => $clientId];
}

function server_health(array $server): string {
    $lastSeen = strtotime((string)($server['last_seen'] ?? ''));
    if ($lastSeen === false) {
        return 'offline';
    }
    $age = time() - $lastSeen;
    if ($age < 600) {
        return 'healthy';
    }
    if ($age < 3600) {
        return 'warning';
    }
    return 'offline';
}

function status_chip(string $status): array {
    return match ($status) {
        'healthy', 'active', 'completed' => ['bg-tertiary-container text-on-tertiary-container', 'Healthy'],
        'warning', 'pending', 'queued' => ['bg-secondary-container text-on-secondary-container', ucfirst($status)],
        'expired', 'offline', 'failed', 'error' => ['bg-error-container text-on-error-container', ucfirst($status)],
        default => ['bg-surface-container text-on-surface-variant', ucfirst($status)],
    };
}

function activity_meta(string $eventType): array {
    return match (true) {
        str_contains($eventType, 'backup') => ['backup', 'text-primary', 'bg-primary/10'],
        str_contains($eventType, 'node') => ['dns', 'text-primary', 'bg-primary/10'],
        str_contains($eventType, 'plan') || str_contains($eventType, 'package') => ['payments', 'text-primary', 'bg-primary/10'],
        str_contains($eventType, 'security') || str_contains($eventType, 'login') => ['shield', 'text-error', 'bg-error/10'],
        str_contains($eventType, 'provision') || str_contains($eventType, 'database') => ['database', 'text-tertiary', 'bg-tertiary/10'],
        default => ['history', 'text-on-surface-variant', 'bg-surface-container'],
    };
}

function allowed_ips_text(string $json): string {
    $ips = json_decode($json, true);
    if (!is_array($ips) || !$ips) {
        return '%';
    }
    return implode(', ', array_map('strval', $ips));
}

if (isset($_GET['action']) && $_GET['action'] === 'watchdog') {
    $db = hub_db();
    refresh_expired_clients($db);
    foreach ($db->query("SELECT * FROM servers")->fetchAll(PDO::FETCH_ASSOC) as $server) {
        $stats = call_agent($server, ['action' => 'stats']);
        if (isset($stats['error'])) {
            send_mail(ADMIN_EMAIL, 'NODE OFFLINE: ' . $server['name'], 'Node ' . e((string)$server['name']) . ' is unreachable.');
        } else {
            $db->prepare("UPDATE servers SET last_seen = CURRENT_TIMESTAMP WHERE id = ?")->execute([$server['id']]);
        }
    }
    exit;
}

if (isset($_GET['action']) && $_GET['action'] === 'paystack_webhook') {
    if (!paystack_enabled()) {
        exit;
    }
    $input = file_get_contents('php://input');
    $sig = $_SERVER['HTTP_X_PAYSTACK_SIGNATURE'] ?? '';
    if ($sig !== hash_hmac('sha256', $input, PAYSTACK_SECRET)) {
        exit;
    }
    $event = json_decode($input, true);
    if (is_array($event) && ($event['event'] ?? '') === 'charge.success') {
        $email = $event['data']['customer']['email'] ?? '';
        $pkgId = (int)($event['data']['metadata']['package_id'] ?? 1);
        if ($email !== '') {
            $db = hub_db();
            $pkg = $db->prepare("SELECT duration_days FROM packages WHERE id = ?");
            $pkg->execute([$pkgId]);
            $days = (int)($pkg->fetchColumn() ?: 30);
            $expiry = date('Y-m-d H:i:s', strtotime("+{$days} days"));
            $db->prepare("UPDATE clients SET package_id = ?, expires_at = ?, status = 'active' WHERE email = ?")->execute([$pkgId, $expiry, $email]);
            record_activity($db, 'system', null, 'billing.activated', 'client', null, 'Billing activated for ' . $email . '.');
            send_mail($email, 'Subscription active', 'Your CloudDB account is ready.');
        }
    }
    exit;
}

if (($_GET['payment'] ?? '') === 'pending') {
    flash('message', 'Payment initiated. Your account will activate after Paystack confirms the charge.');
}

$is_admin = isset($_SESSION['role']) && $_SESSION['role'] === 'admin';
$client_id = isset($_SESSION['client_id']) ? (int)$_SESSION['client_id'] : null;
$view = (string)($_GET['view'] ?? ($is_admin ? 'overview' : ($client_id ? 'client' : 'landing')));
$view = $view === 'admin' ? 'overview' : $view;

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $db = hub_db();
    refresh_expired_clients($db);
    require_csrf();
    $action = (string)($_POST['action'] ?? '');

    if ($action === 'login') {
        $ip = client_ip();
        if (is_ip_locked($db, $ip)) {
            flash('error', 'Too many failed login attempts. Try again in 15 minutes.');
            header('Location: ' . page_url('login'));
            exit;
        }
        $identifier = trim((string)($_POST['email'] ?? ''));
        $password = (string)($_POST['password'] ?? '');
        if ($identifier === ADMIN_USER && password_verify($password, ADMIN_HASH)) {
            clear_failed_login($db, $ip);
            session_regenerate_id(true);
            $_SESSION['role'] = 'admin';
            unset($_SESSION['client_id']);
            record_activity($db, 'admin', null, 'auth.login', 'session', null, 'Administrator logged in.');
            header('Location: ' . page_url('overview'));
            exit;
        }
        $stmt = $db->prepare("SELECT * FROM clients WHERE email = ?");
        $stmt->execute([$identifier]);
        $client = $stmt->fetch(PDO::FETCH_ASSOC);
        if ($client && password_verify($password, (string)$client['password_hash'])) {
            clear_failed_login($db, $ip);
            if (!is_client_active($client)) {
                flash('error', ($client['status'] ?? '') === 'pending' ? 'Account pending payment.' : 'Account access has expired.');
            } else {
                session_regenerate_id(true);
                unset($_SESSION['role']);
                $_SESSION['client_id'] = (int)$client['id'];
                record_activity($db, 'client', (int)$client['id'], 'auth.login', 'client', (int)$client['id'], $client['email'] . ' signed in.');
                header('Location: ' . page_url('client'));
                exit;
            }
        } else {
            record_failed_login($db, $ip);
            record_activity($db, 'system', null, 'security.failed_login', 'session', null, 'Failed login attempt from ' . $ip . '.');
            flash('error', 'Invalid access credentials.');
        }
        header('Location: ' . page_url('login'));
        exit;
    }

    if ($action === 'signup') {
        $email = trim((string)($_POST['email'] ?? ''));
        $plainPassword = (string)($_POST['password'] ?? '');
        $packageId = (int)($_POST['package_id'] ?? 0);
        $package = load_package($db, $packageId);
        if (!$package || !filter_var($email, FILTER_VALIDATE_EMAIL) || $plainPassword === '') {
            flash('error', 'Provide a valid email, password, and plan.');
            header('Location: ' . page_url('landing'));
            exit;
        }
        $status = (!paystack_enabled() || (float)$package['price'] <= 0) ? 'active' : 'pending';
        $expiry = $status === 'active' ? date('Y-m-d H:i:s', strtotime('+' . ((int)($package['duration_days'] ?: 30)) . ' days')) : null;
        try {
            $db->prepare("INSERT INTO clients (email, password_hash, package_id, expires_at, status) VALUES (?,?,?,?,?)")->execute([$email, password_hash($plainPassword, PASSWORD_DEFAULT), $packageId, $expiry, $status]);
            $clientIdCreated = (int)$db->lastInsertId();
            record_activity($db, 'client', $clientIdCreated, 'tenant.created', 'client', $clientIdCreated, 'Tenant account created for ' . $email . '.');
        } catch (Throwable $e) {
            flash('error', 'Account already exists.');
            header('Location: ' . page_url('landing'));
            exit;
        }
        if ($status === 'active') {
            flash('message', 'Account created. You can log in immediately.');
            header('Location: ' . page_url('login'));
            exit;
        }
        $checkout = paystack_initialize($package, $email);
        if (!empty($checkout['authorization_url'])) {
            header('Location: ' . $checkout['authorization_url']);
            exit;
        }
        flash('message', 'Account created. Complete payment to activate it.');
        if (!empty($checkout['error'])) {
            flash('error', (string)$checkout['error']);
        }
        header('Location: ' . page_url('login'));
        exit;
    }

    if ($action === 'add_server' && $is_admin) {
        $name = trim((string)($_POST['name'] ?? ''));
        $host = trim((string)($_POST['host'] ?? ''));
        $agentKey = trim((string)($_POST['agent_key'] ?? ''));
        $publicUrl = rtrim(trim((string)($_POST['public_url'] ?? '')), '/');
        $pmaAlias = trim((string)($_POST['pma_alias'] ?? 'phpmyadmin'), '/');
        $returnTo = local_return_to(page_url('nodes'));
        if ($name === '' || $host === '' || $agentKey === '' || !filter_var($publicUrl, FILTER_VALIDATE_URL) || !preg_match('/^[A-Za-z0-9_-]+$/', $pmaAlias)) {
            flash('error', 'Provide valid node details.');
            header('Location: ' . $returnTo);
            exit;
        }
        $exists = $db->prepare("SELECT id FROM servers WHERE host = ? OR public_url = ?");
        $exists->execute([$host, $publicUrl]);
        if ($exists->fetchColumn()) {
            flash('error', 'That node is already registered.');
            header('Location: ' . $returnTo);
            exit;
        }
        $probe = call_agent(['agent_key' => $agentKey, 'public_url' => $publicUrl], ['action' => 'stats']);
        $lastSeen = isset($probe['error']) ? null : date('Y-m-d H:i:s');
        $db->prepare("INSERT INTO servers (name, host, agent_key, public_url, pma_alias, last_seen) VALUES (?,?,?,?,?,?)")->execute([$name, $host, $agentKey, $publicUrl, $pmaAlias, $lastSeen]);
        $serverId = (int)$db->lastInsertId();
        record_activity($db, 'admin', null, 'node.created', 'server', $serverId, 'Node ' . $name . ' was registered.');
        flash(isset($probe['error']) ? 'error' : 'message', isset($probe['error']) ? 'Node saved, but the initial health check failed.' : 'Node linked and reachable.');
        header('Location: ' . $returnTo);
        exit;
    }

    if ($action === 'update_server' && $is_admin) {
        $serverId = (int)($_POST['server_id'] ?? 0);
        $name = trim((string)($_POST['name'] ?? ''));
        $host = trim((string)($_POST['host'] ?? ''));
        $agentKey = trim((string)($_POST['agent_key'] ?? ''));
        $publicUrl = rtrim(trim((string)($_POST['public_url'] ?? '')), '/');
        $pmaAlias = trim((string)($_POST['pma_alias'] ?? 'phpmyadmin'), '/');
        $returnTo = local_return_to(page_url('nodes'));
        if ($serverId < 1 || $name === '' || $host === '' || $agentKey === '' || !filter_var($publicUrl, FILTER_VALIDATE_URL) || !preg_match('/^[A-Za-z0-9_-]+$/', $pmaAlias)) {
            flash('error', 'Provide valid node details.');
            header('Location: ' . $returnTo);
            exit;
        }
        $exists = $db->prepare("SELECT id FROM servers WHERE id != ? AND (host = ? OR public_url = ?)");
        $exists->execute([$serverId, $host, $publicUrl]);
        if ($exists->fetchColumn()) {
            flash('error', 'Another node already uses that host or endpoint.');
            header('Location: ' . $returnTo);
            exit;
        }
        $probe = call_agent(['agent_key' => $agentKey, 'public_url' => $publicUrl], ['action' => 'stats']);
        $lastSeen = isset($probe['error']) ? null : date('Y-m-d H:i:s');
        $db->prepare("UPDATE servers SET name = ?, host = ?, agent_key = ?, public_url = ?, pma_alias = ?, last_seen = ? WHERE id = ?")->execute([$name, $host, $agentKey, $publicUrl, $pmaAlias, $lastSeen, $serverId]);
        record_activity($db, 'admin', null, 'node.updated', 'server', $serverId, 'Node ' . $name . ' was updated.');
        flash(isset($probe['error']) ? 'error' : 'message', isset($probe['error']) ? 'Node updated, but the health check failed.' : 'Node updated and reachable.');
        header('Location: ' . $returnTo);
        exit;
    }

    if ($action === 'delete_server' && $is_admin) {
        $serverId = (int)($_POST['server_id'] ?? 0);
        $returnTo = local_return_to(page_url('nodes'));
        $assetStmt = $db->prepare("SELECT COUNT(*) FROM tenant_dbs WHERE server_id = ?");
        $assetStmt->execute([$serverId]);
        if ((int)$assetStmt->fetchColumn() > 0) {
            flash('error', 'Cannot delete a node that still has provisioned databases.');
            header('Location: ' . $returnTo);
            exit;
        }
        $nameStmt = $db->prepare("SELECT name FROM servers WHERE id = ?");
        $nameStmt->execute([$serverId]);
        $name = (string)($nameStmt->fetchColumn() ?: ('Node #' . $serverId));
        $db->prepare("DELETE FROM servers WHERE id = ?")->execute([$serverId]);
        record_activity($db, 'admin', null, 'node.deleted', 'server', $serverId, 'Node ' . $name . ' was removed.');
        flash('message', 'Node removed.');
        header('Location: ' . $returnTo);
        exit;
    }

    if ($action === 'create_client' && $is_admin) {
        $email = trim((string)($_POST['email'] ?? ''));
        $plainPassword = (string)($_POST['password'] ?? '');
        $packageId = (int)($_POST['package_id'] ?? 0);
        $status = normalise_client_status((string)($_POST['status'] ?? 'active'));
        $autoProvision = !empty($_POST['auto_provision']);
        $package = load_package($db, $packageId);
        $returnTo = local_return_to(page_url('tenants'));
        if (!$package || !filter_var($email, FILTER_VALIDATE_EMAIL) || $plainPassword === '') {
            flash('error', 'Provide a valid email, password, and plan.');
            header('Location: ' . $returnTo);
            exit;
        }
        try {
            $expiry = resolve_client_expiry($package, $status, (string)($_POST['expires_at'] ?? ''));
            $db->prepare("INSERT INTO clients (email, password_hash, package_id, expires_at, status) VALUES (?,?,?,?,?)")->execute([$email, password_hash($plainPassword, PASSWORD_DEFAULT), $packageId, $expiry, $status]);
            $clientTarget = (int)$db->lastInsertId();
            record_activity($db, 'admin', null, 'tenant.created', 'client', $clientTarget, 'Tenant ' . $email . ' was created.');
            $notice = 'Tenant account created.';
            if ($autoProvision && $status === 'active') {
                $result = provision_database_for_client($db, $clientTarget);
                if (!empty($result['download'])) {
                    $_SESSION['download'] = $result['download'];
                }
                if (isset($result['error'])) {
                    $notice .= ' Provisioning could not start: ' . $result['error'];
                } else {
                    record_activity($db, 'admin', null, 'database.provisioned', 'database', (int)($result['tdb_id'] ?? 0), 'Database ' . $result['database_name'] . ' was provisioned for ' . $email . '.');
                    $notice .= ' Starter database provisioned.';
                }
            }
            flash('message', $notice);
        } catch (InvalidArgumentException $e) {
            flash('error', $e->getMessage());
        } catch (Throwable $e) {
            flash('error', 'Tenant account already exists.');
        }
        header('Location: ' . $returnTo);
        exit;
    }

    if ($action === 'update_client' && $is_admin) {
        $clientTarget = (int)($_POST['client_id'] ?? 0);
        $email = trim((string)($_POST['email'] ?? ''));
        $plainPassword = (string)($_POST['password'] ?? '');
        $packageId = (int)($_POST['package_id'] ?? 0);
        $status = normalise_client_status((string)($_POST['status'] ?? 'active'));
        $package = load_package($db, $packageId);
        $returnTo = local_return_to(page_url('tenants'));
        $clientStmt = $db->prepare("SELECT * FROM clients WHERE id = ?");
        $clientStmt->execute([$clientTarget]);
        if (!$clientStmt->fetch(PDO::FETCH_ASSOC) || !$package || !filter_var($email, FILTER_VALIDATE_EMAIL)) {
            flash('error', 'Provide valid tenant details.');
            header('Location: ' . $returnTo);
            exit;
        }
        try {
            $expiry = resolve_client_expiry($package, $status, (string)($_POST['expires_at'] ?? ''));
            if ($plainPassword !== '') {
                $db->prepare("UPDATE clients SET email = ?, password_hash = ?, package_id = ?, expires_at = ?, status = ? WHERE id = ?")->execute([$email, password_hash($plainPassword, PASSWORD_DEFAULT), $packageId, $expiry, $status, $clientTarget]);
            } else {
                $db->prepare("UPDATE clients SET email = ?, package_id = ?, expires_at = ?, status = ? WHERE id = ?")->execute([$email, $packageId, $expiry, $status, $clientTarget]);
            }
            record_activity($db, 'admin', null, 'tenant.updated', 'client', $clientTarget, 'Tenant ' . $email . ' was updated.');
            flash('message', 'Tenant account updated.');
        } catch (InvalidArgumentException $e) {
            flash('error', $e->getMessage());
        } catch (Throwable $e) {
            flash('error', 'Unable to update the tenant account.');
        }
        header('Location: ' . $returnTo);
        exit;
    }

    if ($action === 'delete_client' && $is_admin) {
        $clientTarget = (int)($_POST['client_id'] ?? 0);
        $returnTo = local_return_to(page_url('tenants'));
        $assetStmt = $db->prepare("SELECT COUNT(*) FROM tenant_dbs WHERE client_id = ?");
        $assetStmt->execute([$clientTarget]);
        if ((int)$assetStmt->fetchColumn() > 0) {
            flash('error', 'Cannot delete a tenant that still owns provisioned databases.');
            header('Location: ' . $returnTo);
            exit;
        }
        $emailStmt = $db->prepare("SELECT email FROM clients WHERE id = ?");
        $emailStmt->execute([$clientTarget]);
        $email = (string)($emailStmt->fetchColumn() ?: ('Tenant #' . $clientTarget));
        $db->prepare("DELETE FROM clients WHERE id = ?")->execute([$clientTarget]);
        record_activity($db, 'admin', null, 'tenant.deleted', 'client', $clientTarget, 'Tenant ' . $email . ' was removed.');
        flash('message', 'Tenant account removed.');
        header('Location: ' . $returnTo);
        exit;
    }

    if ($action === 'create_package' && $is_admin) {
        $returnTo = local_return_to(page_url('plans'));
        $name = trim((string)($_POST['name'] ?? ''));
        $price = (float)($_POST['price'] ?? 0);
        $dbLimit = max(1, (int)($_POST['db_limit'] ?? 1));
        $diskQuota = max(1, (int)($_POST['disk_quota_gb'] ?? 1));
        $maxConns = max(1, (int)($_POST['max_conns'] ?? 10));
        $duration = max(1, (int)($_POST['duration_days'] ?? 30));
        if ($name === '') {
            flash('error', 'Provide a plan name.');
            header('Location: ' . $returnTo);
            exit;
        }
        $db->prepare("INSERT INTO packages (name, price, db_limit, disk_quota_gb, max_conns, duration_days) VALUES (?,?,?,?,?,?)")->execute([$name, $price, $dbLimit, $diskQuota, $maxConns, $duration]);
        $packageId = (int)$db->lastInsertId();
        record_activity($db, 'admin', null, 'plan.created', 'package', $packageId, 'Plan ' . $name . ' was created.');
        flash('message', 'Plan created.');
        header('Location: ' . $returnTo);
        exit;
    }

    if ($action === 'update_package' && $is_admin) {
        $returnTo = local_return_to(page_url('plans'));
        $packageId = (int)($_POST['package_id'] ?? 0);
        $name = trim((string)($_POST['name'] ?? ''));
        $price = (float)($_POST['price'] ?? 0);
        $dbLimit = max(1, (int)($_POST['db_limit'] ?? 1));
        $diskQuota = max(1, (int)($_POST['disk_quota_gb'] ?? 1));
        $maxConns = max(1, (int)($_POST['max_conns'] ?? 10));
        $duration = max(1, (int)($_POST['duration_days'] ?? 30));
        if ($packageId < 1 || $name === '') {
            flash('error', 'Provide valid plan details.');
            header('Location: ' . $returnTo);
            exit;
        }
        $db->prepare("UPDATE packages SET name = ?, price = ?, db_limit = ?, disk_quota_gb = ?, max_conns = ?, duration_days = ? WHERE id = ?")->execute([$name, $price, $dbLimit, $diskQuota, $maxConns, $duration, $packageId]);
        record_activity($db, 'admin', null, 'plan.updated', 'package', $packageId, 'Plan ' . $name . ' was updated.');
        flash('message', 'Plan updated.');
        header('Location: ' . $returnTo);
        exit;
    }

    if ($action === 'delete_package' && $is_admin) {
        $returnTo = local_return_to(page_url('plans'));
        $packageId = (int)($_POST['package_id'] ?? 0);
        $countPackages = (int)$db->query("SELECT COUNT(*) FROM packages")->fetchColumn();
        if ($countPackages <= 1) {
            flash('error', 'At least one plan must remain available.');
            header('Location: ' . $returnTo);
            exit;
        }
        $inUse = $db->prepare("SELECT COUNT(*) FROM clients WHERE package_id = ?");
        $inUse->execute([$packageId]);
        if ((int)$inUse->fetchColumn() > 0) {
            flash('error', 'You cannot delete a plan that is assigned to tenants.');
            header('Location: ' . $returnTo);
            exit;
        }
        $nameStmt = $db->prepare("SELECT name FROM packages WHERE id = ?");
        $nameStmt->execute([$packageId]);
        $name = (string)($nameStmt->fetchColumn() ?: ('Plan #' . $packageId));
        $db->prepare("DELETE FROM packages WHERE id = ?")->execute([$packageId]);
        record_activity($db, 'admin', null, 'plan.deleted', 'package', $packageId, 'Plan ' . $name . ' was deleted.');
        flash('message', 'Plan deleted.');
        header('Location: ' . $returnTo);
        exit;
    }

    if ($action === 'admin_provision' && $is_admin) {
        $returnTo = local_return_to(page_url('tenants'));
        $targetClient = (int)($_POST['client_id'] ?? 0);
        $result = provision_database_for_client($db, $targetClient);
        if (!empty($result['download'])) {
            $_SESSION['download'] = $result['download'];
        }
        if (!isset($result['error'])) {
            record_activity($db, 'admin', null, 'database.provisioned', 'database', (int)($result['tdb_id'] ?? 0), 'Database ' . ($result['database_name'] ?? 'asset') . ' was provisioned.');
        }
        flash(isset($result['error']) ? 'error' : 'message', (string)($result['error'] ?? $result['message'] ?? 'Provision request completed.'));
        header('Location: ' . $returnTo);
        exit;
    }

    if ($action === 'provision' && $client_id) {
        $returnTo = local_return_to(page_url('client'));
        $result = provision_database_for_client($db, $client_id);
        if (!empty($result['download'])) {
            $_SESSION['download'] = $result['download'];
        }
        if (!isset($result['error'])) {
            record_activity($db, 'client', $client_id, 'database.provisioned', 'database', (int)($result['tdb_id'] ?? 0), 'Database ' . ($result['database_name'] ?? 'asset') . ' was provisioned.');
        }
        flash(isset($result['error']) ? 'error' : 'message', (string)($result['error'] ?? $result['message'] ?? 'Provision request completed.'));
        header('Location: ' . $returnTo);
        exit;
    }

    if ($action === 'backup_server' && $is_admin) {
        $returnTo = local_return_to(page_url('backups'));
        $serverId = (int)($_POST['server_id'] ?? 0);
        $result = queue_backup_for_server($db, $serverId);
        if (!isset($result['error'])) {
            foreach ($result['jobs'] ?? [] as $job) {
                record_backup_job($db, 'admin', null, $job);
            }
            record_activity($db, 'admin', null, 'backup.requested', 'server', $serverId, $result['message']);
        }
        flash(isset($result['error']) ? 'error' : 'message', (string)($result['error'] ?? $result['message'] ?? 'Backup request completed.'));
        header('Location: ' . $returnTo);
        exit;
    }

    if ($action === 'backup_client' && $is_admin) {
        $returnTo = local_return_to(page_url('backups'));
        $targetClient = (int)($_POST['client_id'] ?? 0);
        $result = queue_backup_for_client($db, $targetClient);
        if (!isset($result['error'])) {
            foreach ($result['jobs'] ?? [] as $job) {
                record_backup_job($db, 'admin', null, $job);
            }
            record_activity($db, 'admin', null, 'backup.requested', 'client', $targetClient, $result['message']);
        }
        flash(isset($result['error']) ? 'error' : 'message', (string)($result['error'] ?? $result['message'] ?? 'Backup request completed.'));
        header('Location: ' . $returnTo);
        exit;
    }

    if (($action === 'backup_db_admin' && $is_admin) || ($action === 'backup_db' && $client_id)) {
        $tdbId = (int)($_POST['tdb_id'] ?? 0);
        $returnTo = local_return_to($is_admin ? page_url('backups') : page_url('client'));
        $result = queue_backup_for_database($db, $tdbId, $action === 'backup_db' ? $client_id : null);
        if (!isset($result['error'])) {
            foreach ($result['jobs'] ?? [] as $job) {
                record_backup_job($db, $is_admin ? 'admin' : 'client', $client_id, $job);
            }
            record_activity($db, $is_admin ? 'admin' : 'client', $client_id, 'backup.requested', 'database', $tdbId, $result['message']);
        }
        flash(isset($result['error']) ? 'error' : 'message', (string)($result['error'] ?? $result['message'] ?? 'Backup request completed.'));
        header('Location: ' . $returnTo);
        exit;
    }

    if ($action === 'download_db_env' && ($is_admin || $client_id)) {
        $tdbId = (int)($_POST['tdb_id'] ?? 0);
        $returnTo = local_return_to($client_id ? page_url('client') : page_url('databases'));
        $result = download_env_for_database($db, $tdbId, $client_id ?: null);
        if (!empty($result['download'])) {
            $_SESSION['download'] = $result['download'];
        }
        if (!isset($result['error'])) {
            record_activity($db, $is_admin ? 'admin' : 'client', $client_id, 'database.env_issued', 'database', $tdbId, $result['message']);
        }
        flash(isset($result['error']) ? 'error' : 'message', (string)($result['error'] ?? $result['message'] ?? 'Credential file generated.'));
        header('Location: ' . $returnTo);
        exit;
    }

    if ($action === 'rotate_db_password' && ($is_admin || $client_id)) {
        $tdbId = (int)($_POST['tdb_id'] ?? 0);
        $returnTo = local_return_to(page_url('database', ['id' => $tdbId]));
        $result = rotate_database_password($db, $tdbId, $client_id ?: null);
        if (!empty($result['download'])) {
            $_SESSION['download'] = $result['download'];
        }
        if (!isset($result['error'])) {
            record_activity($db, $is_admin ? 'admin' : 'client', $client_id, 'database.credentials_rotated', 'database', $tdbId, $result['message']);
        }
        flash(isset($result['error']) ? 'error' : 'message', (string)($result['error'] ?? $result['message'] ?? 'Credentials rotated.'));
        header('Location: ' . $returnTo);
        exit;
    }

    if ($action === 'update_whitelist' && ($is_admin || $client_id)) {
        $tdbId = (int)($_POST['tdb_id'] ?? 0);
        $sql = "SELECT t.*, s.agent_key, s.public_url FROM tenant_dbs t JOIN servers s ON t.server_id = s.id WHERE t.id = ?";
        $params = [$tdbId];
        if ($client_id) {
            $sql .= " AND t.client_id = ?";
            $params[] = $client_id;
        }
        $stmt = $db->prepare($sql);
        $stmt->execute($params);
        $tdb = $stmt->fetch(PDO::FETCH_ASSOC);
        $returnTo = local_return_to(page_url('database', ['id' => $tdbId]));
        if ($tdb) {
            $ips = array_values(array_filter(array_map('trim', explode(',', (string)($_POST['ips'] ?? '')))));
            if (!$ips) {
                $ips = ['%'];
            }
            $nodeRes = call_agent($tdb, ['action' => 'update_hosts', 'post_data' => ['db_user' => $tdb['db_user'], 'hosts' => json_encode($ips)]]);
            if (!isset($nodeRes['error'])) {
                $db->prepare("UPDATE tenant_dbs SET allowed_ips = ? WHERE id = ?")->execute([json_encode($ips), $tdbId]);
                record_activity($db, $is_admin ? 'admin' : 'client', $client_id, 'database.allowlist_updated', 'database', $tdbId, 'Access allowlist updated for ' . $tdb['db_name'] . '.');
                flash('message', 'Access allowlist updated.');
            } else {
                flash('error', (string)$nodeRes['error']);
            }
        }
        header('Location: ' . $returnTo);
        exit;
    }
}

if (isset($_GET['action']) && $_GET['action'] === 'logout') {
    if ($is_admin || $client_id) {
        $db = hub_db();
        record_activity($db, $is_admin ? 'admin' : 'client', $client_id, 'auth.logout', 'session', null, ($is_admin ? 'Administrator' : 'Tenant') . ' signed out.');
    }
    session_destroy();
    header('Location: ?');
    exit;
}

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
$message = consume_flash('message');
$error = consume_flash('error');
$downloadReady = !empty($_SESSION['download']);

$publicViews = ['landing', 'login', 'signup'];
$adminViews = ['overview', 'nodes', 'tenants', 'backups', 'plans', 'activity', 'databases', 'database', 'account', 'settings'];
$clientViews = ['client', 'database', 'backups', 'plans', 'activity', 'account', 'settings'];
if (!$is_admin && !$client_id && !in_array($view, $publicViews, true)) {
    $view = 'landing';
}
if ($is_admin && !in_array($view, array_merge($publicViews, $adminViews), true)) {
    $view = 'overview';
}
if ($client_id && !$is_admin && !in_array($view, array_merge($publicViews, $clientViews), true)) {
    $view = 'client';
}

$client = null;
$clientDbCount = 0;
$clientUsageMb = 0.0;
$clientDatabases = [];
if ($client_id) {
    sync_client_usage($db, $client_id);
    $clientStmt = $db->prepare("SELECT c.*, p.name AS package_name, p.db_limit, p.disk_quota_gb, p.max_conns, p.duration_days FROM clients c LEFT JOIN packages p ON c.package_id = p.id WHERE c.id = ?");
    $clientStmt->execute([$client_id]);
    $client = $clientStmt->fetch(PDO::FETCH_ASSOC) ?: null;
    $usageStmt = $db->prepare("SELECT COUNT(*), COALESCE(SUM(last_size_mb), 0) FROM tenant_dbs WHERE client_id = ?");
    $usageStmt->execute([$client_id]);
    $usageRow = $usageStmt->fetch(PDO::FETCH_NUM) ?: [0, 0];
    $clientDbCount = (int)$usageRow[0];
    $clientUsageMb = (float)$usageRow[1];
    $dbsStmt = $db->prepare("SELECT t.*, s.name AS server_name, s.host, s.public_url, s.pma_alias, c.email AS client_email FROM tenant_dbs t JOIN servers s ON s.id = t.server_id JOIN clients c ON c.id = t.client_id WHERE t.client_id = ? ORDER BY t.id DESC");
    $dbsStmt->execute([$client_id]);
    $clientDatabases = $dbsStmt->fetchAll(PDO::FETCH_ASSOC);
}

$servers = $db->query("SELECT s.*, COUNT(t.id) AS db_count FROM servers s LEFT JOIN tenant_dbs t ON t.server_id = s.id GROUP BY s.id ORDER BY s.name")->fetchAll(PDO::FETCH_ASSOC);
$packages = $db->query("SELECT * FROM packages ORDER BY price ASC, id ASC")->fetchAll(PDO::FETCH_ASSOC);
$adminClients = $is_admin ? $db->query("SELECT c.*, p.name AS package_name, p.db_limit, p.disk_quota_gb, COUNT(t.id) AS db_count, COALESCE(SUM(t.last_size_mb), 0) AS usage_mb FROM clients c LEFT JOIN packages p ON p.id = c.package_id LEFT JOIN tenant_dbs t ON t.client_id = c.id GROUP BY c.id ORDER BY c.id DESC")->fetchAll(PDO::FETCH_ASSOC) : [];

$searchQuery = trim((string)($_GET['q'] ?? ''));
$scopeFilter = trim((string)($_GET['scope'] ?? ''));
$statusFilter = trim((string)($_GET['status'] ?? ''));
$serverFilter = (int)($_GET['server_id'] ?? 0);
$tenantFilter = (int)($_GET['client_id'] ?? 0);

$allDatabases = [];
if ($is_admin) {
    $sql = "SELECT t.*, c.email AS client_email, c.status AS client_status, p.name AS package_name, s.name AS server_name, s.host, s.public_url, s.pma_alias FROM tenant_dbs t JOIN clients c ON c.id = t.client_id LEFT JOIN packages p ON p.id = c.package_id JOIN servers s ON s.id = t.server_id WHERE 1 = 1";
    $params = [];
    if ($serverFilter > 0) {
        $sql .= " AND t.server_id = ?";
        $params[] = $serverFilter;
    }
    if ($tenantFilter > 0) {
        $sql .= " AND t.client_id = ?";
        $params[] = $tenantFilter;
    }
    $sql .= " ORDER BY t.id DESC";
    $stmt = $db->prepare($sql);
    $stmt->execute($params);
    $allDatabases = $stmt->fetchAll(PDO::FETCH_ASSOC);
} elseif ($client_id) {
    $allDatabases = $clientDatabases;
}

$databaseDetail = null;
$databaseBackups = [];
$databaseEvents = [];
$databaseId = (int)($_GET['id'] ?? 0);
if ($databaseId > 0 && ($is_admin || $client_id)) {
    $sql = "SELECT t.*, c.email AS client_email, c.status AS client_status, p.name AS package_name, s.name AS server_name, s.host, s.public_url, s.pma_alias FROM tenant_dbs t JOIN clients c ON c.id = t.client_id LEFT JOIN packages p ON p.id = c.package_id JOIN servers s ON s.id = t.server_id WHERE t.id = ?";
    $params = [$databaseId];
    if ($client_id && !$is_admin) {
        $sql .= " AND t.client_id = ?";
        $params[] = $client_id;
    }
    $stmt = $db->prepare($sql);
    $stmt->execute($params);
    $databaseDetail = $stmt->fetch(PDO::FETCH_ASSOC) ?: null;
    if ($databaseDetail) {
        $backupsStmt = $db->prepare("SELECT * FROM backup_jobs WHERE tdb_id = ? ORDER BY id DESC LIMIT 8");
        $backupsStmt->execute([$databaseId]);
        $databaseBackups = $backupsStmt->fetchAll(PDO::FETCH_ASSOC);
        $eventsStmt = $db->prepare("SELECT * FROM activity_log WHERE entity_type = 'database' AND entity_id = ? ORDER BY id DESC LIMIT 8");
        $eventsStmt->execute([$databaseId]);
        $databaseEvents = $eventsStmt->fetchAll(PDO::FETCH_ASSOC);
    } elseif ($view === 'database') {
        $view = $client_id ? 'client' : 'databases';
    }
}

$backupWhere = [];
$backupParams = [];
if ($scopeFilter !== '' && in_array($scopeFilter, ['node', 'tenant', 'database'], true)) {
    $backupWhere[] = 'b.scope = ?';
    $backupParams[] = $scopeFilter;
}
if ($statusFilter !== '' && in_array($statusFilter, ['queued', 'completed', 'failed'], true)) {
    $backupWhere[] = 'b.status = ?';
    $backupParams[] = $statusFilter;
}
if ($client_id && !$is_admin) {
    $backupWhere[] = '(b.client_id = ? OR b.requested_by_id = ?)';
    $backupParams[] = $client_id;
    $backupParams[] = $client_id;
}
if ($searchQuery !== '' && $view === 'backups') {
    $backupWhere[] = '(b.target_label LIKE ? OR s.name LIKE ? OR c.email LIKE ?)';
    $needle = '%' . $searchQuery . '%';
    $backupParams[] = $needle;
    $backupParams[] = $needle;
    $backupParams[] = $needle;
}
$backupSql = "SELECT b.*, s.name AS server_name, c.email AS client_email FROM backup_jobs b LEFT JOIN servers s ON s.id = b.server_id LEFT JOIN clients c ON c.id = b.client_id";
if ($backupWhere) {
    $backupSql .= ' WHERE ' . implode(' AND ', $backupWhere);
}
$backupSql .= ' ORDER BY b.id DESC LIMIT 30';
$backupStmt = $db->prepare($backupSql);
$backupStmt->execute($backupParams);
$backupJobs = $backupStmt->fetchAll(PDO::FETCH_ASSOC);

$activityWhere = [];
$activityParams = [];
if ($client_id && !$is_admin) {
    $activityWhere[] = "(a.actor_role = ? AND a.actor_id = ? OR (a.entity_type = ? AND a.entity_id = ?) OR (a.entity_type = ? AND a.entity_id IN (SELECT id FROM tenant_dbs WHERE client_id = ?)))";
    array_push($activityParams, 'client', $client_id, 'client', $client_id, 'database', $client_id);
}
if ($scopeFilter !== '' && $view === 'activity') {
    $activityWhere[] = 'a.event_type LIKE ?';
    $activityParams[] = $scopeFilter . '%';
}
if ($searchQuery !== '' && $view === 'activity') {
    $activityWhere[] = '(a.message LIKE ? OR a.event_type LIKE ? OR a.entity_type LIKE ?)';
    $needle = '%' . $searchQuery . '%';
    $activityParams[] = $needle;
    $activityParams[] = $needle;
    $activityParams[] = $needle;
}
$activitySql = "SELECT a.* FROM activity_log a";
if ($activityWhere) {
    $activitySql .= ' WHERE ' . implode(' AND ', $activityWhere);
}
$activitySql .= ' ORDER BY a.id DESC LIMIT 30';
$activityStmt = $db->prepare($activitySql);
$activityStmt->execute($activityParams);
$activityRows = $activityStmt->fetchAll(PDO::FETCH_ASSOC);

$planUsage = [];
$planUsageStmt = $db->query("SELECT package_id, COUNT(*) AS total FROM clients GROUP BY package_id");
foreach ($planUsageStmt->fetchAll(PDO::FETCH_ASSOC) as $row) {
    $planUsage[(int)$row['package_id']] = (int)$row['total'];
}
$planActivityStmt = $db->prepare("SELECT * FROM activity_log WHERE entity_type = 'package' ORDER BY id DESC LIMIT 10");
$planActivityStmt->execute();
$planActivity = $planActivityStmt->fetchAll(PDO::FETCH_ASSOC);

$serverTotals = ['healthy' => 0, 'warning' => 0, 'offline' => 0];
foreach ($servers as $server) {
    $serverTotals[server_health($server)]++;
}
$tenantTotals = ['active' => 0, 'pending' => 0, 'expired' => 0];
foreach ($adminClients as $tenant) {
    $status = normalise_client_status((string)$tenant['status']);
    $tenantTotals[$status] = ($tenantTotals[$status] ?? 0) + 1;
}
$totalStorageMb = (float)($db->query("SELECT COALESCE(SUM(last_size_mb), 0) FROM tenant_dbs")->fetchColumn() ?: 0);
$backupStats = ['queued' => 0, 'completed' => 0, 'failed' => 0];
foreach ($backupJobs as $job) {
    $state = (string)($job['status'] ?? 'queued');
    if (isset($backupStats[$state])) {
        $backupStats[$state]++;
    }
}
$overviewActivity = array_slice($activityRows, 0, 6);
$attentionItems = [];
if ($serverTotals['offline'] > 0) {
    $attentionItems[] = ['title' => 'Offline infrastructure', 'body' => $serverTotals['offline'] . ' node(s) have not checked in recently.'];
}
if ($serverTotals['warning'] > 0) {
    $attentionItems[] = ['title' => 'Stale health data', 'body' => $serverTotals['warning'] . ' node(s) need a fresh heartbeat.'];
}
if ($tenantTotals['pending'] > 0) {
    $attentionItems[] = ['title' => 'Pending billing', 'body' => $tenantTotals['pending'] . ' tenant account(s) are waiting for activation.'];
}
if ($tenantTotals['expired'] > 0) {
    $attentionItems[] = ['title' => 'Expired tenants', 'body' => $tenantTotals['expired'] . ' tenant account(s) have expired access.'];
}

$currentUrl = match ($view) {
    'database' => page_url('database', ['id' => $databaseId]),
    'databases' => page_url('databases', array_filter(['server_id' => $serverFilter ?: null, 'client_id' => $tenantFilter ?: null])),
    'backups' => page_url('backups'),
    'plans' => page_url('plans'),
    'activity' => page_url('activity'),
    'nodes' => page_url('nodes'),
    'tenants' => page_url('tenants'),
    'client' => page_url('client'),
    'account' => page_url('account'),
    'settings' => page_url('settings'),
    default => page_url($is_admin ? 'overview' : 'client'),
};

$drawer = trim((string)($_GET['drawer'] ?? ''));
$editServer = null;
$editTenant = null;
$editPlan = null;
if ($drawer === 'node-edit' && $is_admin) {
    $stmt = $db->prepare("SELECT * FROM servers WHERE id = ?");
    $stmt->execute([(int)($_GET['drawer_id'] ?? 0)]);
    $editServer = $stmt->fetch(PDO::FETCH_ASSOC) ?: null;
}
if ($drawer === 'tenant-edit' && $is_admin) {
    $stmt = $db->prepare("SELECT * FROM clients WHERE id = ?");
    $stmt->execute([(int)($_GET['drawer_id'] ?? 0)]);
    $editTenant = $stmt->fetch(PDO::FETCH_ASSOC) ?: null;
}
if ($drawer === 'plan-edit' && $is_admin) {
    $editPlan = load_package($db, (int)($_GET['drawer_id'] ?? 0));
}

$documentTitle = match ($view) {
    'landing' => 'CloudDB | Secure MariaDB Infrastructure',
    'login' => 'Sign in | CloudDB',
    'signup' => 'Create account | CloudDB',
    'overview' => 'Admin Dashboard | CloudDB',
    'nodes' => 'Nodes | CloudDB',
    'tenants' => 'Tenants | CloudDB',
    'backups' => 'Backups Center | CloudDB',
    'plans' => 'Service Tiers | CloudDB',
    'activity' => 'Audit Trail | CloudDB',
    'databases' => 'Databases | CloudDB',
    'database' => ($databaseDetail['db_name'] ?? 'Database') . ' | CloudDB',
    'client' => 'Client Dashboard | CloudDB',
    'account' => 'Account | CloudDB',
    'settings' => 'Settings | CloudDB',
    default => 'CloudDB',
};

$panel = 'bg-surface-container-lowest rounded-2xl border border-outline-variant/10 shadow-[0_28px_80px_-40px_rgba(17,48,105,0.28)]';
$softPanel = 'bg-surface-container-low rounded-2xl border border-outline-variant/10';
$input = 'w-full rounded-xl border border-outline-variant/20 bg-surface-container-low px-4 py-3 text-sm text-on-surface placeholder:text-on-surface-variant/60 focus:border-primary focus:ring-2 focus:ring-primary/10';
$buttonPrimary = 'inline-flex items-center justify-center gap-2 rounded-xl bg-primary px-5 py-3 text-sm font-bold text-on-primary shadow-lg shadow-primary/10 transition hover:bg-primary-dim';
$buttonSecondary = 'inline-flex items-center justify-center gap-2 rounded-xl bg-surface-container px-5 py-3 text-sm font-semibold text-on-surface transition hover:bg-surface-container-high';
$buttonGhost = 'inline-flex items-center justify-center gap-2 rounded-xl border border-outline-variant/20 px-4 py-2.5 text-sm font-semibold text-on-surface-variant transition hover:bg-surface-container-high hover:text-on-surface';
$buttonDanger = 'inline-flex items-center justify-center gap-2 rounded-xl bg-error-container px-4 py-2.5 text-sm font-semibold text-on-error-container transition hover:opacity-90';

$selectedPackage = null;
if ($view === 'signup') {
    $selectedPackage = load_package($db, (int)($_GET['pkg'] ?? ($packages[0]['id'] ?? 1)));
    if (!$selectedPackage && $packages) {
        $selectedPackage = $packages[0];
    }
}

$topSearchPlaceholder = match ($view) {
    'activity' => 'Search events, actors, or assets...',
    'backups' => 'Search backup requests...',
    'tenants' => 'Search tenants...',
    'nodes' => 'Search nodes...',
    default => 'Search infrastructure...',
};

function render_alert(string $message, string $type): string {
    if ($message === '') {
        return '';
    }
    $classes = $type === 'error' ? 'bg-error-container/35 text-on-error-container border-error/10' : 'bg-primary-container/45 text-on-primary-container border-primary/10';
    return '<div class="rounded-2xl border px-5 py-4 text-sm font-medium ' . $classes . '">' . e($message) . '</div>';
}

require __DIR__ . DIRECTORY_SEPARATOR . 'hub-view.php';
