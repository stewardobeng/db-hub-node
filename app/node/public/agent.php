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
    if ($value === '%') return $value;
    if (filter_var($value, FILTER_VALIDATE_IP)) return $value;
    if (preg_match('/^[A-Za-z0-9._:%-]{1,255}$/', $value)) return $value;
    throw new InvalidArgumentException('Host value is invalid.');
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
function queue_backup_job(array $dbNames = []): array {
    if (!is_file(BACKUP_SCRIPT) || !is_executable(BACKUP_SCRIPT)) throw new RuntimeException('CloudDB backup engine is not installed.');
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
            'cpu' => min(100, round((sys_getloadavg()[0] / (int)shell_exec('nproc')) * 100)),
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
        $hosts = array_values(array_unique(array_map('ensure_host_value', $hosts)));
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
