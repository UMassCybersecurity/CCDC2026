<?php
require_once("config.inc");
require_once("functions.inc");
require_once("filter.inc");
require_once("shaper.inc");

global $config;

echo "--- Starting Rule Enforcement ---\n";

// [!] CONFIGURATION
// Interface Mappings
$if_private  = "lan";
$if_screened = "opt1";
$if_branch   = "opt2"; 

$rules_to_add = array();

// --- BLOCKING RULES (Security First) ---

// 1. Hardening: Block unsolicited IPv6 on WAN
$rules_to_add[] = array(
    'type' => 'block', 'interface' => 'wan', 'ipprotocol' => 'inet6',
    'source' => array('any' => ''), 'destination' => array('any' => ''),
    'descr' => 'HARDENING: Block Unsolicited IPv6 Inbound on WAN'
);

// 2. Segmentation: Block DMZ from reaching Private
$rules_to_add[] = array(
    'type' => 'block', 'interface' => $if_screened, 'ipprotocol' => 'inet', 
    'source' => array('address' => 'NET_Screened'),
    'destination' => array('address' => 'NET_Private'),
    'descr' => 'BLOCK: DMZ(screened) -> Private (Lateral Movement)'
);

// 3. Segmentation: Block Branch from reaching Private
$rules_to_add[] = array(
    'type' => 'block', 'interface' => $if_branch, 'ipprotocol' => 'inet6', 
    'source' => array('address' => 'NET_Branch'),
    'destination' => array('address' => 'NET_Private'), 
    'descr' => 'BLOCK: Branch -> Private'
);


// --- ALLOW RULES (Internet Access) ---

// 4. Allow Private LAN -> Internet
$rules_to_add[] = array(
    'type' => 'pass', 'interface' => $if_private, 'ipprotocol' => 'inet46',
    'source' => array('address' => 'NET_Private'),
    'destination' => array('any' => ''),
    'descr' => 'ALLOW: Private -> Internet(ipv4+6)'
); 

// 5. Allow DMZ -> Internet (IPv4)
$rules_to_add[] = array(
    'type' => 'pass', 'interface' => $if_screened, 'ipprotocol' => 'inet',
    'source' => array('address' => 'NET_Screened'),
    'destination' => array('any' => ''),
    'descr' => 'ALLOW: DMZ -> Internet'
);

// 6. Allow Branch -> Internet (IPv6)
$rules_to_add[] = array(
    'type' => 'pass', 'interface' => $if_branch, 'ipprotocol' => 'inet6',
    'source' => array('address' => 'NET_Branch'),
    'destination' => array('any' => ''),
    'descr' => 'ALLOW: Branch -> Internet (IPv6)'
);


// [!] PROCESSING
if (!is_array($config['filter'])) { $config['filter'] = array(); }
if (!is_array($config['filter']['rule'])) { $config['filter']['rule'] = array(); }
elseif (isset($config['filter']['rule']['type'])) { $config['filter']['rule'] = array($config['filter']['rule']); }

// Reverse array so we can use array_unshift (pushes to TOP of list)
$rules_to_add = array_reverse($rules_to_add);

foreach ($rules_to_add as $rule) {
    // Check for duplicates by description to prevent spamming rules
    $exists = false;
    foreach ($config['filter']['rule'] as $existing_rule) {
        if (isset($existing_rule['descr']) && $existing_rule['descr'] == $rule['descr']) {
            $exists = true; 
            echo "Skipping Duplicate Rule: " . $rule['descr'] . "\n";
            break;
        }
    }
    if (!$exists) {
        array_unshift($config['filter']['rule'], $rule);
        echo "Added Rule: " . $rule['descr'] . "\n";
    }
}

write_config("Script: Applied Hybrid Topology Rules");
filter_configure(); // Reloads the firewall filter
echo "--- Rule Enforcement Complete ---\n";
?>