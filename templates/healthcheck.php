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
        'storage_writable' => is_writable(__DIR__ . '/storage') || is_writable(__DIR__ . '/public/storage') || is_writable(__DIR__),
        'cache_writable' => is_writable(__DIR__ . '/bootstrap/cache') || is_writable(__DIR__),
    ],
    'db' => [
        'checked' => false,
        'ok' => false,
        'error' => null,
    ],
];

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

$allOk = $status['extensions']['pdo_mysql'] && $status['db']['ok'] !== false;

http_response_code($allOk ? 200 : 500);
header('Content-Type: application/json');
echo json_encode($status, JSON_PRETTY_PRINT);
