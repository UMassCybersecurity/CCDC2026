#!/usr/bin/env python3
"""Minimal WordPress restore script - restores files and database using pure Python."""

import os
import re
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

try:
    import pymysql
except ImportError:
    print("pymysql not installed. Run: pip install pymysql")
    sys.exit(1)


class Colors:
    RED = "\033[0;31m"
    GREEN = "\033[0;32m"
    YELLOW = "\033[1;33m"
    CYAN = "\033[0;36m"
    NC = "\033[0m"


def log_info(msg): print(f"{Colors.GREEN}[INFO]{Colors.NC} {msg}")
def log_warn(msg): print(f"{Colors.YELLOW}[WARN]{Colors.NC} {msg}")
def log_error(msg): print(f"{Colors.RED}[ERROR]{Colors.NC} {msg}")
def log_step(msg): print(f"{Colors.CYAN}[STEP]{Colors.NC} {msg}")


def parse_wp_config(config_path):
    """Parse wp-config.php for database credentials."""
    if not config_path.exists():
        return None

    content = config_path.read_text()

    def extract_define(key):
        match = re.search(rf"define\s*\(\s*['\"]({key})['\"]\s*,\s*['\"]([^'\"]*)['\"]", content)
        if match:
            return match.group(2)
        match = re.search(rf"define\s*\(\s*['\"]({key})['\"]\s*,\s*getenv_docker\s*\([^,]+,\s*['\"]([^'\"]*)['\"]", content)
        if match:
            return match.group(2)
        return ""

    db_host = extract_define("DB_HOST") or "localhost"
    db_port = 3306
    if ":" in db_host:
        db_host, port_str = db_host.rsplit(":", 1)
        db_port = int(port_str)

    return {
        "name": extract_define("DB_NAME"),
        "user": extract_define("DB_USER"),
        "pass": extract_define("DB_PASSWORD"),
        "host": db_host,
        "port": db_port,
    }


def list_backup_contents(backup_dir):
    """List what's in the backup directory."""
    backup_dir = Path(backup_dir)
    print()
    log_info("Backup contents:")

    files = {
        "wordpress-full.tar.gz": "Full WordPress backup",
        "wp-config.php": "WordPress configuration",
        ".htaccess": "Apache rewrite rules",
    }

    for fname, desc in files.items():
        path = backup_dir / fname
        if path.exists():
            size = path.stat().st_size / (1024 * 1024)
            print(f"  [x] {fname} ({size:.1f} MB) - {desc}")
        else:
            print(f"  [ ] {fname} - {desc}")

    sql_files = list(backup_dir.glob("database_*.sql")) + list(backup_dir.glob("database_*.sql.gz"))
    if sql_files:
        for sql_file in sql_files:
            size = sql_file.stat().st_size / (1024 * 1024)
            print(f"  [x] {sql_file.name} ({size:.1f} MB) - Database dump")
    else:
        print(f"  [ ] database_*.sql - Database dump")

    print()


def restore_database(backup_dir, creds):
    """Restore database using pymysql."""
    backup_dir = Path(backup_dir)

    sql_files = list(backup_dir.glob("database_*.sql")) + list(backup_dir.glob("database_*.sql.gz"))
    if not sql_files:
        log_warn("No database dump found")
        return False

    sql_file = sql_files[0]
    is_gzipped = sql_file.suffix == ".gz"

    log_step(f"Restoring database from {sql_file.name}...")
    log_info(f"Connecting to {creds['host']}:{creds['port']}...")

    # First connect without database to create it if needed
    try:
        conn = pymysql.connect(
            host=creds["host"],
            port=creds["port"],
            user=creds["user"],
            password=creds["pass"],
            charset='utf8mb4',
            connect_timeout=10,
        )
    except pymysql.Error as e:
        log_error(f"Database connection failed: {e}")
        return False

    log_info("Database connection successful")

    # Create database if it doesn't exist
    cursor = conn.cursor()
    try:
        cursor.execute(f"CREATE DATABASE IF NOT EXISTS `{creds['name']}`")
        log_info(f"Database '{creds['name']}' ready")
    except pymysql.Error as e:
        log_error(f"Could not create database: {e}")
        conn.close()
        return False

    cursor.execute(f"USE `{creds['name']}`")

    # Read SQL file
    log_info("Reading SQL dump...")
    if is_gzipped:
        import gzip
        with gzip.open(sql_file, 'rt', encoding='utf-8') as f:
            sql_content = f.read()
    else:
        sql_content = sql_file.read_text(encoding='utf-8')

    # Execute SQL statements
    log_info("Executing SQL statements...")

    # Split into statements (simple split on semicolon + newline)
    # This handles most cases but may fail on complex statements with semicolons in strings
    statements = []
    current = []
    for line in sql_content.split('\n'):
        # Skip comments and empty lines
        stripped = line.strip()
        if stripped.startswith('--') or not stripped:
            continue
        current.append(line)
        if stripped.endswith(';'):
            statements.append('\n'.join(current))
            current = []

    if current:
        statements.append('\n'.join(current))

    log_info(f"Executing {len(statements)} statements...")

    executed = 0
    errors = 0
    for stmt in statements:
        stmt = stmt.strip()
        if not stmt:
            continue
        try:
            cursor.execute(stmt)
            executed += 1
        except pymysql.Error as e:
            # Log but continue - some errors are expected (e.g., DROP on non-existent table)
            if "doesn't exist" not in str(e):
                errors += 1
                if errors <= 5:
                    log_warn(f"SQL error: {e}")

    conn.commit()
    cursor.close()
    conn.close()

    log_info(f"Database restored: {executed} statements executed, {errors} errors")
    return True


def restore_files(backup_dir, target_path):
    """Restore WordPress files from tarball."""
    backup_dir = Path(backup_dir)
    target_path = Path(target_path)

    tarball = backup_dir / "wordpress-full.tar.gz"
    if not tarball.exists():
        log_error("wordpress-full.tar.gz not found")
        return False

    log_step(f"Restoring files to {target_path}...")

    if target_path.exists():
        log_info(f"Removing existing {target_path}...")
        shutil.rmtree(target_path)
    # if above doesn't work, add ignore_errors=True

    target_path.parent.mkdir(parents=True, exist_ok=True)

    with tarfile.open(tarball, "r:gz") as tar:
        root_dir = tar.getnames()[0].split('/')[0]
        tar.extractall(target_path.parent)

    extracted_path = target_path.parent / root_dir
    if extracted_path != target_path:
        extracted_path.rename(target_path)

    log_info(f"Files restored to {target_path}")
    return True


def fix_permissions(target_path, web_user="www-data"):
    """Fix file permissions."""
    target_path = Path(target_path)

    log_step("Fixing permissions...")

    # Try to find web user
    try:
        import pwd
        for user in [web_user, "apache", "nginx", "nobody"]:
            try:
                pwd.getpwnam(user)
                web_user = user
                break
            except KeyError:
                continue
        else:
            log_warn("No web user found, skipping permission fix")
            return
    except ImportError:
        log_warn("pwd module not available, skipping permission fix")
        return

    log_info(f"Setting ownership to {web_user}...")

    try:
        subprocess.run(["chown", "-R", f"{web_user}:{web_user}", str(target_path)], check=True)
        subprocess.run(["find", str(target_path), "-type", "d", "-exec", "chmod", "755", "{}", ";"], check=True)
        subprocess.run(["find", str(target_path), "-type", "f", "-exec", "chmod", "644", "{}", ";"], check=True)

        wp_config = target_path / "wp-config.php"
        if wp_config.exists():
            wp_config.chmod(0o600)

        log_info("Permissions fixed")
    except subprocess.CalledProcessError as e:
        log_warn(f"Permission fix failed (may need root): {e}")


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <backup_directory> <restore_target>")
        print(f"       {sys.argv[0]} ./backup /var/www/html")
        sys.exit(1)

    backup_dir = Path(sys.argv[1])
    target_path = Path(sys.argv[2])

    if not backup_dir.exists():
        log_error(f"Backup directory not found: {backup_dir}")
        sys.exit(1)

    log_info("=" * 50)
    log_info("WordPress Restore")
    log_info("=" * 50)

    list_backup_contents(backup_dir)

    config_file = backup_dir / "wp-config.php"
    creds = parse_wp_config(config_file)
    if not creds:
        log_error("Could not parse wp-config.php from backup")
        sys.exit(1)

    log_info(f"Database: {creds['name']} on {creds['host']}:{creds['port']}")
    log_info(f"Target: {target_path}")
    print()

    response = input(f"{Colors.YELLOW}Proceed with restore? [y/N]: {Colors.NC}")
    if response.lower() not in ('y', 'yes'):
        log_info("Cancelled")
        sys.exit(0)

    print()

    if not restore_files(backup_dir, target_path):
        log_error("File restore failed")
        sys.exit(1)

    if not restore_database(backup_dir, creds):
        log_warn("Database restore failed, files were still restored")

    fix_permissions(target_path)

    print()
    log_info("=" * 50)
    log_info("Restore complete!")
    log_info("=" * 50)
    log_info(f"WordPress restored to: {target_path}")


if __name__ == "__main__":
    main()
