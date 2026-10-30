<?php
require_once __DIR__ . '/config.php';

function db(): PDO {
    static $pdo = null;
    if ($pdo === null) {
        $pdo = new PDO('mysql:host=' . DB_HOST . ';dbname=' . DB_NAME . ';charset=utf8mb4', DB_USER, DB_PASS, [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
        ]);
    }
    return $pdo;
}

// Logs go to stderr, collected by Docker (no more /var/log/geststock nor logrotate).
function app_log(string $level, string $msg): void {
    $line = sprintf("[%s] %s geststock: %s\n", date('c'), strtoupper($level), $msg);
    file_put_contents('php://stderr', $line);
}
