#!/bin/bash
# based strongly on https://gitlab.com/nuccdc/tools/-/blob/master/scripts/unix/change_all_passwords.sh

SHADOW_BACKUP="/var/log/password_hash_backup.csv"
CSV_LOG="/var/log/generated_passwords.csv"

# Must be root
if [ "$(id -u)" -ne 0 ]; then
    echo "You must be root to run this script."
    exit 1
fi

read -r -p "Enter path to wordlist file: " WORDLIST

# Check wordlist
if [ ! -f "$WORDLIST" ]; then
    echo "Wordlist not found: $WORDLIST"
    exit 1
fi

# Initialize CSV & backup
if [ ! -f "$CSV_LOG" ]; then
    echo "username,password,timestamp" > "$CSV_LOG"
    chmod 600 "$CSV_LOG"
fi

if [ ! -f "$SHADOW_BACKUP" ]; then
    echo "username,hash,timestamp" > "$SHADOW_BACKUP"
    chmod 600 "$SHADOW_BACKUP"
fi

# Get loginnable users
users=$(grep -E 'sh$|bash$|zsh$' /etc/passwd | cut -d: -f1)

echo "Press 'y' to change password of the specified user, anything else to skip."
echo

### SHADOW BACKUP (OVERKILL) (USE AT OWN RISK)
# SHADOW_COPY="/var/log/etc_shadow_copy"
# cp /etc/shadow $SHADOW_COPY
# chmod 600 $SHADOW_COPY

for user in $users; do

    # Backup current hash
    current_hash = $(grep "^$user:" /etc/shadow | cut d: -f2)
    
    if [ -z "$current_hash" ] || [ "$current_hash" = "!" ] || [ "$current_hash" = "*" ]; then
	    echo "No valid password hash found for $user (account may be locked)"
    else
	    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	    echo "$user,$current_hash,$timestamp" >> "$SHADOW_BACKUP"
    fi
   
    # Prompt-per-user
    read -p "Change password for user '$user'? [y/n] " answer
    if [ "$answer" != "y" ]; then
        echo "Skipping $user"
        continue
    fi

    # Generate password
    word1=$(shuf -n 1 "$WORDLIST")
    word2=$(shuf -n 1 "$WORDLIST")
    word3=$(shuf -n 1 "$WORDLIST")
    num=$((RANDOM % 10000))
    password="${word1}-${word2}-${word3}-${num}"

    # Hash password (SHA-512)
    hash=$(echo "$password" | openssl passwd -6 -stdin)

    # Apply password
    if usermod --password "$hash" "$user"; then
        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        echo "$user,$password,$timestamp" >> "$CSV_LOG"
        echo "Password changed for $user"
    else
        echo "Failed to change password for $user" >&2
    fi

    echo

done
    echo "Output of all changes saved to $CSV_LOG"
    echo "A backup of old hashes saved to $SHADOW_BACKUP"
    # echo "A copy of /etc/shadow (please never use this) saved to $SHADOW_COPY"
    echo "Remove the files once you no longer need them with shred -u FILEPATH"
