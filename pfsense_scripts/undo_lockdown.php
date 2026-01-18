<?php
require_once("config.inc");
require_once("filter.inc");
require_once("shaper.inc");

global $config;

echo "\n---------------------------------------------------\n";
echo "      STARTING ROLLBACK (UNDO LOCKDOWN)           \n";
echo "---------------------------------------------------\n";

$deleted_count = 0;
$restored_count = 0;

if (is_array($config['filter']['rule'])) {
    
    // We iterate through the rules to find what needs to be fixed
    foreach ($config['filter']['rule'] as $key => &$rule) {
        
        // 1. DELETE rules created by the Lockdown script
        // We look for descriptions starting with "LOCKDOWN:"
        if (isset($rule['descr']) && strpos($rule['descr'], 'LOCKDOWN:') === 0) {
            unset($config['filter']['rule'][$key]);
            $deleted_count++;
            continue; // Skip to next rule
        }

        // 2. RESTORE rules that were disabled
        // We look for the tag we added: "(DISABLED by Lockdown)"
        if (isset($rule['descr']) && strpos($rule['descr'], '(DISABLED by Lockdown)') !== false) {
            
            // A. Re-enable the rule (Unset the 'disabled' flag)
            if (isset($rule['disabled'])) {
                unset($rule['disabled']);
            }
            
            // B. Restore the original description (Remove the tag)
            $rule['descr'] = str_replace(" (DISABLED by Lockdown)", "", $rule['descr']);
            
            $restored_count++;
        }
    }
    // Clean up the array keys after unsetting items
    $config['filter']['rule'] = array_values($config['filter']['rule']);
}

// ==========================================================
// APPLY CHANGES
// ==========================================================

if ($deleted_count > 0 || $restored_count > 0) {
    write_config("Reverted Egress Lockdown (Undo Script)");
    filter_configure();
    
    echo "\n===================================================\n";
    echo "               ROLLBACK COMPLETE                   \n";
    echo "===================================================\n";
    echo "1. CLEANUP:\n";
    echo "   [-] Removed $deleted_count Lockdown rules (Block/Whitelist).\n";
    echo "\n2. RESTORATION:\n";
    echo "   [+] Re-enabled $restored_count original rules.\n";
    echo "   [+] Restored original rule descriptions.\n";
    echo "\n---------------------------------------------------\n";
    echo "System state restored to Pre-Lockdown configuration.\n";
    echo "---------------------------------------------------\n";
} else {
    echo "\n[INFO] No Lockdown artifacts found. System was already clean.\n";
}
?>