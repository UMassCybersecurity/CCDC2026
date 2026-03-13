#!/bin/bash
## run as sudo ./add_promjobs.sh
## Script to add prometheus jobs to the box siem

set -e  # Exit on error

# Default configuration
PROMETHEUS_CONFIG="/etc/prometheus/prometheus.yml"
BACKUP_DIR="/etc/prometheus/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_message() {
    echo -e "${2}${1}${NC}"
}

# Function to validate IP address
validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        for octet in $(echo $ip | tr '.' ' '); do
            if [[ $octet -gt 255 ]] || [[ $octet -lt 0 ]]; then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

# Function to validate port
validate_port() {
    local port=$1
    if [[ $port =~ ^[0-9]+$ ]] && [[ $port -ge 1 ]] && [[ $port -le 65535 ]]; then
        return 0
    fi
    return 1
}

# Function to validate file path
validate_file_path() {
    local path=$1
    local dir_path=$(dirname "$path")

    # Check if directory exists
    if [[ ! -d "$dir_path" ]]; then
        return 1
    fi

    # Check if file exists (optional - we can create it if it doesn't)
    # Just return 0 as long as the directory exists
    return 0
}

# Function to configure Prometheus settings
configure_prometheus_settings() {
    clear
    print_message "══════════════════════════════════════════════" "$BLUE"
    print_message "     Prometheus Configuration Setup" "$BLUE"
    print_message "══════════════════════════════════════════════" "$BLUE"
    echo ""

    # Get Prometheus config file path
    while true; do
        read -p "Enter Prometheus configuration file path [$PROMETHEUS_CONFIG]: " input_path
        if [[ -z "$input_path" ]]; then
            # Use default
            break
        elif validate_file_path "$input_path"; then
            PROMETHEUS_CONFIG="$input_path"
            break
        else
            print_message "Invalid path. Directory does not exist: $(dirname "$input_path")" "$RED"
        fi
    done

    # Get backup directory
    while true; do
        read -p "Enter backup directory path [$BACKUP_DIR]: " input_backup
        if [[ -z "$input_backup" ]]; then
            # Use default
            break
        else
            BACKUP_DIR="$input_backup"
            break
        fi
    done

    # Create backup directory if it doesn't exist
    mkdir -p "$BACKUP_DIR"

    # Check if config file exists, if not ask if we should create it
    if [[ ! -f "$PROMETHEUS_CONFIG" ]]; then
        print_message "Configuration file does not exist: $PROMETHEUS_CONFIG" "$YELLOW"
        read -p "Would you like to create a basic configuration file? (y/n): " create_config

        if [[ "$create_config" =~ ^[Yy]$ ]]; then
            create_basic_config
        else
            print_message "Exiting. Please create the configuration file manually." "$RED"
            exit 1
        fi
    fi

    print_message "\nConfiguration set:" "$GREEN"
    print_message "  Config file: $PROMETHEUS_CONFIG" "$GREEN"
    print_message "  Backup dir:  $BACKUP_DIR" "$GREEN"
    echo ""
}

# Function to create basic Prometheus configuration
create_basic_config() {
    cat > "$PROMETHEUS_CONFIG" << 'EOF'
# Basic Prometheus configuration
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    monitor: 'prometheus-monitor'

# Alertmanager configuration
alerting:
  alertmanagers:
    - static_configs:
        - targets: []

# Rule files
rule_files:
  # - "alert_rules.yml"

# Scrape configurations
scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
EOF

    print_message "✓ Created basic Prometheus configuration at $PROMETHEUS_CONFIG" "$GREEN"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   print_message "This script must be run as root (use sudo)" "$RED"
   exit 1
fi

# Initial configuration
configure_prometheus_settings

# Create backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"

# Create backup of current config
print_message "Creating backup of current configuration..." "$YELLOW"
cp "$PROMETHEUS_CONFIG" "$BACKUP_DIR/prometheus.yml.backup_$TIMESTAMP"
print_message "✓ Backup created at $BACKUP_DIR/prometheus.yml.backup_$TIMESTAMP" "$GREEN"

# Function to add Windows AD job
add_windows_ad_job() {
    local ip=$1
    local job_name="windows_ad_$2"
    local port=${3:-9182}  # Default Windows exporter port
    local scrape_interval=${4:-30s}
    local scrape_timeout=${5:-10s}

    cat << EOF >> "$PROMETHEUS_CONFIG"

  - job_name: '$job_name'
    static_configs:
      - targets: ['$ip:$port']
    metrics_path: /metrics
    scrape_interval: $scrape_interval
    scrape_timeout: $scrape_timeout
    # Windows AD specific labels
    labels:
      job_type: 'windows_ad'
      environment: 'production'
      location: '$2'
      exporter_type: 'windows_exporter'
EOF

    print_message "✓ Added Windows AD job: $job_name ($ip:$port)" "$GREEN"
}

# Function to add ADFS job
add_adfs_job() {
    local ip=$1
    local job_name="adfs_$2"
    local port=${3:-9182}  # Default Windows exporter port
    local scrape_interval=${4:-30s}
    local scrape_timeout=${5:-10s}

    cat << EOF >> "$PROMETHEUS_CONFIG"

  - job_name: '$job_name'
    static_configs:
      - targets: ['$ip:$port']
    metrics_path: /metrics
    scrape_interval: $scrape_interval
    scrape_timeout: $scrape_timeout
    # ADFS specific labels
    labels:
      job_type: 'adfs'
      environment: 'production'
      location: '$2'
      exporter_type: 'windows_exporter'
EOF

    print_message "✓ Added ADFS job: $job_name ($ip:$port)" "$GREEN"
}

# Function to validate YAML syntax
validate_yaml() {
    if command -v python3 &> /dev/null; then
        python3 -c "import yaml; yaml.safe_load(open('$PROMETHEUS_CONFIG'))" 2>/dev/null
        if [[ $? -eq 0 ]]; then
            return 0
        else
            return 1
        fi
    elif command -v python &> /dev/null; then
        python -c "import yaml; yaml.safe_load(open('$PROMETHEUS_CONFIG'))" 2>/dev/null
        if [[ $? -eq 0 ]]; then
            return 0
        else
            return 1
        fi
    else
        # Can't validate, assume it's ok
        print_message "Warning: Python not found, skipping YAML validation" "$YELLOW"
        return 0
    fi
}

# Function to reload Prometheus
reload_prometheus() {
    local service_name=""

    # Try to find Prometheus service name
    if systemctl list-units --full -all | grep -q "prometheus.service"; then
        service_name="prometheus"
    elif systemctl list-units --full -all | grep -q "prometheus-server.service"; then
        service_name="prometheus-server"
    elif systemctl list-units --full -all | grep -q "prometheus2.service"; then
        service_name="prometheus2"
    fi

    if [[ -n "$service_name" ]] && systemctl is-active --quiet "$service_name"; then
        print_message "\nReloading Prometheus configuration..." "$YELLOW"

        # Try reload first, then restart
        if systemctl reload "$service_name" 2>/dev/null; then
            print_message "✓ Prometheus configuration reloaded successfully" "$GREEN"
        elif systemctl restart "$service_name" 2>/dev/null; then
            print_message "✓ Prometheus restarted successfully" "$GREEN"
        else
            print_message "⚠ Failed to reload/restart Prometheus. Please check service manually." "$RED"
        fi
    elif [[ -n "$service_name" ]]; then
        print_message "\nPrometheus service ($service_name) is not running." "$YELLOW"
        read -p "Would you like to start it now? (y/n): " start_prom
        if [[ "$start_prom" =~ ^[Yy]$ ]]; then
            systemctl start "$service_name"
            print_message "✓ Prometheus started" "$GREEN"
        fi
    else
        print_message "\nCould not detect Prometheus service. Please reload/restart manually." "$YELLOW"
    fi
}

# Function to show current config
show_current_config() {
    print_message "\nCurrent Prometheus configuration:" "$YELLOW"
    echo "══════════════════════════════════════════════"

    if [[ -f "$PROMETHEUS_CONFIG" ]]; then
        # Show job entries
        echo -e "\n${BLUE}Scrape Jobs:${NC}"
        grep -A 15 "job_name:" "$PROMETHEUS_CONFIG" | head -100 | sed 's/^/  /'

        # Show file info
        echo -e "\n${BLUE}File Information:${NC}"
        echo "  Path: $PROMETHEUS_CONFIG"
        echo "  Size: $(du -h "$PROMETHEUS_CONFIG" | cut -f1)"
        echo "  Modified: $(date -r "$PROMETHEUS_CONFIG" "+%Y-%m-%d %H:%M:%S")"

        # Validate YAML if Python is available
        if command -v python3 &> /dev/null || command -v python &> /dev/null; then
            if validate_yaml; then
                print_message "  YAML Syntax: ✓ Valid" "$GREEN"
            else
                print_message "  YAML Syntax: ✗ Invalid" "$RED"
            fi
        fi
    else
        print_message "Configuration file not found!" "$RED"
    fi

    echo ""
    read -p "Press Enter to continue..."
}

# Function to list backups
list_backups() {
    print_message "\nAvailable backups in $BACKUP_DIR:" "$YELLOW"
    echo "──────────────────────────────────"
    if [[ -d "$BACKUP_DIR" ]] && [[ "$(ls -A "$BACKUP_DIR")" ]]; then
        ls -lh "$BACKUP_DIR" | grep "prometheus.yml.backup_" | awk '{print $9, "("$5")", "-", $6, $7, $8}'
    else
        print_message "No backups found." "$YELLOW"
    fi
    echo ""
}

# Main menu
while true; do
    clear
    print_message "══════════════════════════════════════════════" "$YELLOW"
    print_message "     Prometheus Job Addition Script" "$YELLOW"
    print_message "══════════════════════════════════════════════" "$YELLOW"
    echo ""
    print_message "Current Configuration:" "$BLUE"
    print_message "  Config: $PROMETHEUS_CONFIG" "$BLUE"
    print_message "  Backup: $BACKUP_DIR" "$BLUE"
    echo ""
    print_message "1. Add Windows AD monitoring job" "$GREEN"
    print_message "2. Add ADFS monitoring job" "$GREEN"
    print_message "3. Add both AD and ADFS jobs" "$GREEN"
    print_message "4. View current Prometheus configuration" "$GREEN"
    print_message "5. List available backups" "$GREEN"
    print_message "6. Restore from backup" "$GREEN"
    print_message "7. Change Prometheus configuration" "$GREEN"
    print_message "8. Test configuration syntax" "$GREEN"
    print_message "9. Exit" "$GREEN"
    echo ""
    read -p "Select option (1-9): " option

    case $option in
        1|2|3)
            # Get IP address
            while true; do
                read -p "Enter the IP address of the Windows server: " ip_address
                if validate_ip "$ip_address"; then
                    break
                else
                    print_message "Invalid IP address format. Please try again." "$RED"
                fi
            done

            # Get location/identifier
            read -p "Enter a location/identifier for this server (e.g., dc1, nyc, prod): " location
            location=${location:-"unknown"}

            # Get port (optional)
            read -p "Enter Windows exporter port [default: 9182]: " port
            port=${port:-9182}

            if ! validate_port "$port"; then
                print_message "Invalid port number. Using default 9182." "$YELLOW"
                port=9182
            fi

            # Get scrape interval
            read -p "Enter scrape interval [default: 30s]: " scrape_interval
            scrape_interval=${scrape_interval:-"30s"}

            # Get scrape timeout
            read -p "Enter scrape timeout [default: 10s]: " scrape_timeout
            scrape_timeout=${scrape_timeout:-"10s"}

            # Add the selected job(s)
            case $option in
                1) add_windows_ad_job "$ip_address" "$location" "$port" "$scrape_interval" "$scrape_timeout" ;;
                2) add_adfs_job "$ip_address" "$location" "$port" "$scrape_interval" "$scrape_timeout" ;;
                3)
                    add_windows_ad_job "$ip_address" "$location" "$port" "$scrape_interval" "$scrape_timeout"
                    add_adfs_job "$ip_address" "${location}_adfs" "$port" "$scrape_interval" "$scrape_timeout"
                    ;;
            esac

            print_message "\n✓ Configuration updated successfully!" "$GREEN"

            # Validate configuration
            if validate_yaml; then
                print_message "✓ YAML syntax is valid" "$GREEN"
            else
                print_message "⚠ Warning: YAML syntax may be invalid. Please check the configuration." "$RED"
            fi

            read -p "Press Enter to continue..."
            ;;

        4)
            show_current_config
            ;;

        5)
            list_backups
            read -p "Press Enter to continue..."
            ;;

        6)
            list_backups
            read -p "Enter backup filename to restore (e.g., prometheus.yml.backup_20240101_120000): " backup_file

            if [[ -f "$BACKUP_DIR/$backup_file" ]]; then
                # Create backup of current before restore
                cp "$PROMETHEUS_CONFIG" "$BACKUP_DIR/prometheus.yml.pre_restore_$TIMESTAMP"
                cp "$BACKUP_DIR/$backup_file" "$PROMETHEUS_CONFIG"
                print_message "✓ Configuration restored from $backup_file" "$GREEN"
                print_message "Previous config backed up as prometheus.yml.pre_restore_$TIMESTAMP" "$YELLOW"
            else
                print_message "Backup file not found!" "$RED"
            fi
            read -p "Press Enter to continue..."
            ;;

        7)
            configure_prometheus_settings
            # Recreate backup with new config
            mkdir -p "$BACKUP_DIR"
            cp "$PROMETHEUS_CONFIG" "$BACKUP_DIR/prometheus.yml.backup_${TIMESTAMP}_new"
            print_message "✓ Configuration updated and backed up" "$GREEN"
            read -p "Press Enter to continue..."
            ;;

        8)
            if validate_yaml; then
                print_message "✓ YAML syntax is valid!" "$GREEN"
            else
                print_message "✗ YAML syntax is invalid!" "$RED"
            fi
            read -p "Press Enter to continue..."
            ;;

        9)
            print_message "Exiting..." "$YELLOW"

            # Ask about reload
            read -p "Would you like to reload Prometheus now? (y/n): " reload_now
            if [[ "$reload_now" =~ ^[Yy]$ ]]; then
                reload_prometheus
            fi

            exit 0
            ;;

        *)
            print_message "Invalid option. Please select 1-9" "$RED"
            sleep 2
            ;;
    esac
done
