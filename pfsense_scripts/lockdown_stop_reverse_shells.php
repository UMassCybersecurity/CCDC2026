<?php
require_once("config.inc");
require_once("filter.inc");
require_once("shaper.inc");

global $config;

echo "Starting Egress Lockdown (Alias-Aware Mode)...\n";

// ==========================================================
// 1. CONFIGURATION: MAP INTERFACES TO ALIASES
// ==========================================================
// This ensures we use your specific network definitions as the Source.
$interface_map = array(
    'lan'  => 'NET_Private',  // LAN is the Private Subnet
    'opt1' => 'NET_Screened', // OPT1 is the Screened Subnet
    'opt2' => 'NET_Branch'    // OPT2 is the Branch Subnet
);

// Define the Whitelist (Good Traffic)
$whitelist_rules = array();

$whitelist_rules[] = array(
    'descr' => 'LOCKDOWN: Allow DNS (Safe)', 
    'protocol' => 'tcp/udp', 'dstport' => '53'
);
$whitelist_rules[] = array(
    'descr' => 'LOCKDOWN: Allow HTTP (Safe)', 
    'protocol' => 'tcp', 'dstport' => '80'
);
$whitelist_rules[] = array(
    'descr' => 'LOCKDOWN: Allow HTTPS (Safe)', 
    'protocol' => 'tcp', 'dstport' => '443'
);
$whitelist_rules[] = array(
    'descr' => 'LOCKDOWN: Allow Ping (Safe)', 
    'protocol' => 'icmp', 'dstport' => ''
);

// ==========================================================
// 2. DISABLE EXISTING "ALLOW ALL" RULES
// ==========================================================
$rules_to_disable = [
    'Default allow LAN to any rule',
    'ALLOW: Private -> Internet(ipv4+6)',
    'ALLOW: DMZ -> Internet',
    'ALLOW: Branch -> Internet (IPv6)'
];

$disabled_count = 0;

if (is_array($config['filter']['rule'])) {
    foreach ($config['filter']['rule'] as &$r) {
        if (in_array($r['descr'], $rules_to_disable)) {
            if (!isset($r['disabled'])) {
                $r['disabled'] = true;
                $r['descr'] .= " (DISABLED by Lockdown)";
                $disabled_count++;
            }
        }
    }
    unset($r); 
}

// ==========================================================
// 3. INJECT NEW RULES
// ==========================================================

// We iterate through our MAP (Interface => Alias Name)
foreach ($interface_map as $iface => $alias_name) {
    
    // A. The "Catch-All" Block Rule (Logged)
    $block_rule = array();
    $block_rule['interface'] = $iface;
    $block_rule['type'] = 'block';
    $block_rule['ipprotocol'] = 'inet46';
    
    // CORRECTED SOURCE: Use the Alias Name
    $block_rule['source'] = array('address' => $alias_name);
    
    $block_rule['destination'] = array('any' => '');
    $block_rule['log'] = true; 
    $block_rule['descr'] = "LOCKDOWN: Block & Log Everything Else ($alias_name)";
    $block_rule['created'] = make_config_revision_entry();
    
    // Check duplicates
    $exists = false;
    foreach($config['filter']['rule'] as $ex) {
        if ($ex['descr'] == $block_rule['descr'] && $ex['interface'] == $iface) { $exists = true; break; }
    }
    if (!$exists) { array_unshift($config['filter']['rule'], $block_rule); }

    // B. The Whitelist Rules (Pass)
    $whitelist_rev = array_reverse($whitelist_rules);
    
    foreach ($whitelist_rev as $template) {
        $rule = array();
        $rule['interface'] = $iface;
        $rule['type'] = 'pass';
        $rule['ipprotocol'] = 'inet46'; 
        
        // CORRECTED SOURCE: Use the Alias Name
        $rule['source'] = array('address' => $alias_name);
        
        // DESTINATION SAFETY:
        // Traffic is allowed to Internet, but NOT to the Private Network.
        // This preserves your topology segmentation (e.g. Branch can't use "Allow HTTP" to hit Private).
        $rule['destination'] = array('address' => 'NET_Private', 'not' => true);
        
        $rule['protocol'] = $template['protocol'];
        if(isset($template['dstport']) && $template['dstport'] != '') { 
            $rule['destination']['port'] = $template['dstport']; 
        }
        $rule['descr'] = $template['descr'];
        $rule['created'] = make_config_revision_entry();
        
        // Check duplicates
        $exists = false;
        foreach($config['filter']['rule'] as $ex) {
            if ($ex['descr'] == $rule['descr'] && $ex['interface'] == $iface && !isset($ex['disabled'])) { $exists = true; break; }
        }
        if (!$exists) { array_unshift($config['filter']['rule'], $rule); }
    }
}

write_config("Applied Egress Lockdown using Aliases (NET_Private/Screened/Branch)");
filter_configure();

echo "Lockdown Complete.\n";
echo "Sources updated to use aliases: NET_Private, NET_Screened, NET_Branch.\n";
?>