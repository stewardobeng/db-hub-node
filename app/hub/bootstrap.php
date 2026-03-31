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

clouddb_define('APP_NAME', 'CloudDB');
clouddb_define('APP_ENV', 'production');
clouddb_define('ADMIN_USER', 'admin');
clouddb_define('ADMIN_HASH', password_hash('ChangeMe123!', PASSWORD_DEFAULT));
clouddb_define('ADMIN_EMAIL', '');
clouddb_define('APP_SECRET', 'local-dev-secret-change-me');
clouddb_define('PAYSTACK_SECRET', '');
clouddb_define('PAYSTACK_CURRENCY', 'NGN');
clouddb_define('SMTP_HOST', '');
clouddb_define('SMTP_PORT', '587');
clouddb_define('SMTP_USER', '');
clouddb_define('SMTP_PASS', '');
clouddb_define('SMTP_FROM', 'noreply@clouddb.io');

if (!defined('HUB_DB_PATH')) {
    $hubDbPath = clouddb_env('HUB_DB_PATH');
    define(
        'HUB_DB_PATH',
        $hubDbPath !== null
            ? clouddb_resolve_path($hubDbPath, __DIR__)
            : $storageRoot . DIRECTORY_SEPARATOR . 'hub_v5.sqlite'
    );
}
