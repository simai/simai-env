<?php
// Simple health check: PHP, filesystem, database.
$status = [
    'php_version' => PHP_VERSION,
    'extensions' => [
        'pdo_mysql' => extension_loaded('pdo_mysql'),
        'mbstring' => extension_loaded('mbstring'),
        'curl' => extension_loaded('curl'),
    ],
    'fs' => [
        'storage_writable' => is_writable(__DIR__ . '/../storage') || is_writable(__DIR__ . '/storage') || is_writable(__DIR__),
        'cache_writable' => is_writable(__DIR__ . '/../bootstrap/cache') || is_writable(__DIR__ . '/bootstrap/cache') || is_writable(__DIR__),
    ],
    'db' => [
        'checked' => false,
        'ok' => false,
        'error' => null,
    ],
];

// load .env if present (simple parser)
$envPath = __DIR__ . '/../.env';
if (file_exists($envPath)) {
    $lines = file($envPath, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    foreach ($lines as $line) {
        if (strpos(ltrim($line), '#') === 0) {
            continue;
        }
        if (!str_contains($line, '=')) {
            continue;
        }
        [$k, $v] = explode('=', $line, 2);
        $k = trim($k);
        $v = trim($v, " \t\n\r\0\x0B\"'");
        if ($k !== '') {
            putenv("$k=$v");
        }
    }
}

$dbHost = getenv('DB_HOST') ?: '127.0.0.1';
$dbPort = getenv('DB_PORT') ?: '3306';
$dbName = getenv('DB_DATABASE') ?: null;
$dbUser = getenv('DB_USERNAME') ?: null;
$dbPass = getenv('DB_PASSWORD') ?: null;

if ($dbName && $dbUser) {
    $status['db']['checked'] = true;
    $dsn = "mysql:host={$dbHost};port={$dbPort};dbname={$dbName};charset=utf8mb4";
    try {
        $pdo = new PDO($dsn, $dbUser, $dbPass, [
            PDO::ATTR_TIMEOUT => 3,
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        ]);
        $pdo->query('SELECT 1');
        $status['db']['ok'] = true;
    } catch (Throwable $e) {
        $status['db']['ok'] = false;
        $status['db']['error'] = $e->getMessage();
    }
}

$dbOk = !$status['db']['checked'] || $status['db']['ok'] === true;
$allOk = $status['extensions']['pdo_mysql'] && $dbOk;

http_response_code($allOk ? 200 : 500);
header('Content-Type: application/json');
echo json_encode($status, JSON_PRETTY_PRINT);
