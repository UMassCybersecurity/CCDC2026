<?php
require_once("config.inc");
require_once("functions.inc");
require_once("filter.inc");

global $config;

$scoring_ips = "10.20.5.0/24"; 
$alias_name  = "Scoring_Engine_Team";
$interface = 'wan';

// --- CRITICAL FIX: Ensure the config is an array, not a string ---
if (!is_array($config['aliases'])) {
    $config['aliases'] = array();
}
if (!is_array($config['aliases']['alias'])) {
    $config['aliases']['alias'] = array();
}

// 1. Add Alias (Safe now)
$config['aliases']['alias'][] = array(
    'name'    => $alias_name,
    'address' => $scoring_ips,
    'descr'   => 'CCDC Scoring Engine',
    'type'    => 'network'
);

// 2. Add Rule to Top
$scoring_rule = array(
    'type'        => 'pass',
    'interface'   => $interface,
    'ipprotocol'  => 'inet46',
    'protocol'    => 'tcp/udp',
    'source'      => array('address' => $alias_name),
    'destination' => array('any' => true),
    'descr'       => 'Allow Scoring Engine acces to internal network.',
    'created'     => array('time' => time(), 'username' => 'root@script')
);

// Check filter rule array too, just in case
if (!is_array($config['filter']['rule'])) {
    $config['filter']['rule'] = array();
}

array_unshift($config['filter']['rule'], $scoring_rule); 

// 3. Save and Apply
write_config("Added Scoring Rules");
filter_configure();
echo "Done.\n Created Scoring Engine alias. \n Rules to allow scoring ips to access internal network";
?>