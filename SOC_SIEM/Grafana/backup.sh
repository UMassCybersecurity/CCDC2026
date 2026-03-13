#!/bin/bash

# Simplified version - handles both files and directories

# Get paths from user
read -p "Enter Prometheus path [/etc/prometheus]: " PROMETHEUS
PROMETHEUS=${PROMETHEUS:-/etc/prometheus}

read -p "Enter Loki path [/etc/loki]: " LOKI
LOKI=${LOKI:-/etc/loki}

read -p "Enter Grafana path [/etc/grafana]: " GRAFANA
GRAFANA=${GRAFANA:-/etc/grafana}

read -p "Enter backup destination [.]: " DEST
DEST=${DEST:-.}

# Create backup
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_FILE="${DEST}/monitoring_backup_${TIMESTAMP}.tar.gz"

echo "Creating backup: $BACKUP_FILE"

# Build array of existing paths
PATHS=()
for p in "$PROMETHEUS" "$LOKI" "$GRAFANA"; do
    if [[ -e "$p" ]]; then
        PATHS+=("$p")
        if [[ -f "$p" ]]; then
            echo "  ✓ File: $p"
        elif [[ -d "$p" ]]; then
            echo "  ✓ Directory: $p"
        fi
    else
        echo "  ✗ Missing: $p"
    fi
done

# Create backup if we have any paths
if [[ ${#PATHS[@]} -gt 0 ]]; then
    tar -czf "$BACKUP_FILE" "${PATHS[@]}" 2>/dev/null

    if [[ $? -eq 0 ]]; then
        echo ""
        echo "✅ Backup created: $BACKUP_FILE"
        echo "Size: $(du -h "$BACKUP_FILE" | cut -f1)"
        echo "Contents: $(tar -tzf "$BACKUP_FILE" 2>/dev/null | wc -l) files"
    else
        echo "❌ Backup failed"
        exit 1
    fi
else
    echo "❌ No valid paths found to backup"
    exit 1
fi
