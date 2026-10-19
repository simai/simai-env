<?php
$env = parse_ini_file(__DIR__ . '/.env', false, INI_SCANNER_RAW);
if (!is_array($env)) {
    throw new RuntimeException('Canary environment is unavailable');
}
$pdo = new PDO(
    'mysql:host=' . ($env['DB_HOST'] ?? 'localhost') . ';dbname=' . $env['DB_DATABASE'] . ';charset=utf8mb4',
    $env['DB_USERNAME'], $env['DB_PASSWORD'],
    [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]
);
