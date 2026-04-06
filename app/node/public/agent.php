<?php
declare(strict_types=1);

require dirname(__DIR__) . DIRECTORY_SEPARATOR . 'bootstrap.php';

if (($_GET['key'] ?? '') !== API_KEY) { http_response_code(403); die('Forbidden'); }

function db(): PDO {
    return new PDO(NODE_DB_DSN, PROV_USER, PROV_PASS, [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC
    ]);
}
function ensure_identifier(string $value, string $label): string {
    if (!preg_match('/^[A-Za-z0-9_]{1,48}$/', $value)) throw new InvalidArgumentException($label . ' is invalid.');
    return $value;
}
function ensure_host_value(string $value): string {
    $value = trim($value);
    if ($value === '%') return $value;
    if (filter_var($value, FILTER_VALIDATE_IP)) return $value;
    if (preg_match('/^[A-Za-z0-9._%-]{1,255}$/', $value)) return $value;
    throw new InvalidArgumentException('Host value is invalid.');
}
function ipv4_to_unsigned_long(string $ip): int {
    $value = ip2long($ip);
    if ($value === false) {
        throw new InvalidArgumentException('Host value is invalid.');
    }
    return (int)sprintf('%u', $value);
}
function expand_host_value(string $value): array {
    $value = trim($value);
    if (!preg_match('/^([^\/]+)\/(\d{1,3})$/', $value, $match)) {
        return [ensure_host_value($value)];
    }
    $ip = trim($match[1]);
    $mask = (int)$match[2];
    if (filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV6)) {
        if ($mask === 128) {
            return [$ip];
        }
        throw new InvalidArgumentException('IPv6 CIDR ranges are not supported in access allowlists yet.');
    }
    if (!filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4) || $mask < 0 || $mask > 32) {
        throw new InvalidArgumentException('Host value is invalid.');
    }
    if ($mask === 0) {
        return ['%'];
    }
    $hostCount = (int)(2 ** (32 - $mask));
    if ($hostCount > 256) {
        throw new InvalidArgumentException('CIDR ranges wider than /24 are not supported. Use /24 or narrower.');
    }
    $maskBits = $mask === 32 ? 0xFFFFFFFF : ((0xFFFFFFFF << (32 - $mask)) & 0xFFFFFFFF);
    $network = ipv4_to_unsigned_long($ip) & $maskBits;
    $hosts = [];
    for ($offset = 0; $offset < $hostCount; $offset++) {
        $hosts[] = long2ip($network + $offset);
    }
    return $hosts;
}
function normalize_allowlist_hosts(array $values): array {
    $hosts = [];
    foreach ($values as $value) {
        foreach (expand_host_value((string)$value) as $host) {
            $hosts[] = $host;
        }
    }
    $hosts = array_values(array_unique($hosts));
    if (in_array('%', $hosts, true)) {
        return ['%'];
    }
    return $hosts;
}
function sql_ident(string $value): string {
    return '`' . str_replace('`', '``', $value) . '`';
}
function tenant_db_for_user(string $dbUser): string {
    if (!preg_match('/^([A-Za-z0-9]+)_user$/', $dbUser, $m)) throw new InvalidArgumentException('Database user is invalid.');
    return $m[1] . '_db';
}
function quoted_user_host(PDO $pdo, string $user, string $host): string {
    return $pdo->quote($user) . '@' . $pdo->quote($host);
}
function drop_remote_user_hosts(PDO $pdo, string $user): void {
    $stmt = $pdo->prepare("SELECT Host FROM mysql.user WHERE User = ? AND Host != 'localhost'");
    $stmt->execute([$user]);
    foreach ($stmt->fetchAll(PDO::FETCH_COLUMN) as $host) {
        $pdo->exec("DROP USER IF EXISTS " . quoted_user_host($pdo, $user, (string)$host));
    }
}
function cpu_usage_percent(): int {
    if (!function_exists('sys_getloadavg')) {
        return 0;
    }
    $loads = sys_getloadavg();
    $load = is_array($loads) ? (float)($loads[0] ?? 0) : 0.0;
    $cpuCount = 1;
    $nproc = trim((string)@shell_exec('nproc 2>/dev/null'));
    if (ctype_digit($nproc) && (int)$nproc > 0) {
        $cpuCount = (int)$nproc;
    }
    return max(0, min(100, (int)round(($load / $cpuCount) * 100)));
}
function backup_script_ready(): bool {
    if (!is_file(BACKUP_SCRIPT)) {
        return false;
    }
    if (preg_match('/\.php$/i', BACKUP_SCRIPT)) {
        return is_readable(BACKUP_SCRIPT);
    }
    return is_executable(BACKUP_SCRIPT);
}
function resolve_php_cli_binary(): string {
    $candidates = [];
    if (PHP_BINARY !== '') {
        $candidates[] = PHP_BINARY;
        $candidates[] = dirname(PHP_BINARY) . DIRECTORY_SEPARATOR . '..' . DIRECTORY_SEPARATOR . '..' . DIRECTORY_SEPARATOR . 'php' . DIRECTORY_SEPARATOR . 'php.exe';
        $candidates[] = dirname(PHP_BINARY) . DIRECTORY_SEPARATOR . 'php.exe';
    }
    $candidates[] = 'php';
    foreach ($candidates as $candidate) {
        $candidate = str_replace(['/', '\\'], DIRECTORY_SEPARATOR, $candidate);
        if (preg_match('/^(?:[A-Za-z]:[\\\\\\/]|[\\\\\\/])/', $candidate) === 1) {
            $base = strtolower(basename($candidate));
            if (is_file($candidate) && str_starts_with($base, 'php')) {
                return $candidate;
            }
            continue;
        }
        return $candidate;
    }
    return 'php';
}
function run_php_backup_script(string $file, array $dbNames): array {
    $phpBinary = resolve_php_cli_binary();
    $command = array_merge([$phpBinary, BACKUP_SCRIPT], $dbNames);
    $descriptors = [
        1 => ['pipe', 'w'],
        2 => ['pipe', 'w'],
    ];
    $env = array_merge($_ENV, $_SERVER, [
        'BACKUP_FILE' => $file,
    ]);
    $process = proc_open($command, $descriptors, $pipes, dirname(BACKUP_SCRIPT), $env, ['bypass_shell' => true]);
    if (!is_resource($process)) {
        throw new RuntimeException('CloudDB backup engine could not be started.');
    }
    $stdout = stream_get_contents($pipes[1]) ?: '';
    fclose($pipes[1]);
    $stderr = stream_get_contents($pipes[2]) ?: '';
    fclose($pipes[2]);
    $exitCode = proc_close($process);
    if ($exitCode !== 0) {
        throw new RuntimeException(trim($stderr !== '' ? $stderr : ($stdout !== '' ? $stdout : 'CloudDB backup engine failed.')));
    }
    return ['file' => basename($file), 'path' => $file, 'pid' => 'sync'];
}
function resolve_backup_file(string $fileName): string {
    $fileName = trim(str_replace('\\', '/', $fileName));
    $baseName = basename($fileName);
    if ($fileName === '' || $baseName !== $fileName || !preg_match('/^[A-Za-z0-9._-]+\.enc$/', $baseName)) {
        throw new InvalidArgumentException('Backup file is invalid.');
    }
    return rtrim(BACKUP_DIR, DIRECTORY_SEPARATOR) . DIRECTORY_SEPARATOR . $baseName;
}
function backup_file_info(string $fileName): array {
    $path = resolve_backup_file($fileName);
    if (!is_file($path)) {
        return ['exists' => false, 'file' => basename($path)];
    }
    return [
        'exists' => true,
        'file' => basename($path),
        'path' => $path,
        'size_bytes' => (int)(filesize($path) ?: 0),
        'modified_at' => date('c', (int)(filemtime($path) ?: time())),
    ];
}
function resolve_mysql_cli_binary(): string {
    $candidates = [];
    if (PHP_BINARY !== '') {
        $phpDir = dirname(PHP_BINARY);
        $candidates[] = $phpDir . DIRECTORY_SEPARATOR . '..' . DIRECTORY_SEPARATOR . 'mysql' . DIRECTORY_SEPARATOR . 'bin' . DIRECTORY_SEPARATOR . 'mysql.exe';
        $candidates[] = $phpDir . DIRECTORY_SEPARATOR . '..' . DIRECTORY_SEPARATOR . 'mysql' . DIRECTORY_SEPARATOR . 'bin' . DIRECTORY_SEPARATOR . 'mysql';
        $candidates[] = $phpDir . DIRECTORY_SEPARATOR . '..' . DIRECTORY_SEPARATOR . 'mysql' . DIRECTORY_SEPARATOR . 'bin' . DIRECTORY_SEPARATOR . 'mariadb.exe';
        $candidates[] = $phpDir . DIRECTORY_SEPARATOR . '..' . DIRECTORY_SEPARATOR . 'mysql' . DIRECTORY_SEPARATOR . 'bin' . DIRECTORY_SEPARATOR . 'mariadb';
    }
    $candidates[] = 'mysql';
    $candidates[] = 'mariadb';
    foreach ($candidates as $candidate) {
        $candidate = str_replace(['/', '\\'], DIRECTORY_SEPARATOR, $candidate);
        if (preg_match('/^(?:[A-Za-z]:[\\\\\\/]|[\\\\\\/])/', $candidate) === 1) {
            if (is_file($candidate)) {
                return $candidate;
            }
            continue;
        }
        if (command_exists($candidate)) {
            return $candidate;
        }
    }
    throw new RuntimeException('CloudDB restore failed: no MariaDB client binary found.');
}
function reset_database_for_restore(PDO $pdo, string $dbName): void {
    $dbName = ensure_identifier($dbName, 'Database name');
    $pdo->exec("DROP DATABASE IF EXISTS " . sql_ident($dbName));
    $pdo->exec("CREATE DATABASE " . sql_ident($dbName) . " CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci");
}
function import_sql_payload(string $sql): void {
    if (!is_readable(BACKUP_DB_CNF)) {
        throw new RuntimeException('CloudDB restore failed: MySQL credential file is not readable.');
    }
    $mysqlBinary = resolve_mysql_cli_binary();
    $command = [$mysqlBinary, '--defaults-extra-file=' . BACKUP_DB_CNF];
    $process = proc_open($command, [
        0 => ['pipe', 'w'],
        1 => ['pipe', 'w'],
        2 => ['pipe', 'w'],
    ], $pipes, dirname(is_file($mysqlBinary) ? $mysqlBinary : __FILE__), null, ['bypass_shell' => true]);
    if (!is_resource($process)) {
        throw new RuntimeException('CloudDB restore failed: unable to start the database client.');
    }
    fwrite($pipes[0], $sql);
    fclose($pipes[0]);
    $stdout = stream_get_contents($pipes[1]) ?: '';
    fclose($pipes[1]);
    $stderr = stream_get_contents($pipes[2]) ?: '';
    fclose($pipes[2]);
    $exitCode = proc_close($process);
    if ($exitCode !== 0) {
        throw new RuntimeException(trim($stderr !== '' ? $stderr : ($stdout !== '' ? $stdout : 'CloudDB restore failed during import.')));
    }
}
function decrypt_local_backup_payload(string $payload): string {
    if (!str_starts_with($payload, 'CLDB1') || strlen($payload) < 21) {
        throw new RuntimeException('CloudDB restore failed: unsupported local backup format.');
    }
    $iv = substr($payload, 5, 16);
    $cipher = substr($payload, 21);
    $plain = openssl_decrypt($cipher, 'AES-256-CBC', hash('sha256', BACKUP_KEY, true), OPENSSL_RAW_DATA, $iv);
    if ($plain === false) {
        throw new RuntimeException('CloudDB restore failed: unable to decrypt local backup payload.');
    }
    $sql = gzdecode($plain);
    return $sql === false ? $plain : $sql;
}
function run_shell_restore_pipeline(string $filePath): void {
    if (DIRECTORY_SEPARATOR === '\\') {
        throw new RuntimeException('CloudDB restore failed: shell restore is unavailable on Windows.');
    }
    if (!is_readable(BACKUP_DB_CNF)) {
        throw new RuntimeException('CloudDB restore failed: MySQL credential file is not readable.');
    }
    $mysqlBinary = resolve_mysql_cli_binary();
    $gzipCommand = command_exists('gunzip') ? 'gunzip' : 'gzip -d -c';
    $command = 'openssl enc -d -aes-256-cbc -pbkdf2 -pass '
        . escapeshellarg('pass:' . BACKUP_KEY)
        . ' -in ' . escapeshellarg($filePath)
        . ' | ' . $gzipCommand
        . ' | ' . escapeshellarg($mysqlBinary)
        . ' --defaults-extra-file=' . escapeshellarg(BACKUP_DB_CNF);
    $process = proc_open($command, [
        1 => ['pipe', 'w'],
        2 => ['pipe', 'w'],
    ], $pipes);
    if (!is_resource($process)) {
        throw new RuntimeException('CloudDB restore failed: unable to start the restore pipeline.');
    }
    $stdout = stream_get_contents($pipes[1]) ?: '';
    fclose($pipes[1]);
    $stderr = stream_get_contents($pipes[2]) ?: '';
    fclose($pipes[2]);
    $exitCode = proc_close($process);
    if ($exitCode !== 0) {
        throw new RuntimeException(trim($stderr !== '' ? $stderr : ($stdout !== '' ? $stdout : 'CloudDB restore pipeline failed.')));
    }
}
function restore_backup_file(PDO $pdo, string $fileName, ?string $dbName = null): array {
    $path = resolve_backup_file($fileName);
    if (!is_file($path) || !is_readable($path)) {
        throw new RuntimeException('Backup file was not found on this node.');
    }
    if ($dbName !== null && $dbName !== '') {
        reset_database_for_restore($pdo, $dbName);
    }
    $handle = fopen($path, 'rb');
    if ($handle === false) {
        throw new RuntimeException('Backup file could not be opened.');
    }
    $prefix = (string)fread($handle, 8);
    fclose($handle);
    if (str_starts_with($prefix, 'CLDB1')) {
        $payload = file_get_contents($path);
        if ($payload === false) {
            throw new RuntimeException('Backup file could not be read.');
        }
        import_sql_payload(decrypt_local_backup_payload($payload));
    } else {
        run_shell_restore_pipeline($path);
    }
    return [
        'message' => ($dbName !== null && $dbName !== '')
            ? ('Backup restored into ' . $dbName . '.')
            : 'Full-node backup restored.',
        'file' => basename($path),
    ];
}
function queue_backup_job(array $dbNames = []): array {
    if (!backup_script_ready()) throw new RuntimeException('CloudDB backup engine is not installed.');
    if (!is_readable(BACKUP_DB_CNF)) throw new RuntimeException('CloudDB backup credentials are not readable.');
    if (!is_dir(BACKUP_DIR) || !is_writable(BACKUP_DIR)) throw new RuntimeException('CloudDB backup directory is not writable.');
    $cleanNames = [];
    foreach ($dbNames as $dbName) {
        $cleanNames[] = ensure_identifier((string)$dbName, 'Database name');
    }
    $cleanNames = array_values(array_unique($cleanNames));
    $label = $cleanNames
        ? preg_replace('/[^A-Za-z0-9._-]+/', '-', implode('-', array_slice($cleanNames, 0, 3)))
        : 'node-full';
    $stamp = date('Ymd-His');
    $file = BACKUP_DIR . '/' . ($label ?: 'snapshot') . '-' . $stamp . '.sql.gz.enc';
    if (preg_match('/\.php$/i', BACKUP_SCRIPT)) {
        return run_php_backup_script($file, $cleanNames);
    }
    $command = 'nohup env BACKUP_FILE=' . escapeshellarg($file) . ' ' . escapeshellarg(BACKUP_SCRIPT);
    foreach ($cleanNames as $dbName) {
        $command .= ' ' . escapeshellarg($dbName);
    }
    $command .= ' >/dev/null 2>&1 & echo $!';
    $pid = trim((string)shell_exec($command));
    return ['file' => basename($file), 'path' => $file, 'pid' => $pid];
}

$action = $_GET['action'] ?? 'stats';
$res = [];

try {
    $pdo = db();
    if ($action === 'stats') {
        $free = 0; $total = 0;
        if (is_readable('/proc/meminfo')) {
            $mem = file_get_contents('/proc/meminfo');
            if (preg_match('/MemTotal:\s+(\d+)/', $mem, $m)) $total = (int)$m[1];
            if (preg_match('/MemAvailable:\s+(\d+)/', $mem, $m)) $free = (int)$m[1];
        }
        $res = [
            'cpu' => cpu_usage_percent(),
            'ram' => $total > 0 ? round((($total - $free) / $total) * 100) : 0,
            'ram_text' => round(($total - $free)/1024/1024, 1) . 'GB / ' . round($total/1024/1024, 1) . 'GB',
            'disk' => round(((disk_total_space('/') - disk_free_space('/')) / disk_total_space('/')) * 100),
            'active_conns' => (int)$pdo->query("SHOW STATUS LIKE 'Threads_connected'")->fetch()['Value']
        ];
    } elseif ($action === 'list_tenants') {
        $sql = "SELECT SCHEMA_NAME,
                (SELECT SUM(data_length + index_length) FROM information_schema.TABLES WHERE table_schema = SCHEMA_NAME) as size_bytes
                FROM information_schema.SCHEMATA
                WHERE SCHEMA_NAME LIKE '%\\_db' ESCAPE '\\'
                  AND SCHEMA_NAME NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')";
        foreach ($pdo->query($sql) as $r) {
            $db = $r['SCHEMA_NAME']; $prefix = explode('_', $db)[0]; $u = $prefix . '_user';
            $stmt = $pdo->prepare("SELECT User, Host FROM mysql.user WHERE User = ?");
            $stmt->execute([$u]);
            $res[] = [
                'db' => $db,
                'user' => $u,
                'size_mb' => round(($r['size_bytes'] ?? 0) / 1024 / 1024, 2),
                'users' => $stmt->fetchAll()
            ];
        }
    } elseif ($action === 'update_hosts') {
        $u = ensure_identifier((string)($_POST['db_user'] ?? ''), 'Database user');
        $hosts = json_decode((string)($_POST['hosts'] ?? '[]'), true);
        if (!is_array($hosts) || !$hosts) throw new Exception("Invalid host list.");
        $hosts = normalize_allowlist_hosts($hosts);
        $p_stmt = $pdo->prepare("SELECT authentication_string FROM mysql.user WHERE User = ? AND Host = 'localhost' LIMIT 1");
        $p_stmt->execute([$u]);
        $auth_str = $p_stmt->fetchColumn();
        if (!$auth_str) throw new Exception("Base localhost user not found.");

        drop_remote_user_hosts($pdo, $u);
        $db_name = tenant_db_for_user($u);
        foreach($hosts as $h) {
            if ($h === 'localhost') continue;
            $pdo->exec("CREATE USER IF NOT EXISTS " . quoted_user_host($pdo, $u, $h) . " IDENTIFIED BY PASSWORD " . $pdo->quote((string)$auth_str));
            $pdo->exec("GRANT ALL PRIVILEGES ON " . sql_ident($db_name) . ".* TO " . quoted_user_host($pdo, $u, $h));
        }
        $pdo->exec("FLUSH PRIVILEGES");
        $res = ['message' => "IP Whitelist Synchronized."];
    } elseif ($action === 'backup_status') {
        $fileName = (string)($_GET['file'] ?? '');
        $info = backup_file_info($fileName);
        $res = $info + ['message' => $info['exists'] ? 'Backup file is available.' : 'Backup file is not ready yet.'];
    } elseif ($action === 'download_backup') {
        $fileName = (string)($_GET['file'] ?? '');
        $path = resolve_backup_file($fileName);
        if (!is_file($path) || !is_readable($path)) {
            http_response_code(404);
            header('Content-Type: text/plain; charset=UTF-8');
            echo 'Backup file not found.';
            exit;
        }
        header('Content-Type: application/octet-stream');
        header('Content-Length: ' . (string)(filesize($path) ?: 0));
        header('Content-Disposition: attachment; filename="' . basename($path) . '"');
        header('Cache-Control: private, no-store');
        readfile($path);
        exit;
    } elseif ($action === 'trigger_backup') {
        $dbNames = [];
        $singleDbName = trim((string)($_POST['db_name'] ?? ''));
        if ($singleDbName !== '') $dbNames[] = $singleDbName;
        $multiDbNames = $_POST['db_names'] ?? null;
        if ($multiDbNames !== null) {
            $decoded = json_decode((string)$multiDbNames, true);
            if (!is_array($decoded)) throw new InvalidArgumentException('Database list is invalid.');
            foreach ($decoded as $dbName) $dbNames[] = (string)$dbName;
        }
        $backup = queue_backup_job($dbNames);
        if (count($dbNames) === 1) $message = 'Backup queued for ' . ensure_identifier($dbNames[0], 'Database name') . '.';
        elseif ($dbNames) $message = 'Backup queued for ' . count(array_unique($dbNames)) . ' databases.';
        else $message = 'Full-node backup queued.';
        $res = ['message' => $message, 'file' => $backup['file'], 'path' => $backup['path'], 'pid' => $backup['pid']];
    } elseif ($action === 'restore_backup') {
        $fileName = trim((string)($_POST['file'] ?? ''));
        $dbName = trim((string)($_POST['db_name'] ?? ''));
        $restore = restore_backup_file($pdo, $fileName, $dbName !== '' ? $dbName : null);
        $res = $restore;
    } elseif ($action === 'create') {
        $prefix = ensure_identifier((string)($_POST['db_prefix'] ?? ''), 'Database prefix');
        $suffix = ensure_identifier((string)($_POST['db_suffix'] ?? ''), 'Database suffix');
        $host = ensure_host_value((string)($_POST['remote_host'] ?? '%'));
        $max_conns = (int)($_POST['max_conns'] ?? 10);
        $dbName = $prefix . '_' . $suffix; $dbUser = $prefix . '_user'; $dbPass = bin2hex(random_bytes(12));
        $pdo->exec("CREATE DATABASE " . sql_ident($dbName) . " CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci");
        $pdo->exec("CREATE USER " . quoted_user_host($pdo, $dbUser, $host) . " IDENTIFIED BY " . $pdo->quote($dbPass) . " WITH MAX_USER_CONNECTIONS $max_conns");
        if ($host !== 'localhost') $pdo->exec("CREATE USER IF NOT EXISTS " . quoted_user_host($pdo, $dbUser, 'localhost') . " IDENTIFIED BY " . $pdo->quote($dbPass) . " WITH MAX_USER_CONNECTIONS $max_conns");
        $pdo->exec("GRANT ALL PRIVILEGES ON " . sql_ident($dbName) . ".* TO " . quoted_user_host($pdo, $dbUser, $host));
        if ($host !== 'localhost') $pdo->exec("GRANT ALL PRIVILEGES ON " . sql_ident($dbName) . ".* TO " . quoted_user_host($pdo, $dbUser, 'localhost'));
        $res = ['message' => "Resource-hardened DB created.", 'download' => ['filename' => $dbName.'.env', 'content' => "DB_DATABASE=$dbName\nDB_USERNAME=$dbUser\nDB_PASSWORD=$dbPass"]];
    } elseif ($action === 'delete') {
        $dbName = ensure_identifier((string)($_POST['db_name'] ?? ''), 'Database name');
        $dbUser = ensure_identifier((string)($_POST['db_user'] ?? ''), 'Database user');
        $stmt = $pdo->prepare("SELECT Host FROM mysql.user WHERE User = ?");
        $stmt->execute([$dbUser]);
        foreach ($stmt->fetchAll(PDO::FETCH_COLUMN) as $userHost) {
            $pdo->exec("DROP USER IF EXISTS " . quoted_user_host($pdo, $dbUser, (string)$userHost));
        }
        $pdo->exec("DROP DATABASE IF EXISTS " . sql_ident($dbName));
        $res = ['message' => "Database removed."];
    } elseif ($action === 'rotate_password') {
        $dbUser = ensure_identifier((string)($_POST['db_user'] ?? ''), 'Database user');
        $dbName = tenant_db_for_user($dbUser);
        $dbPass = trim((string)($_POST['db_password'] ?? '')) ?: bin2hex(random_bytes(12));
        $stmt = $pdo->prepare("SELECT Host FROM mysql.user WHERE User = ?");
        $stmt->execute([$dbUser]);
        $hosts = $stmt->fetchAll(PDO::FETCH_COLUMN);
        if (!$hosts) throw new Exception("Database user not found.");
        foreach ($hosts as $userHost) {
            $pdo->exec("ALTER USER " . quoted_user_host($pdo, $dbUser, (string)$userHost) . " IDENTIFIED BY " . $pdo->quote($dbPass));
        }
        $res = ['message' => "Password rotated.", 'download' => ['filename' => $dbName . '.env', 'content' => "DB_DATABASE=$dbName\nDB_USERNAME=$dbUser\nDB_PASSWORD=$dbPass"]];
    }
} catch (Throwable $e) { http_response_code(500); $res = ['error' => $e->getMessage()]; }
header('Content-Type: application/json'); echo json_encode($res);
