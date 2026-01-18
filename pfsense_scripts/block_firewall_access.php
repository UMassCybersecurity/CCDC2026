require_once("config.inc");
require_once("functions.inc");
require_once("filter.inc");
require_once("shaper.inc");

echo "Starting Precision Management Lockdown (The Scalpel)...\n";

// 1. Define Interfaces
$target_interfaces = ['opt1', 'opt2']; 

// 2. Define EXACT ports to block (No ranges)
$ports_to_block = [22, 80, 443];

$rules_added = 0;


foreach ($ports_to_block as $port) {
    $rule = array();
    $rule['type'] = 'block';
    $rule['interface'] = 'opt1';
    $rule['ipprotocol'] = 'inet';
    $rule['protocol'] = 'tcp/udp'; 
    $rule['source']['any'] = true;
    
    // Destination: This Firewall (Self)
    $rule['destination']['network'] = '(self)';
    $rule['destination']['port'] = $port; 
    
    $rule['descr'] = "BLOCK Port $port to restrict firewall web access";
    $rule['created'] = make_config_revision_entry();

    // Insert at TOP
    array_unshift($config['filter']['rule'], $rule);
    $rules_added++;
}

foreach ($ports_to_block as $port) {
    $rule = array();
    $rule['type'] = 'block';
    $rule['interface'] = 'opt2';
    $rule['ipprotocol'] = 'inet46';
    $rule['protocol'] = 'tcp/udp'; 
    $rule['source']['any'] = true;
    
    // Destination: This Firewall (Self)
    $rule['destination']['network'] = '(self)';
    $rule['destination']['port'] = $port; 
    
    $rule['descr'] = "BLOCK Port $port to restrict firewall web access";
    $rule['created'] = make_config_revision_entry();

    // Insert at TOP
    array_unshift($config['filter']['rule'], $rule);
    $rules_added++;
}

// 3. Save and Reload
if ($rules_added > 0) {
    write_config("Deployed $rules_added precision rules.");
    echo "Rules saved. Reloading filter... ";
    filter_configure();
    echo "Done.\n";
    echo "Only ports 22, 80, and 443 are blocked. DNS (53) is safe.\n";
} else {
    echo "No rules added.\n";
}
?>