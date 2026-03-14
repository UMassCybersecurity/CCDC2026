#!/bin/bash
# Collect non-standard files (files not owned by any package)
# Useful for CCDC to identify added/modified files
# Simple version - no suspicious file analysis

set -euo pipefail

OUTPUT_DIR="${1:-./nonstandard_files_$(date +%Y%m%d_%H%M%S)}"
MANIFEST="$OUTPUT_DIR/manifest.txt"
ARCHIVE="$OUTPUT_DIR/files.tar.gz"

# Directories to scan (avoiding pseudo-filesystems)
SCAN_DIRS=(
    /etc
    /usr
    /bin
    /sbin
    /lib
    /lib64
    /opt
    /var/www
    /var/lib
    /var/spool/cron
    /home
    /root
)

# Directories to always skip
SKIP_PATTERNS=(
    "/proc"
    "/sys"
    "/dev"
    "/run"
    "/tmp"
    "/var/tmp"
    "/var/cache"
    "/var/log"
    "/var/run"
    "*.pyc"
    "*/__pycache__/*"
    "/usr/share/mime/*"
    "/var/lib/docker/*"
)

echo "=== Non-Standard File Collector ==="
echo "Output directory: $OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

# Detect package manager
detect_pkg_manager() {
    if command -v rpm &>/dev/null && [ -d /var/lib/rpm ]; then
        echo "rpm"
    elif command -v dpkg &>/dev/null && [ -d /var/lib/dpkg ]; then
        echo "dpkg"
    else
        echo "unknown"
    fi
}

PKG_MGR=$(detect_pkg_manager)
echo "Detected package manager: $PKG_MGR"

# Build exclude arguments for find
build_excludes() {
    local excludes=""
    for pattern in "${SKIP_PATTERNS[@]}"; do
        excludes="$excludes -path '$pattern' -prune -o"
    done
    echo "$excludes"
}

# Check if file is owned by a package
is_package_file() {
    local file="$1"
    case "$PKG_MGR" in
        rpm)
            rpm -qf "$file" &>/dev/null
            return $?
            ;;
        dpkg)
            dpkg -S "$file" &>/dev/null
            return $?
            ;;
        *)
            # Unknown package manager - assume not a package file
            return 1
            ;;
    esac
}

# Find non-standard files
echo ""
echo "Scanning for non-standard files..."
echo "This may take several minutes depending on system size."
echo ""

TEMP_LIST=$(mktemp)
trap "rm -f $TEMP_LIST" EXIT

count=0
for dir in "${SCAN_DIRS[@]}"; do
    if [ -d "$dir" ]; then
        echo "Scanning: $dir"

        # Find regular files, excluding skip patterns
        while IFS= read -r -d '' file; do
            # Skip if matches any skip pattern
            skip=false
            for pattern in "${SKIP_PATTERNS[@]}"; do
                if [[ "$file" == $pattern ]]; then
                    skip=true
                    break
                fi
            done

            if [ "$skip" = true ]; then
                continue
            fi

            # Check if owned by package manager
            if ! is_package_file "$file" 2>/dev/null; then
                echo "$file" >> "$TEMP_LIST"
                ((count++)) || true

                # Progress indicator
                if ((count % 100 == 0)); then
                    echo "  Found $count non-standard files so far..."
                fi
            fi
        done < <(find "$dir" -type f -print0 2>/dev/null || true)
    fi
done

echo ""
echo "Found $count non-standard files total."

# Create manifest with file details
echo ""
echo "Creating manifest with file details..."
echo "# Non-standard files manifest - $(date)" > "$MANIFEST"
echo "# Format: permissions|owner|group|size|mtime|path" >> "$MANIFEST"
echo "" >> "$MANIFEST"

while IFS= read -r file; do
    if [ -f "$file" ]; then
        stat --printf="%A|%U|%G|%s|%y|%n\n" "$file" >> "$MANIFEST" 2>/dev/null || true
    fi
done < "$TEMP_LIST"

# Create archive
echo ""
echo "Creating archive of non-standard files..."
if [ -s "$TEMP_LIST" ]; then
    tar -czf "$ARCHIVE" --files-from="$TEMP_LIST" --ignore-failed-read 2>/dev/null || {
        echo "Warning: Some files could not be archived (permission denied)"
    }

    archive_size=$(du -h "$ARCHIVE" 2>/dev/null | cut -f1)
    echo "Archive created: $ARCHIVE ($archive_size)"
else
    echo "No files to archive."
fi

# Summary by directory
echo ""
echo "=== Summary by Directory ==="
if [ -s "$TEMP_LIST" ]; then
    awk -F'/' '{
        if (NF >= 2) {
            dir = "/" $2
            if (NF >= 3) dir = dir "/" $3
            counts[dir]++
        }
    } END {
        for (d in counts) printf "%6d  %s\n", counts[d], d
    }' "$TEMP_LIST" | sort -rn | head -20
fi

echo ""
echo "=== Output Files ==="
echo "Manifest: $MANIFEST"
echo "Archive:  $ARCHIVE"
echo ""
echo "Done!"
