<?php
// Larena Panel placeholder, installed by `simai-admin.sh panel install`
// until the Larena build replaces it. It proves the path the panel will use:
// this site's account -> sudo -> panel gateway. It shows no server data,
// because it has no sign-in.
declare(strict_types=1);

function gateway(array $request): ?array
{
    $proc = proc_open(['sudo', '-n', '/usr/local/sbin/simai-panel-gate'],
        [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
    if (!is_resource($proc)) {
        return null;
    }
    fwrite($pipes[0], json_encode($request));
    fclose($pipes[0]);
    $out = stream_get_contents($pipes[1]);
    fclose($pipes[1]);
    fclose($pipes[2]);
    proc_close($proc);
    $answer = json_decode((string) $out, true);
    return is_array($answer) ? $answer : null;
}

function setup_token(): ?string
{
    $env = @file_get_contents(dirname(__DIR__) . '/.env');
    if ($env !== false && preg_match('/^SIMAI_PANEL_SETUP_TOKEN=([a-f0-9]{64})$/m', $env, $m)) {
        return $m[1];
    }
    return null;
}

$answer = gateway([
    'schema' => 'simai-panel-request/1',
    'request_id' => 'placeholder-' . bin2hex(random_bytes(6)),
    'actor' => ['user' => 'panel-placeholder', 'owner' => null],
    'command' => 'self:commands',
    'args' => new stdClass(),
]);
$gatewayOk = ($answer['status'] ?? '') === 'ok';
$token = setup_token();
$given = is_string($_GET['setup'] ?? null) ? $_GET['setup'] : '';
$setup = $given === '' ? 'none' : (($token !== null && hash_equals($token, $given)) ? 'valid' : 'invalid');

if (($_GET['format'] ?? '') === 'json') {
    header('Content-Type: application/json');
    echo json_encode(['panel' => 'placeholder', 'gateway' => $gatewayOk ? 'ok' : 'unavailable', 'setup' => $setup]), "\n";
    exit;
}
header('Content-Type: text/html; charset=utf-8');
?><!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>Larena Panel</title>
<style>
  body { font: 16px/1.5 system-ui, sans-serif; max-width: 40rem; margin: 4rem auto; padding: 0 1rem; color: #1d2330; background: #f6f7f9; }
  .card { background: #fff; border-radius: 12px; padding: 1.5rem 2rem; box-shadow: 0 1px 3px rgba(0,0,0,.08); }
  .ok { color: #137a3a; } .bad { color: #b42318; }
  code { background: #eef0f4; padding: .1rem .3rem; border-radius: 4px; }
</style>
</head>
<body>
<div class="card">
  <h1>Larena Panel</h1>
  <p>The panel is installed as a placeholder. The Larena build will replace this page.</p>
  <p>Gateway: <strong class="<?= $gatewayOk ? 'ok' : 'bad' ?>"><?= $gatewayOk ? 'reachable' : 'not reachable' ?></strong></p>
  <?php if ($setup !== 'none'): ?>
  <p>Setup link: <strong class="<?= $setup === 'valid' ? 'ok' : 'bad' ?>"><?= $setup === 'valid' ? 'valid' : 'not valid' ?></strong></p>
  <?php endif; ?>
  <p>Install the panel build: <code>simai-admin.sh panel install --domain &lt;this domain&gt; --git &lt;url&gt; --ref &lt;tag&gt;</code></p>
</div>
</body>
</html>
