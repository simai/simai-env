<?php
header('Content-Type: application/json');
try {
    require dirname(__DIR__) . '/bootstrap.php';
    $amount = $pdo->query('SELECT amount FROM simai_canary WHERE id = 1')->fetchColumn();
    echo json_encode(['fixture' => 'simai-env-canary', 'release' => 'v1', 'amount' => (int)$amount]);
} catch (Throwable $error) {
    http_response_code(503);
    echo json_encode(['fixture' => 'simai-env-canary', 'error' => 'database-unavailable']);
}
