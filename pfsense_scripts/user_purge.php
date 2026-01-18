/* ---------------------------------------------------------
   SCRIPT 2: USER PURGE (PRESERVE ADMIN & ENABLE SSH)
   --------------------------------------------------------- */
require_once("config.inc");
require_once("auth.inc");

global $config;

// 1. Purge all users except admin
if (is_array($config['system']['user'])) {
    $keepers = array();
    foreach ($config['system']['user'] as $user) {
        if ($user['name'] === 'admin') {
            // Keep admin as-is without modifying the password field
            $keepers[] = $user;
            echo "Admin account preserved (password unchanged).\n";
        } else {
            echo "Deleted user: " . $user['name'] . "\n";
        }
    }
    $config['system']['user'] = $keepers;
}

// 2. ENABLE SSH Password Auth (Safety Net)
// Setting this to false ensures password-based SSH login is allowed
$config['system']['ssh']['no_passwordauth'] = false;

write_config("Purged users and enabled SSH password auth via script");
echo "User purge complete. SSH Password Login is ENABLED.\n";