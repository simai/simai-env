<?php
require __DIR__ . '/bootstrap.php';
if (PHP_SAPI !== 'cli') {
    exit(1);
}
$pdo->exec('CREATE TABLE IF NOT EXISTS simai_canary (id INT PRIMARY KEY, amount INT NOT NULL)');
$amount = ($argv[1] ?? 'seed') === 'mutate' ? 99 : 7;
$pdo->exec('REPLACE INTO simai_canary VALUES (1, ' . $amount . ')');
echo "canary-data-written\n";
