<?php

/*
|--------------------------------------------------------------------------
| composer test:dusk
|--------------------------------------------------------------------------
|
| Everything a browser-test run needs, in the right order, with the cleanup
| guaranteed. WP8.
|
| A Dusk run is three things that have to agree with each other: a web server,
| a database, and a browser. The server is a *separate process*, so it reads
| its configuration from `.env` at the moment a request arrives — which is why
| `RefreshDatabase` cannot work here and why the database has to be a real file
| both processes can open. This script is what makes those three agree:
|
|   1. `.env` is swapped for `.env.dusk.local` (the original goes to
|      `.env.dusk-backup`) and the config cache is cleared, so the server, the
|      test process and every artisan call below see one configuration.
|   2. The Dusk database is created and migrated fresh, and the Dusk private
|      storage tree (storage/app/private/dusk) is emptied — a run writes real
|      pack, asset and paint files, and stale ones from a previous run are a
|      source of tests that pass for the wrong reason.
|   3. A `php artisan serve` is started on the port `APP_URL` names, unless
|      something is already listening there — so a developer who prefers to
|      keep a server in its own window can, and `php artisan dusk` on its own
|      still works.
|   4. `php artisan dusk` runs, forwarding any arguments (`--filter=…`,
|      `--browse`, a path).
|   5. The server is stopped and `.env` is put back, on *every* exit path
|      including Ctrl-C — a run that leaves the development `.env` replaced by
|      the testing one is a much worse failure than a red test.
|
| It is deliberately a plain script rather than an artisan command: it has to
| rewrite `.env` and then boot the application, which is not something a
| process that has already booted the application can honestly do.
|
*/

$root = dirname(__DIR__);
chdir($root);

$php = PHP_BINARY;
$isWindows = str_starts_with(strtoupper(PHP_OS_FAMILY), 'WIN');

$envFile = $root.'/.env';
$duskEnvFile = $root.'/.env.dusk.local';
$backupFile = $root.'/.env.dusk-backup';

/**
 * Say something, in the shape the rest of the toolchain says things.
 */
$line = static function (string $message): void {
    fwrite(STDOUT, '  '.$message.PHP_EOL);
};

$fail = static function (string $message): never {
    fwrite(STDERR, PHP_EOL.'  DUSK  '.$message.PHP_EOL.PHP_EOL);
    exit(1);
};

/**
 * Run a command to completion, inheriting stdout/stderr.
 *
 * @param  array<int, string>  $command
 */
$run = static function (array $command) use ($isWindows): int {
    $process = proc_open(
        $command,
        [0 => STDIN, 1 => STDOUT, 2 => STDERR],
        $pipes,
        null,
        null,
        $isWindows ? ['bypass_shell' => true] : [],
    );

    if (! is_resource($process)) {
        return 1;
    }

    return proc_close($process);
};

/**
 * Is anything accepting connections there?
 */
$listening = static function (string $host, int $port): bool {
    $socket = @fsockopen($host, $port, $errno, $error, 0.4);

    if ($socket === false) {
        return false;
    }

    fclose($socket);

    return true;
};

if (! is_file($duskEnvFile)) {
    $fail('.env.dusk.local is missing. It is committed — restore it before running browser tests.');
}

if (! is_file($root.'/public/build/manifest.json')) {
    $fail('public/build is missing. Dusk drives the real Inertia pages: run `npm run build` first.');
}

/*
 * Where the browser is going to point. Parsed out of the Dusk env rather than
 * hard-coded, so the port lives in exactly one place.
 *
 * Read with a regex rather than `parse_ini_file`, which chokes on perfectly
 * ordinary dotenv values (`${APP_NAME}` interpolation, bare `!` and `&`).
 */
if (preg_match('/^\s*APP_URL\s*=\s*(.+)$/m', (string) file_get_contents($duskEnvFile), $matches) !== 1) {
    $fail('.env.dusk.local has no APP_URL.');
}

$appUrl = trim(trim($matches[1]), "\"'");
$host = parse_url($appUrl, PHP_URL_HOST) ?: '127.0.0.1';
$port = (int) (parse_url($appUrl, PHP_URL_PORT) ?: 80);

if ($port === 80) {
    $fail('.env.dusk.local APP_URL must name a port for `php artisan serve` to bind to.');
}

/*
 * Cleanup, registered before the first thing that needs cleaning up. Both a
 * shutdown function (normal exit, fatal error, uncaught throwable) and a
 * signal handler (Ctrl-C), because on the failure paths where this matters
 * most only one of the two fires.
 */
$server = null;
$serverPid = null;
$swapped = false;

$cleanup = static function () use (&$server, &$serverPid, &$swapped, $envFile, $backupFile, $isWindows, $line): void {
    if ($server !== null && is_resource($server)) {
        // `php artisan serve` runs the built-in server as a *child*, so
        // terminating the artisan process alone would orphan the thing
        // actually holding the port. Kill the tree.
        if ($isWindows && $serverPid !== null) {
            exec('taskkill /F /T /PID '.((int) $serverPid).' 2>&1', $output, $status);
        } else {
            proc_terminate($server, defined('SIGTERM') ? SIGTERM : 15);
        }

        proc_close($server);
        $server = null;
    }

    if ($swapped && is_file($backupFile)) {
        copy($backupFile, $envFile);
        unlink($backupFile);
        $swapped = false;
        $line('.env restored.');
    }
};

register_shutdown_function($cleanup);

if (function_exists('pcntl_signal') && function_exists('pcntl_async_signals')) {
    pcntl_async_signals(true);
    pcntl_signal(SIGINT, static fn () => exit(130));
    pcntl_signal(SIGTERM, static fn () => exit(143));
} elseif (function_exists('sapi_windows_set_ctrl_handler')) {
    sapi_windows_set_ctrl_handler(static fn () => exit(130));
}

/*
 * 1. Swap the environment.
 *
 * `php artisan dusk` would do this itself, by this same filename convention —
 * but only for its own process tree, and only after the server has already
 * started. Doing it up front is what lets the server be started against the
 * Dusk database at all. Dusk then finds `.env` byte-identical to
 * `.env.dusk.local` and skips its own swap, so the two never fight.
 */
if (is_file($envFile)) {
    copy($envFile, $backupFile);
}

copy($duskEnvFile, $envFile);
$swapped = true;
$line('.env swapped for .env.dusk.local.');

// A cached config would out-rank the file that was just written.
$run([$php, 'artisan', 'config:clear', '--quiet']);

/*
 * 2. A database of its own, migrated from nothing, and an empty private tree.
 */
$database = $root.'/database/dusk.sqlite';

if (! is_file($database)) {
    touch($database);
}

$line('Migrating '.basename($database).' fresh…');

if ($run([$php, 'artisan', 'migrate:fresh', '--force', '--quiet']) !== 0) {
    $fail('migrate:fresh failed on the Dusk database.');
}

$deleteTree = static function (string $directory) use (&$deleteTree): void {
    if (! is_dir($directory)) {
        return;
    }

    /** @var array<int, string> $entries */
    $entries = scandir($directory) ?: [];

    foreach ($entries as $entry) {
        if ($entry === '.' || $entry === '..') {
            continue;
        }

        $path = $directory.'/'.$entry;

        is_dir($path) ? $deleteTree($path) : @unlink($path);
    }

    @rmdir($directory);
};

$deleteTree($root.'/storage/app/private/dusk');
$line('Private storage tree emptied.');

/*
 * 3. A server, unless the developer is already running one.
 */
if ($listening($host, $port)) {
    $line("Reusing the server already listening on {$host}:{$port}.");
} else {
    $line("Starting php artisan serve on {$host}:{$port}…");

    $server = proc_open(
        [
            $php, 'artisan', 'serve',
            '--host='.$host,
            '--port='.$port,
            // This script rewrites .env twice; a server that restarts itself
            // when it notices would drop the connection mid-test.
            '--no-reload',
        ],
        [0 => ['pipe', 'r'], 1 => ['file', $root.'/storage/logs/dusk-serve.log', 'w'], 2 => ['redirect', 1]],
        $pipes,
        $root,
        null,
        $isWindows ? ['bypass_shell' => true] : [],
    );

    if (! is_resource($server)) {
        $fail('Could not start `php artisan serve`.');
    }

    $status = proc_get_status($server);
    $serverPid = $status['pid'] ?? null;

    $deadline = microtime(true) + 20.0;
    $up = false;

    while (microtime(true) < $deadline) {
        if ($listening($host, $port)) {
            $up = true;
            break;
        }

        usleep(200_000);
    }

    if (! $up) {
        $fail("The server never came up on {$host}:{$port} — see storage/logs/dusk-serve.log.");
    }

    $line('Server up.');
}

/*
 * 4. The tests. Everything after the script name is forwarded, so
 * `composer test:dusk -- --filter=AdminTest` works.
 */
$arguments = array_slice($argv, 1);

$exitCode = $run(array_merge([$php, 'artisan', 'dusk'], $arguments));

/*
 * 5. Cleanup runs on the way out (registered above). Leave the Dusk database
 * migrated rather than rolled back — `DatabaseMigrations` rolls back after the
 * last test, and an empty schema makes the next manual `php artisan serve`
 * against this env look broken for no reason.
 */
$run([$php, 'artisan', 'migrate', '--force', '--quiet']);

$cleanup();

exit($exitCode);
