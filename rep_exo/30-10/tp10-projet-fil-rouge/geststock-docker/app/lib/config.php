<?php
// Configuration from the environment (12-factor). Defaults keep the legacy behaviour.
function env(string $name, string $default = ''): string {
    $value = getenv($name);
    return ($value === false || $value === '') ? $default : $value;
}

// The DB password comes from a secret file (DB_PASS_FILE), never from git nor from the image.
function secret(string $name, string $default = ''): string {
    $file = env($name . '_FILE');
    if ($file !== '' && is_readable($file)) {
        return trim(file_get_contents($file));
    }
    return env($name, $default);
}

define('DB_HOST', env('DB_HOST', 'db'));
define('DB_NAME', env('DB_NAME', 'geststock'));
define('DB_USER', env('DB_USER', 'geststock'));
define('DB_PASS', secret('DB_PASS'));
define('UPLOAD_DIR', rtrim(env('UPLOAD_DIR', '/var/www/html/uploads'), '/') . '/');
define('SMTP_HOST', env('SMTP_HOST', 'localhost'));
define('REPORT_TO', env('REPORT_TO', 'direction@shop.example'));
