#!/usr/bin/env python3
"""Minimal WordPress backup script - backs up files and database using pure Python."""

import os
import re
import sys
import tarfile
from pathlib import Path

try:
    import pymysql
except ImportError:
    print("pymysql not installed. Run: pip install pymysql")
    sys.exit(1)

# For ansibruh: python3 wordpress-backup.py .
print("Reminders: If running in a docker container, you will need to manually substitute in the environment values for WORDPRESS_DB_USER, WORDPRESS_DB_PASSWORD, WORDPRESS_DB_NAME, and WORDPRESS_DB_HOST since it cannot directly run the php command for the env.\nWhen restoring, the wordpress server must be down.")

# Common WordPress paths to check
WP_PATHS = [
    "/var/www/html",
    "/var/www/wordpress",
    "/var/www/html/wordpress",
    "/var/www",
    "/srv/www/htdocs",
    "/usr/share/nginx/html",
]

# Default/weak credentials to flag
DEFAULT_DB_NAMES = {"wordpress", "wp", "database", "db", "wp_database"}
DEFAULT_DB_USERS = {"root", "admin", "wordpress", "wp", "user", "dbuser"}
DEFAULT_DB_PASSWORDS = {"", "password", "root", "admin", "wordpress", "123456", "12345678", "qwerty", "letmein"}


class Colors:
    RED = "\033[0;31m"
    GREEN = "\033[0;32m"
    YELLOW = "\033[1;33m"
    CYAN = "\033[0;36m"
    NC = "\033[0m"


def log_info(msg): print(f"{Colors.GREEN}[INFO]{Colors.NC} {msg}")
def log_warn(msg): print(f"{Colors.YELLOW}[WARN]{Colors.NC} {msg}")
def log_error(msg): print(f"{Colors.RED}[ERROR]{Colors.NC} {msg}")
def log_cred(msg): print(f"{Colors.CYAN}[CRED]{Colors.NC} {msg}")
def log_alert(msg): print(f"{Colors.RED}[ALERT]{Colors.NC} {msg}")


def find_wordpress():
    """Find WordPress installations."""
    found = []
    for path in WP_PATHS:
        wp_config = Path(path) / "wp-config.php"
        if wp_config.is_file():
            found.append(path)
            log_info(f"Found WordPress: {path}")

    from glob import glob
    for pattern in ["/home/*/public_html", "/home/*/www", "/var/www/*/public_html"]:
        for path in glob(pattern):
            wp_config = Path(path) / "wp-config.php"
            if wp_config.is_file() and path not in found:
                found.append(path)
                log_info(f"Found WordPress: {path}")

    return found


def parse_wp_config(wp_path):
    """Parse wp-config.php for database credentials."""
    config_file = Path(wp_path) / "wp-config.php"
    if not config_file.exists():
        log_error(f"wp-config.php not found: {config_file}")
        return None

    content = config_file.read_text()

    def extract_define(key):
        match = re.search(rf"define\s*\(\s*['\"]({key})['\"]\s*,\s*['\"]([^'\"]*)['\"]", content)
        if match:
            return match.group(2)
        match = re.search(rf"define\s*\(\s*['\"]({key})['\"]\s*,\s*getenv_docker\s*\([^,]+,\s*['\"]([^'\"]*)['\"]", content)
        if match:
            return match.group(2)
        match = re.search(rf"define\s*\(\s*['\"]({key})['\"]\s*,.*getenv\s*\(\s*['\"]([^'\"]*)['\"]", content)
        if match:
            return os.environ.get(match.group(2), "")
        return ""

    prefix_match = re.search(r"\$table_prefix\s*=\s*['\"]([^'\"]*)['\"]", content)
    table_prefix = prefix_match.group(1) if prefix_match else "wp_"

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
        "prefix": table_prefix,
    }


def print_credentials(creds):
    """Print credentials and check for defaults."""
    print()
    log_info("=" * 50)
    log_info("Database Credentials")
    log_info("=" * 50)
    log_cred(f"DB_NAME:     {creds['name']}")
    log_cred(f"DB_USER:     {creds['user']}")
    log_cred(f"DB_PASSWORD: {creds['pass']}")
    log_cred(f"DB_HOST:     {creds['host']}")
    log_cred(f"DB_PORT:     {creds['port']}")
    log_cred(f"TABLE_PREFIX: {creds['prefix']}")
    print()

    has_defaults = False
    if creds["name"] in DEFAULT_DB_NAMES:
        log_alert(f"DEFAULT DETECTED: DB_NAME '{creds['name']}' is a common default!")
        has_defaults = True
    if creds["user"] in DEFAULT_DB_USERS:
        log_alert(f"DEFAULT DETECTED: DB_USER '{creds['user']}' is a common default!")
        has_defaults = True
    if creds["pass"] in DEFAULT_DB_PASSWORDS:
        log_alert(f"DEFAULT DETECTED: DB_PASSWORD is weak or empty!")
        has_defaults = True
    if creds["prefix"] == "wp_":
        log_warn("TABLE_PREFIX is default 'wp_' (minor security concern)")

    if has_defaults:
        print()
        log_alert("*** WARNING: Default credentials detected! Change them immediately! ***")
    print()


def escape_string(val):
    """Escape string for SQL."""
    if val is None:
        return "NULL"
    if isinstance(val, bytes):
        return "X'" + val.hex() + "'"
    if isinstance(val, (int, float)):
        return str(val)
    s = str(val)
    s = s.replace("\\", "\\\\")
    s = s.replace("'", "\\'")
    s = s.replace("\n", "\\n")
    s = s.replace("\r", "\\r")
    s = s.replace("\t", "\\t")
    return f"'{s}'"


def backup_database(creds, output_path):
    """Backup database using pymysql."""
    log_info(f"Connecting to {creds['host']}:{creds['port']}...")

    try:
        conn = pymysql.connect(
            host=creds["host"],
            port=creds["port"],
            user=creds["user"],
            password=creds["pass"],
            database=creds["name"],
            charset='utf8mb4',
            connect_timeout=10,
        )
    except pymysql.Error as e:
        log_error(f"Database connection failed: {e}")
        log_error("Possible causes:")
        log_error("  - Database server not running")
        log_error("  - Invalid credentials")
        log_error("  - Firewall blocking connection")
        log_error("  - User not allowed from this host")
        return False

    log_info("Database connection successful")

    sql_file = output_path / f"database_{creds['name']}.sql"
    log_info(f"Dumping database to {sql_file}...")

    try:
        with open(sql_file, 'w', encoding='utf-8') as f:
            cursor = conn.cursor()

            # Header
            f.write(f"-- WordPress Database Backup\n")
            f.write(f"-- Database: {creds['name']}\n")
            f.write(f"-- Host: {creds['host']}\n\n")
            f.write("SET FOREIGN_KEY_CHECKS=0;\n")
            f.write("SET SQL_MODE='NO_AUTO_VALUE_ON_ZERO';\n\n")

            # Get all tables
            cursor.execute("SHOW TABLES")
            tables = [row[0] for row in cursor.fetchall()]
            log_info(f"Found {len(tables)} tables")

            for table in tables:
                log_info(f"  Dumping: {table}")

                # Get CREATE TABLE statement
                cursor.execute(f"SHOW CREATE TABLE `{table}`")
                create_stmt = cursor.fetchone()[1]

                f.write(f"-- Table: {table}\n")
                f.write(f"DROP TABLE IF EXISTS `{table}`;\n")
                f.write(f"{create_stmt};\n\n")

                # Get table data
                cursor.execute(f"SELECT * FROM `{table}`")
                rows = cursor.fetchall()

                if rows:
                    # Get column names
                    columns = [desc[0] for desc in cursor.description]
                    col_list = ", ".join(f"`{c}`" for c in columns)

                    # Write INSERT statements in batches
                    batch_size = 100
                    for i in range(0, len(rows), batch_size):
                        batch = rows[i:i + batch_size]
                        values_list = []
                        for row in batch:
                            values = ", ".join(escape_string(v) for v in row)
                            values_list.append(f"({values})")

                        f.write(f"INSERT INTO `{table}` ({col_list}) VALUES\n")
                        f.write(",\n".join(values_list))
                        f.write(";\n")

                f.write("\n")

            f.write("SET FOREIGN_KEY_CHECKS=1;\n")

        cursor.close()
        conn.close()

        size = sql_file.stat().st_size / (1024 * 1024)
        log_info(f"Database backup complete: {sql_file} ({size:.1f} MB)")
        return True

    except Exception as e:
        log_error(f"Database dump failed: {e}")
        conn.close()
        return False


def backup_files(wp_path, output_path):
    """Backup WordPress files to tarball."""
    wp_path = Path(wp_path)
    tarball = output_path / "wordpress-full.tar.gz"

    log_info(f"Backing up all files from {wp_path}...")

    wp_config = wp_path / "wp-config.php"
    if wp_config.exists():
        (output_path / "wp-config.php").write_text(wp_config.read_text())
        log_info("Copied wp-config.php")

    htaccess = wp_path / ".htaccess"
    if htaccess.exists():
        (output_path / ".htaccess").write_text(htaccess.read_text())
        log_info("Copied .htaccess")

    with tarfile.open(tarball, "w:gz") as tar:
        tar.add(wp_path, arcname=wp_path.name)

    size = tarball.stat().st_size / (1024 * 1024)
    log_info(f"Full backup created: {tarball} ({size:.1f} MB)")


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <output_directory> [wordpress_path]")
        print(f"       {sys.argv[0]} ./backup")
        print(f"       {sys.argv[0]} ./backup /var/www/html")
        sys.exit(1)

    output_dir = Path(sys.argv[1])
    output_dir.mkdir(parents=True, exist_ok=True)

    if len(sys.argv) >= 3:
        wp_paths = [sys.argv[2]]
    else:
        wp_paths = find_wordpress()

    if not wp_paths:
        log_error("No WordPress installations found")
        sys.exit(1)

    for wp_path in wp_paths:
        log_info("=" * 50)
        log_info(f"Backing up: {wp_path}")
        log_info("=" * 50)

        creds = parse_wp_config(wp_path)
        if not creds:
            log_error(f"Skipping {wp_path}")
            continue

        print_credentials(creds)

        if not backup_database(creds, output_dir):
            log_warn("Database backup failed, continuing with files...")

        backup_files(wp_path, output_dir)

        log_info("Backup complete!")
        log_info(f"Files saved to: {output_dir}")


if __name__ == "__main__":
    main()
