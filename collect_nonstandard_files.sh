#!/bin/bash
# Collect non-standard files (files not owned by any package)
# Useful for CCDC to identify added/modified files

set -euo pipefail

OUTPUT_DIR="${1:-./nonstandard_files_$(date +%Y%m%d_%H%M%S)}"
MANIFEST="$OUTPUT_DIR/manifest.txt"
ARCHIVE="$OUTPUT_DIR/files.tar.gz"
SUSPICIOUS_REPORT="$OUTPUT_DIR/suspicious_files.txt"

# Colors for terminal output
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Suspicious filename patterns (common backdoor/malware names)
SUSPICIOUS_NAMES=(
    "\..*\.swp"           # Hidden swap files (can hide malware)
    "^\.\..*"             # Files starting with ..
    "\s"                  # Files with spaces (evasion)
    "base64"
    "shell"
    "backdoor"
    "rootkit"
    "keylog"
    "reverse"
    "bind.*sh"
    "c99"
    "r57"
    "wso"
    "b374k"
    "weevely"
    "meterpreter"
    "payload"
    "exploit"
    "pwn"
    "hack"
    "\.php\."             # Double extensions like .php.jpg
    "\.asp\."
    "\.jsp\."
)

# Suspicious content patterns to grep for
SUSPICIOUS_CONTENT=(
    "eval.*base64_decode"
    "eval.*gzinflate"
    "eval.*str_rot13"
    "exec.*\\\$_"
    "system.*\\\$_"
    "passthru.*\\\$_"
    "shell_exec.*\\\$_"
    "/bin/sh.*-i"
    "/bin/bash.*-i"
    "nc.*-e.*/bin"
    "ncat.*-e.*/bin"
    "python.*pty.spawn"
    "perl.*socket.*exec"
    "ruby.*socket.*exec"
    "/dev/tcp/"
    "fsockopen"
    "pfsockopen"
    "proc_open"
    "expect.*spawn"
)

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

# ============================================
# SUSPICIOUS FILE ANALYSIS
# ============================================
echo ""
echo -e "${RED}=== SUSPICIOUS FILE ANALYSIS ===${NC}"
echo ""

> "$SUSPICIOUS_REPORT"
echo "# Suspicious Files Report - $(date)" >> "$SUSPICIOUS_REPORT"
echo "# Generated by collect_nonstandard_files.sh" >> "$SUSPICIOUS_REPORT"
echo "" >> "$SUSPICIOUS_REPORT"

suspicious_count=0

log_suspicious() {
    local severity="$1"
    local reason="$2"
    local file="$3"
    local details="${4:-}"

    ((suspicious_count++)) || true

    case "$severity" in
        HIGH)   color="$RED" ;;
        MEDIUM) color="$YELLOW" ;;
        *)      color="$NC" ;;
    esac

    echo -e "${color}[$severity]${NC} $reason"
    echo "        $file"
    [ -n "$details" ] && echo "        -> $details"

    echo "[$severity] $reason" >> "$SUSPICIOUS_REPORT"
    echo "  File: $file" >> "$SUSPICIOUS_REPORT"
    [ -n "$details" ] && echo "  Details: $details" >> "$SUSPICIOUS_REPORT"
    echo "" >> "$SUSPICIOUS_REPORT"
}

echo "Analyzing non-standard files for suspicious indicators..."
echo ""

# --- CHECK 1: SUID/SGID binaries ---
echo "[*] Checking for SUID/SGID files..."
while IFS= read -r file; do
    if [ -f "$file" ]; then
        perms=$(stat -c "%a" "$file" 2>/dev/null || echo "0000")
        if [[ "$perms" =~ ^[4267] ]]; then
            log_suspicious "HIGH" "SUID/SGID binary not owned by package" "$file" "Permissions: $perms"
        fi
    fi
done < "$TEMP_LIST"

# --- CHECK 2: Hidden files in system directories ---
echo "[*] Checking for hidden files in system directories..."
while IFS= read -r file; do
    filename=$(basename "$file")
    dir=$(dirname "$file")

    # Hidden file in system directory (not /home or /root)
    if [[ "$filename" == .* ]] && [[ ! "$dir" =~ ^/home ]] && [[ ! "$dir" =~ ^/root ]]; then
        # Skip common legitimate hidden files
        if [[ ! "$filename" =~ ^\.(git|svn|hg|keep|gitkeep|placeholder|htaccess|htpasswd)$ ]]; then
            log_suspicious "MEDIUM" "Hidden file in system directory" "$file"
        fi
    fi
done < "$TEMP_LIST"

# --- CHECK 3: Executables in /tmp, /var/tmp, /dev/shm ---
echo "[*] Checking for executables in temp directories..."
for tmp_dir in /tmp /var/tmp /dev/shm; do
    if [ -d "$tmp_dir" ]; then
        while IFS= read -r -d '' file; do
            if [ -x "$file" ] && [ -f "$file" ]; then
                filetype=$(file -b "$file" 2>/dev/null | head -c 50)
                log_suspicious "HIGH" "Executable in temp directory" "$file" "$filetype"
            fi
        done < <(find "$tmp_dir" -type f -print0 2>/dev/null)
    fi
done

# --- CHECK 4: World-writable files in system directories ---
echo "[*] Checking for world-writable files..."
while IFS= read -r file; do
    if [ -f "$file" ]; then
        dir=$(dirname "$file")
        # Only flag in system directories
        if [[ "$dir" =~ ^/(usr|bin|sbin|lib|etc) ]]; then
            perms=$(stat -c "%a" "$file" 2>/dev/null || echo "000")
            if [[ "${perms: -1}" =~ [2367] ]]; then
                log_suspicious "HIGH" "World-writable file in system directory" "$file" "Permissions: $perms"
            fi
        fi
    fi
done < "$TEMP_LIST"

# --- CHECK 5: Suspicious filenames ---
echo "[*] Checking for suspicious filenames..."
while IFS= read -r file; do
    filename=$(basename "$file")
    filename_lower=$(echo "$filename" | tr '[:upper:]' '[:lower:]')

    for pattern in "${SUSPICIOUS_NAMES[@]}"; do
        if echo "$filename_lower" | grep -qiE "$pattern" 2>/dev/null; then
            log_suspicious "MEDIUM" "Suspicious filename pattern" "$file" "Matched: $pattern"
            break
        fi
    done
done < "$TEMP_LIST"

# --- CHECK 6: ELF binaries in unusual locations ---
echo "[*] Checking for ELF binaries in unusual locations..."
while IFS= read -r file; do
    dir=$(dirname "$file")
    # Check files not in standard binary locations
    if [[ ! "$dir" =~ ^/(usr/)?(local/)?(s?bin|lib|lib64) ]] && [[ ! "$dir" =~ ^/opt ]]; then
        if [ -f "$file" ]; then
            filetype=$(file -b "$file" 2>/dev/null || echo "")
            if [[ "$filetype" =~ ^ELF ]]; then
                log_suspicious "HIGH" "ELF binary in unusual location" "$file" "$filetype"
            fi
        fi
    fi
done < "$TEMP_LIST"

# --- CHECK 7: Recently modified files in /etc, /usr (last 24h) ---
echo "[*] Checking for recently modified system files (24h)..."
for sys_dir in /etc /usr/bin /usr/sbin /usr/lib; do
    if [ -d "$sys_dir" ]; then
        while IFS= read -r -d '' file; do
            if ! is_package_file "$file" 2>/dev/null; then
                mtime=$(stat -c "%y" "$file" 2>/dev/null | cut -d'.' -f1)
                log_suspicious "MEDIUM" "Recently modified system file" "$file" "Modified: $mtime"
            fi
        done < <(find "$sys_dir" -type f -mtime -1 -print0 2>/dev/null)
    fi
done

# --- CHECK 8: Scripts with suspicious content ---
echo "[*] Checking for suspicious content in scripts..."
while IFS= read -r file; do
    if [ -f "$file" ]; then
        # Only check text files under 1MB
        size=$(stat -c "%s" "$file" 2>/dev/null || echo "0")
        if [ "$size" -lt 1048576 ]; then
            filetype=$(file -b "$file" 2>/dev/null || echo "")
            if [[ "$filetype" =~ (text|script|PHP|ASCII) ]]; then
                for pattern in "${SUSPICIOUS_CONTENT[@]}"; do
                    if grep -qE "$pattern" "$file" 2>/dev/null; then
                        match=$(grep -oE "$pattern" "$file" 2>/dev/null | head -1)
                        log_suspicious "HIGH" "Suspicious code pattern" "$file" "Pattern: $match"
                        break
                    fi
                done
            fi
        fi
    fi
done < "$TEMP_LIST"

# --- CHECK 9: Unusual cron entries ---
echo "[*] Checking for unusual cron entries..."
for cron_dir in /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly /var/spool/cron /var/spool/cron/crontabs; do
    if [ -d "$cron_dir" ]; then
        while IFS= read -r -d '' file; do
            if ! is_package_file "$file" 2>/dev/null; then
                log_suspicious "HIGH" "Non-package cron entry" "$file"
            fi
        done < <(find "$cron_dir" -type f -print0 2>/dev/null)
    fi
done

# --- CHECK 10: Unusual systemd units ---
echo "[*] Checking for unusual systemd units..."
for systemd_dir in /etc/systemd/system /usr/lib/systemd/system; do
    if [ -d "$systemd_dir" ]; then
        while IFS= read -r -d '' file; do
            if ! is_package_file "$file" 2>/dev/null; then
                # Skip symlinks to /dev/null (disabled services)
                if [ ! -L "$file" ] || [ "$(readlink -f "$file")" != "/dev/null" ]; then
                    log_suspicious "MEDIUM" "Non-package systemd unit" "$file"
                fi
            fi
        done < <(find "$systemd_dir" -maxdepth 1 -type f -name "*.service" -print0 2>/dev/null)
    fi
done

# --- CHECK 11: SSH authorized_keys anomalies ---
echo "[*] Checking SSH authorized_keys..."
while IFS= read -r -d '' file; do
    if [ -f "$file" ]; then
        key_count=$(wc -l < "$file" 2>/dev/null || echo 0)
        if [ "$key_count" -gt 0 ]; then
            # Check for command= restrictions or unusual options
            if grep -qE "^(command=|no-pty|from=)" "$file" 2>/dev/null; then
                log_suspicious "MEDIUM" "SSH key with forced command/restrictions" "$file" "Keys: $key_count"
            fi
            # Just report existence
            log_suspicious "LOW" "SSH authorized_keys found" "$file" "Contains $key_count key(s)"
        fi
    fi
done < <(find /home /root -name "authorized_keys" -print0 2>/dev/null)

# --- CHECK 12: Processes with deleted binaries ---
echo "[*] Checking for processes with deleted binaries..."
if [ -d /proc ]; then
    for pid_dir in /proc/[0-9]*; do
        if [ -d "$pid_dir" ]; then
            exe_link=$(readlink "$pid_dir/exe" 2>/dev/null || echo "")
            if [[ "$exe_link" =~ \(deleted\) ]]; then
                pid=$(basename "$pid_dir")
                cmdline=$(tr '\0' ' ' < "$pid_dir/cmdline" 2>/dev/null | head -c 100)
                log_suspicious "HIGH" "Process running from deleted binary" "$exe_link" "PID: $pid CMD: $cmdline"
            fi
        fi
    done
fi

# --- CHECK 13: Unusual /etc/passwd or /etc/shadow entries ---
echo "[*] Checking for unusual user accounts..."
if [ -f /etc/passwd ]; then
    # Check for UID 0 accounts other than root
    while IFS=: read -r user _ uid _ _ _ shell; do
        if [ "$uid" = "0" ] && [ "$user" != "root" ]; then
            log_suspicious "HIGH" "Non-root account with UID 0" "/etc/passwd" "User: $user"
        fi
        # Check for users with login shells that shouldn't have them
        if [[ "$shell" =~ (bash|sh|zsh|fish)$ ]] && [[ "$user" =~ ^(www-data|nobody|daemon|sys|bin|mail|news|proxy|backup|list|irc|gnats|_).*$ ]]; then
            log_suspicious "MEDIUM" "System user with login shell" "/etc/passwd" "User: $user Shell: $shell"
        fi
    done < /etc/passwd
fi

# Summary
echo ""
echo "============================================"
echo -e "Suspicious file analysis complete: ${RED}$suspicious_count items flagged${NC}"
echo "============================================"
echo ""

# Severity summary
high_count=$(grep -c "^\[HIGH\]" "$SUSPICIOUS_REPORT" 2>/dev/null || echo 0)
medium_count=$(grep -c "^\[MEDIUM\]" "$SUSPICIOUS_REPORT" 2>/dev/null || echo 0)
low_count=$(grep -c "^\[LOW\]" "$SUSPICIOUS_REPORT" 2>/dev/null || echo 0)

echo -e "  ${RED}HIGH:${NC}   $high_count"
echo -e "  ${YELLOW}MEDIUM:${NC} $medium_count"
echo "  LOW:    $low_count"

echo ""
echo "=== Output Files ==="
echo "Manifest:          $MANIFEST"
echo "Archive:           $ARCHIVE"
echo -e "${RED}Suspicious Report: $SUSPICIOUS_REPORT${NC}"
echo ""
echo "Done!"
