import os

def backup_nginx_config_linux():
    pass

os.system("sudo nginx -T > backup.nginx")