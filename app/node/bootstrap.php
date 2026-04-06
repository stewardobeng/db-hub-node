<?php
declare(strict_types=1);

if (!function_exists('clouddb_load_env_file')) {
    function clouddb_load_env_file(string $path): void
    {
        if (!is_file($path)) {
            return;
        }

        $lines = file($path, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
        if ($lines === false) {
            return;
        }

        foreach ($lines as $line) {
            $line = trim($line);
            if ($line === '' || str_starts_with($line, '#')) {
                continue;
            }
            $parts = explode('=', $line, 2);
            if (count($parts) !== 2) {
                continue;
            }
            $name = trim($parts[0]);
            if ($name === '') {
                continue;
            }
            $value = trim($parts[1]);
            if (
                strlen($value) >= 2 &&
                (($value[0] === '"' && $value[strlen($value) - 1] === '"') ||
                ($value[0] === "'" && $value[strlen($value) - 1] === "'"))
            ) {
                $value = substr($value, 1, -1);
            }
            $_ENV[$name] = $value;
            $_SERVER[$name] = $value;
            putenv($name . '=' . $value);
        }
    }

    function clouddb_env(string $name, ?string $default = null): ?string
    {
        $value = $_ENV[$name] ?? $_SERVER[$name] ?? getenv($name);
        if ($value === false || $value === null || $value === '') {
            return $default;
        }
        return (string)$value;
    }

    function clouddb_define(string $name, string $default): void
    {
        if (!defined($name)) {
            define($name, clouddb_env($name, $default));
        }
    }

    function clouddb_resolve_path(string $path, string $baseDir): string
    {
        if ($path === '') {
            return $baseDir;
        }
        if (preg_match('/^(?:[A-Za-z]:[\\\\\\/]|[\\\\\\/])/', $path) === 1) {
            return $path;
        }
        return rtrim($baseDir, DIRECTORY_SEPARATOR) . DIRECTORY_SEPARATOR . str_replace(['/', '\\'], DIRECTORY_SEPARATOR, $path);
    }
}

clouddb_load_env_file(__DIR__ . DIRECTORY_SEPARATOR . '.env');

$storageRoot = clouddb_resolve_path(
    clouddb_env('STORAGE_PATH', 'storage') ?? 'storage',
    __DIR__
);
if (!is_dir($storageRoot)) {
    @mkdir($storageRoot, 0775, true);
}
$backupDir = clouddb_resolve_path(
    clouddb_env('BACKUP_DIR', 'storage/backups') ?? 'storage/backups',
    __DIR__
);
if (!is_dir($backupDir)) {
    @mkdir($backupDir, 0775, true);
}

clouddb_define('APP_NAME', 'CloudDB Node');
clouddb_define('API_KEY', 'local-node-key');
clouddb_define('PROV_USER', 'root');
clouddb_define('PROV_PASS', '');
if (!defined('BACKUP_DIR')) {
    define('BACKUP_DIR', $backupDir);
}
$backupScriptRef = clouddb_env('BACKUP_SCRIPT', 'bin/backup-engine.sh') ?? 'bin/backup-engine.sh';
if (DIRECTORY_SEPARATOR === '\\' && preg_match('/\.sh$/i', $backupScriptRef)) {
    $backupScriptRef = 'bin/backup-engine.php';
}
$backupScript = clouddb_resolve_path($backupScriptRef, __DIR__);
if (!defined('BACKUP_SCRIPT')) {
    define('BACKUP_SCRIPT', $backupScript);
}
$backupDbCnf = clouddb_resolve_path(
    clouddb_env('BACKUP_DB_CNF', 'storage/backup-mysql.cnf') ?? 'storage/backup-mysql.cnf',
    __DIR__
);
if (!defined('BACKUP_DB_CNF')) {
    define('BACKUP_DB_CNF', $backupDbCnf);
}
$backupLog = clouddb_resolve_path(
    clouddb_env('BACKUP_LOG', 'storage/backup.log') ?? 'storage/backup.log',
    __DIR__
);
if (!defined('BACKUP_LOG')) {
    define('BACKUP_LOG', $backupLog);
}
clouddb_define('BACKUP_KEY', 'local-backup-key');
clouddb_define('MYSQLDUMP_BIN', clouddb_env('MYSQLDUMP_BIN', '') ?? '');
clouddb_define('NODE_DB_DSN', 'mysql:host=localhost;dbname=information_schema');
