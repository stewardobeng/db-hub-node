<?php
declare(strict_types=1);

require dirname(__DIR__) . DIRECTORY_SEPARATOR . 'bootstrap.php';

function backup_log(string $message): void
{
    $logDir = dirname(BACKUP_LOG);
    if (!is_dir($logDir)) {
        @mkdir($logDir, 0775, true);
    }
    @file_put_contents(BACKUP_LOG, '[' . date('c') . '] ' . $message . PHP_EOL, FILE_APPEND);
}

function command_exists(string $command): bool
{
    $check = DIRECTORY_SEPARATOR === '\\'
        ? @shell_exec('where ' . escapeshellarg($command) . ' 2>NUL')
        : @shell_exec('command -v ' . escapeshellarg($command) . ' 2>/dev/null');
    return trim((string)$check) !== '';
}

function resolve_mysqldump_binary(): string
{
    $candidates = [];
    if (defined('MYSQLDUMP_BIN') && MYSQLDUMP_BIN !== '') {
        $candidates[] = MYSQLDUMP_BIN;
    }
    if (PHP_BINARY !== '') {
        $candidates[] = dirname(PHP_BINARY) . DIRECTORY_SEPARATOR . '..' . DIRECTORY_SEPARATOR . 'mysql' . DIRECTORY_SEPARATOR . 'bin' . DIRECTORY_SEPARATOR . 'mysqldump.exe';
        $candidates[] = dirname(PHP_BINARY) . DIRECTORY_SEPARATOR . '..' . DIRECTORY_SEPARATOR . 'mysql' . DIRECTORY_SEPARATOR . 'bin' . DIRECTORY_SEPARATOR . 'mysqldump';
    }
    $candidates[] = 'mysqldump';
    $candidates[] = 'mariadb-dump';
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
    throw new RuntimeException('CloudDB backup failed: no dump binary found');
}

function encrypt_backup_payload(string $payload): string
{
    if (BACKUP_KEY === '') {
        throw new RuntimeException('CloudDB backup failed: BACKUP_KEY is not configured');
    }
    $iv = random_bytes(16);
    $cipher = openssl_encrypt($payload, 'AES-256-CBC', hash('sha256', BACKUP_KEY, true), OPENSSL_RAW_DATA, $iv);
    if ($cipher === false) {
        throw new RuntimeException('CloudDB backup failed: unable to encrypt payload');
    }
    return 'CLDB1' . $iv . $cipher;
}

function prune_old_backups(): void
{
    $retentionDays = max(1, (int)(getenv('BACKUP_RETENTION_DAYS') ?: 30));
    $threshold = time() - ($retentionDays * 86400);
    foreach (glob(rtrim(BACKUP_DIR, DIRECTORY_SEPARATOR) . DIRECTORY_SEPARATOR . '*.enc') ?: [] as $file) {
        if (is_file($file) && @filemtime($file) !== false && filemtime($file) < $threshold) {
            @unlink($file);
        }
    }
}

try {
    if (!is_readable(BACKUP_DB_CNF)) {
        throw new RuntimeException('CloudDB backup failed: MySQL credential file is not readable');
    }
    if (!is_dir(BACKUP_DIR)) {
        @mkdir(BACKUP_DIR, 0775, true);
    }
    $outFile = getenv('BACKUP_FILE') ?: rtrim(BACKUP_DIR, DIRECTORY_SEPARATOR) . DIRECTORY_SEPARATOR . 'auto-' . date('Y-m-d-His') . '.sql.gz.enc';
    $dumpBinary = resolve_mysqldump_binary();
    $dbNames = array_values(array_filter(array_map('strval', array_slice($argv, 1))));
    $command = [
        $dumpBinary,
        '--defaults-extra-file=' . BACKUP_DB_CNF,
        '--single-transaction',
        '--quick',
        '--routines',
        '--events',
    ];
    if ($dbNames) {
        $command[] = '--databases';
        foreach ($dbNames as $dbName) {
            $command[] = $dbName;
        }
    } else {
        $command[] = '--all-databases';
    }
    backup_log('CloudDB backup started -> ' . $outFile);
    $process = proc_open($command, [
        1 => ['pipe', 'w'],
        2 => ['pipe', 'w'],
    ], $pipes, dirname($dumpBinary), null, ['bypass_shell' => true]);
    if (!is_resource($process)) {
        throw new RuntimeException('CloudDB backup failed: unable to start dump process');
    }
    $dump = stream_get_contents($pipes[1]) ?: '';
    fclose($pipes[1]);
    $stderr = stream_get_contents($pipes[2]) ?: '';
    fclose($pipes[2]);
    $exitCode = proc_close($process);
    if ($exitCode !== 0) {
        throw new RuntimeException('CloudDB backup failed: ' . trim($stderr !== '' ? $stderr : 'mysqldump exited with an error'));
    }
    $compressed = function_exists('gzencode') ? gzencode($dump, 6) : $dump;
    if ($compressed === false) {
        throw new RuntimeException('CloudDB backup failed: unable to compress dump');
    }
    $payload = encrypt_backup_payload($compressed);
    if (@file_put_contents($outFile, $payload) === false) {
        throw new RuntimeException('CloudDB backup failed: unable to write backup file');
    }
    prune_old_backups();
    backup_log('CloudDB backup finished -> ' . $outFile);
    fwrite(STDOUT, basename($outFile) . PHP_EOL);
    exit(0);
} catch (Throwable $e) {
    backup_log($e->getMessage());
    fwrite(STDERR, $e->getMessage() . PHP_EOL);
    exit(1);
}
