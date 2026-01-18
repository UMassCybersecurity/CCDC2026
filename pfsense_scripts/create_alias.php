<?php
require_once("config.inc");
require_once("functions.inc");
require_once("filter.inc");
require_once("shaper.inc");

global $config;

echo "--- Starting Alias Creation ---\n";

// [!] CONFIGURATION
$team_id = 10; 

// Subnet Definitions
$private_net  = "10.0." . $team_id . ".0/25";    // 10.0.10.0/25
$screened_net = "10.0." . $team_id . ".128/26";  // 10.0.10.128/26
$branch_net   = "fd00:" . $team_id . ":0:3::/64"; // IPv6 Only

// Define Aliases
$aliases_to_add = array(
    array(
        "name"    => "NET_Private",
        "type"    => "network", 
        "address" => $private_net,
        "descr"   => "Tier 1: Critical Infra (AD/DB)"
    ),
    array(
        "name"    => "NET_Screened",
        "type"    => "network", 
        "address" => $screened_net,
        "descr"   => "Tier 2: DMZ (Web)"
    ),
    array(
        "name"    => "NET_Branch",
        "type"    => "network", 
        "address" => $branch_net,
        "descr"   => "Tier 3: Branch (IPv6 Kiosks)"
    )
);

// [!] PROCESSING
if (!is_array($config['aliases'])) { $config['aliases'] = array(); }
if (!is_array($config['aliases']['alias'])) { $config['aliases']['alias'] = array(); } 
elseif (isset($config['aliases']['alias']['name'])) { $config['aliases']['alias'] = array($config['aliases']['alias']); }

foreach ($aliases_to_add as $new_alias) {
    $found = false;
    foreach ($config['aliases']['alias'] as &$existing) {
        if ($existing['name'] == $new_alias['name']) {
            $existing = $new_alias; // Update existing
            $found = true;
            echo "Updated Alias: " . $new_alias['name'] . "\n";
            break;
        }
    }
    unset($existing);
    if (!$found) { 
        $config['aliases']['alias'][] = $new_alias; 
        echo "Created Alias: " . $new_alias['name'] . "\n";
    }
}

write_config("Script: Created Topology Aliases");
echo "--- Alias Creation Complete ---\n";
?>