import os
from pathlib import Path

SAVE_DIR = "nginx_backups"

BASIC_SAVE_DIR = os.path.join(SAVE_DIR, "basic_configs")
FULL_SAVE_DIR = os.path.join(SAVE_DIR, "full_configs")

if os.path.isdir(SAVE_DIR) and os.listdir(SAVE_DIR):
    input(f"Directory {SAVE_DIR} is not empty. Files may be overwritten. Press Enter to continue or Ctrl+C to abort.")


os.makedirs(BASIC_SAVE_DIR, exist_ok=True)

# First get and save full parsed nginx config from nginx
nginx_parsed_config = os.popen(f"sudo nginx -T").read()
with open(os.path.join(BASIC_SAVE_DIR, 'nginx-parsed.conf'), 'w') as f:
    f.write(nginx_parsed_config)

# Get nginx arguments with nginx -V
nginx_v_output = os.popen("sudo nginx -V 2>&1").read()
with open(os.path.join(BASIC_SAVE_DIR, 'nginx-info.txt'), 'w') as f:
    f.write(nginx_v_output)

nginx_args = nginx_v_output.split('configure arguments: ')[1].strip().removeprefix('--').split(' --')
nginx_args = {flag:val for flag, val in (arg.split('=', 1) if '=' in arg else (arg, None) for arg in nginx_args)}

# Get backup config file plus prefix
prefix_dir = nginx_args['prefix']
nginx_conf = nginx_args['conf-path']

# Start full backup
os.makedirs(FULL_SAVE_DIR, exist_ok=True)

# Now save  nginx config
nginx_conf_contents = os.popen(f"sudo cat {nginx_conf}").read()
with open(os.path.join(FULL_SAVE_DIR, 'nginx.conf.backup'), 'w') as f:
    f.write(nginx_conf_contents)

# Now save all files in prefix directory
os.system(f"sudo cp -r {prefix_dir} {FULL_SAVE_DIR}/prefix_backup")

# Go though nginx config and find all included/root files that are not in the prefix directory
def save_directive_external_paths(config: str, directive: str, prefix_path: str | Path, save_root_path: str | Path, covered_paths: list[str | Path] = []) -> list[Path]:
    """
    Saves all files included via a specific directive that are outside of the passed in covered paths.
    
    :param config: The nginx configuration content
    :type config: str
    :param directive: The directive to look for (e.g., 'include', 'root')
    :type directive: str
    :param prefix_path: The prefix directory path to resolve relative paths
    :type prefix_path: str | Path
    :param save_root_path: The directory to save the external files to
    :type save_root_path: str | Path
    :param covered_paths: List of paths that are considered covered (i.e., the prefix directory)
    :type covered_paths: list[str | Path]
    :return: Updated list of covered paths including newly saved paths
    """
    prefix_path = Path(prefix_path)
    external_paths: list[Path] = []
    covered_paths: list[Path] = [Path(p) for p in covered_paths]
    for line in config.splitlines():
        line = line.strip()
        if line.startswith(directive):
            include_path = Path(line.split(directive)[1].rstrip(';').strip())
            full_path = prefix_path / include_path
            covered = False
            for covered_path in covered_paths:
                if full_path.is_relative_to(covered_path):
                    covered = True
                    break
            if covered:
                continue

            print(f"Found external included path: {full_path}")
            external_paths.append(full_path)
            covered_paths.append(full_path)
    
    if not external_paths:
        return covered_paths

    os.makedirs(save_root_path, exist_ok=True)

    for external_path in external_paths:
        save_path = os.path.join(save_root_path, external_path.relative_to('/'))
        os.makedirs(os.path.dirname(save_path), exist_ok=True)
        os.system(f"sudo cp -r {external_path} {save_path}")

    return covered_paths

covered_paths = save_directive_external_paths(nginx_conf_contents, 'include', prefix_dir, os.path.join(FULL_SAVE_DIR, 'external_includes'), [prefix_dir])
save_directive_external_paths(nginx_conf_contents, 'root', prefix_dir, os.path.join(FULL_SAVE_DIR, 'external_roots'), covered_paths)