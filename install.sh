#!/usr/bin/env bash
#
# ======================= EDIT THESE 3 LINES =======================
BRAND="Relisys"                 # company name
AUTHOR="Mohamed Khire"         # author
TIMEZONE="Africa/Cairo"
# ==================================================================
#
# ${BRAND} Pterodactyl Installer
# Author: ${AUTHOR}
# Tested target: Ubuntu 24.04 LTS (fresh install)
#
# Usage:
#   sudo bash install.sh <IP-or-domain> <admin-email> <admin-username> [--no-ufw]
#
# Example:
#   sudo bash install.sh 203.0.113.10 you@email.com myadmin
#
# Pterodactyl itself is MIT licensed (c) Dane Everitt and contributors.
# This script only automates the installation steps from the official docs:
#   https://pterodactyl.io/panel/1.0/getting_started.html
#   https://pterodactyl.io/wings/1.0/installing.html

set -euo pipefail

HOST="${1:-}"
ADMIN_EMAIL="${2:-}"
ADMIN_USER="${3:-}"
USE_UFW=true
[[ "${4:-}" == "--no-ufw" ]] && USE_UFW=false

PANEL_DIR="/var/www/pterodactyl"
CRED_FILE="/root/${BRAND// /_}-credentials.txt"

log()  { echo -e "\n\033[1;36m[${BRAND}]\033[0m $*"; }
die()  { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

# ---------------------------------------------------------------- checks
[[ $EUID -eq 0 ]] || die "Run as root (sudo -i)."
[[ -n "$HOST" && -n "$ADMIN_EMAIL" && -n "$ADMIN_USER" ]] \
  || die "Usage: bash install.sh <IP-or-domain> <admin-email> <admin-username> [--no-ufw]"

. /etc/os-release
[[ "$ID" == "ubuntu" && "$VERSION_ID" == "24.04" ]] \
  || die "This script supports Ubuntu 24.04 only (found: $ID $VERSION_ID)."

if [[ -d "$PANEL_DIR" ]]; then
  die "$PANEL_DIR already exists. Use a fresh server."
fi

# ------------------------------------------------------ random secrets
DB_NAME="panel"
DB_USER="pterodactyl"
DB_PASS="$(openssl rand -hex 16)"
ADMIN_PASS="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-20)"

APP_URL="http://${HOST}"

# --------------------------------------------------------- system update
log "Updating system..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y

log "Installing packages..."
apt-get install -y \
  curl ca-certificates gnupg lsb-release software-properties-common \
  tar unzip git cron openssl \
  nginx redis-server mariadb-server \
  php8.3 php8.3-cli php8.3-fpm php8.3-gd php8.3-mysql php8.3-mbstring \
  php8.3-bcmath php8.3-xml php8.3-curl php8.3-zip

systemctl enable --now mariadb redis-server php8.3-fpm nginx cron

# -------------------------------------------------------------- composer
log "Installing Composer..."
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# ----------------------------------------------------------------- panel
log "Downloading Pterodactyl Panel..."
mkdir -p "$PANEL_DIR"
cd "$PANEL_DIR"
curl -fLo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzf panel.tar.gz
rm -f panel.tar.gz
chmod -R 755 storage/* bootstrap/cache/

cp .env.example .env
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction
php artisan key:generate --force

# -------------------------------------------------------------- database
log "Creating database (listening on localhost only)..."
mariadb -u root -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;"
mariadb -u root -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';"
mariadb -u root -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1' WITH GRANT OPTION;"
mariadb -u root -e "FLUSH PRIVILEGES;"

# ----------------------------------------------------- panel configuration
log "Configuring panel..."
php artisan p:environment:setup \
  --author="$ADMIN_EMAIL" \
  --url="$APP_URL" \
  --timezone="$TIMEZONE" \
  --cache="redis" --session="redis" --queue="redis" \
  --redis-host="127.0.0.1" --redis-pass="null" --redis-port="6379" \
  --settings-ui=true \
  --telemetry=false

php artisan p:environment:database \
  --host="127.0.0.1" --port="3306" \
  --database="$DB_NAME" --username="$DB_USER" --password="$DB_PASS"

php artisan migrate --seed --force

php artisan p:user:make \
  --email="$ADMIN_EMAIL" \
  --username="$ADMIN_USER" \
  --name-first="$AUTHOR" \
  --name-last="Admin" \
  --password="$ADMIN_PASS" \
  --admin=1

php artisan p:location:make --short="dc1" --long="${BRAND} Datacenter" || true

chown -R www-data:www-data "$PANEL_DIR"/*

# ------------------------------------------------------- cron + queue
log "Setting up cron and queue worker..."
( crontab -l -u www-data 2>/dev/null; \
  echo "* * * * * php ${PANEL_DIR}/artisan schedule:run >> /dev/null 2>&1" ) \
  | sort -u | crontab -u www-data -

cat > /etc/systemd/system/pteroq.service <<'EOF'
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now pteroq.service

# ----------------------------------------------------------------- nginx
log "Configuring nginx (HTTP)..."
rm -f /etc/nginx/sites-enabled/default

cat > /etc/nginx/sites-available/pterodactyl.conf <<'EOF'
server {
    listen 80;
    server_name __HOST__;

    root /var/www/pterodactyl/public;
    index index.html index.htm index.php;
    charset utf-8;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    access_log off;
    error_log  /var/log/nginx/pterodactyl.app-error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        include /etc/nginx/fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

sed -i "s/__HOST__/${HOST}/" /etc/nginx/sites-available/pterodactyl.conf
ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
nginx -t
systemctl restart nginx

# ---------------------------------------------------------------- docker
log "Installing Docker..."
curl -sSL https://get.docker.com/ | CHANNEL=stable bash
systemctl enable --now docker

# ----------------------------------------------------------------- wings
log "Installing Wings..."
mkdir -p /etc/pterodactyl
ARCH="$([[ "$(uname -m)" == "x86_64" ]] && echo amd64 || echo arm64)"
curl -fLo /usr/local/bin/wings \
  "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${ARCH}"
chmod u+x /usr/local/bin/wings

cat > /etc/systemd/system/wings.service <<'EOF'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
# Wings is enabled but NOT started: it needs config.yml from the Panel first.
systemctl enable wings

# ------------------------------------------------------------------- ufw
if $USE_UFW; then
  log "Enabling firewall (SSH allowed first)..."
  apt-get install -y ufw
  ufw allow 22/tcp
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow 8080/tcp
  ufw allow 2022/tcp
  ufw allow 3000:3999/tcp
  ufw --force enable
else
  log "Skipping ufw (--no-ufw). Make sure your provider firewall is configured."
fi

# ----------------------------------------------------------- credentials
umask 077
cat > "$CRED_FILE" <<EOF
${BRAND} Pterodactyl - generated by install.sh (author: ${AUTHOR})

Panel URL      : ${APP_URL}
Admin email    : ${ADMIN_EMAIL}
Admin username : ${ADMIN_USER}
Admin password : ${ADMIN_PASS}

Database name  : ${DB_NAME}
Database user  : ${DB_USER}@127.0.0.1
Database pass  : ${DB_PASS}
EOF
chmod 600 "$CRED_FILE"

log "DONE. Panel installed."
echo
echo "  Panel URL   : ${APP_URL}"
echo "  Credentials : ${CRED_FILE}   (cat it, then store it safely)"
echo
echo "  NEXT STEPS:"
echo "   1) Open the panel, log in, change Company Name in Admin > Settings."
echo "   2) Admin > Nodes > Create New (Memory/Disk Overallocate = 0)."
echo "   3) Node > Configuration > copy into /etc/pterodactyl/config.yml"
echo "   4) systemctl start wings"
echo "   5) Add Allocations, import your eggs."
echo
echo "  (No reboot was done. Reboot manually if the kernel was updated.)"
