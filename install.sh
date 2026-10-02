#!/usr/bin/env bash
#
# ======================= EDIT THESE 3 LINES =======================
BRAND="Relisys"                 # company name
AUTHOR="Mohamed Khire"          # author
TIMEZONE="Africa/Cairo"
# ==================================================================
#
# ${BRAND} Pterodactyl Installer  (v2: step-by-step, keeps going on errors)
# Tested target: Ubuntu 24.04 LTS (fresh install)
#
# Usage:
#   sudo bash install.sh <IP-or-domain> <admin-email> <admin-username> [--no-ufw]
#
# Example:
#   sudo bash install.sh 203.0.113.10 you@email.com myadmin --no-ufw
#
# How it behaves:
#   * Every step runs on its own. Success = big GREEN box. Failure = big RED box.
#   * A failed step does NOT stop the script. Steps that depend on a failed
#     step are SKIPPED (yellow) so you don't get a cascade of fake errors.
#   * A full summary is printed at the end. Full log: /root/<BRAND>-install.log
#
# Pterodactyl itself is MIT licensed (c) Dane Everitt and contributors.
# Official docs this script automates:
#   https://pterodactyl.io/panel/1.0/getting_started.html
#   https://pterodactyl.io/wings/1.0/installing.html

# NOTE: no "set -e" on purpose. Errors are handled per step by run_step().
set -uo pipefail

HOST="${1:-}"
ADMIN_EMAIL="${2:-}"
ADMIN_USER="${3:-}"
USE_UFW=true
[[ "${4:-}" == "--no-ufw" ]] && USE_UFW=false

PANEL_DIR="/var/www/pterodactyl"
SAFE_BRAND="${BRAND// /_}"
CRED_FILE="/root/${SAFE_BRAND}-credentials.txt"
LOG="/root/${SAFE_BRAND}-install.log"

# ---------------------------------------------------------------- colors
GREEN=$'\033[1;32m'; RED=$'\033[1;31m'; YELLOW=$'\033[1;33m'
CYAN=$'\033[1;36m';  NC=$'\033[0m'

big() {  # big <color> <line> [line...]
  local color="$1"; shift
  local bar; bar="$(printf '═%.0s' {1..64})"
  local l
  printf '\n%s╔%s\n' "$color" "$bar"
  for l in "$@"; do printf '║  %s\n' "$l"; done
  printf '╚%s%s\n\n' "$bar" "$NC"
}

die() { big "$RED" "FATAL: $*"; exit 1; }

# ---------------------------------------------------------------- checks
[[ $EUID -eq 0 ]] || die "Run as root (sudo -i)."

[[ -n "$HOST" && -n "$ADMIN_EMAIL" && -n "$ADMIN_USER" ]] \
  || die "Usage: bash install.sh <IP-or-domain> <admin-email> <admin-username> [--no-ufw]"

[[ "$ADMIN_EMAIL" != "your@email.com" && "$ADMIN_USER" != "yourusername" ]] \
  || die "You pasted the placeholder email/username. Put your REAL ones."

[[ "$ADMIN_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] \
  || die "Admin email looks invalid: $ADMIN_EMAIL"

[[ "$ADMIN_USER" =~ ^[A-Za-z0-9_.-]{3,}$ ]] \
  || die "Username must be 3+ chars: letters, numbers, _ . - only."

[[ "$HOST" =~ ^[A-Za-z0-9.:-]+$ ]] \
  || die "Host/IP contains invalid characters: $HOST"

. /etc/os-release
[[ "$ID" == "ubuntu" && "$VERSION_ID" == "24.04" ]] \
  || die "This script supports Ubuntu 24.04 only (found: $ID $VERSION_ID)."

if [[ -d "$PANEL_DIR" ]]; then
  die "$PANEL_DIR already exists. Use a fresh server (or clean the old install first)."
fi

if ! command -v openssl >/dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq openssl
fi

# ------------------------------------------------------ random secrets
DB_NAME="panel"
DB_USER="pterodactyl"
DB_PASS="$(openssl rand -hex 16)"
ADMIN_PASS="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-20)"
APP_URL="http://${HOST}"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export COMPOSER_ALLOW_SUPERUSER=1

: > "$LOG"
chmod 600 "$LOG"

# ======================================================= step framework
declare -A STATUS=()
RESULTS=()
STEP_NO=0
TOTAL_STEPS="$(grep -c '^ *run_step "' "$0" 2>/dev/null || echo 0)"
$USE_UFW || TOTAL_STEPS=$((TOTAL_STEPS - 1))   # the ufw step is skipped with --no-ufw

# run_step "<Title>" <function> [dependency_function ...]
run_step() {
  local title="$1" fn="$2"; shift 2
  STEP_NO=$((STEP_NO + 1))

  local dep
  for dep in "$@"; do
    if [[ "${STATUS[$dep]:-}" != "OK" ]]; then
      STATUS[$fn]="SKIPPED"
      RESULTS+=("SKIPPED|${title}|0")
      big "$YELLOW" \
        "SKIPPED  [${STEP_NO}/${TOTAL_STEPS}]  ${title}" \
        "Reason: it needs '${dep}' and that did not succeed."
      echo "[SKIPPED] ${title} (needs ${dep})" >> "$LOG"
      return 0
    fi
  done

  printf '\n%s━━━━━━━━  [%s/%s]  %s  ━━━━━━━━%s\n\n' \
    "$CYAN" "$STEP_NO" "$TOTAL_STEPS" "$title" "$NC"

  local start_line t0 rc dt
  start_line="$(wc -l < "$LOG")"
  t0=$SECONDS

  ( set -e; "$fn" ) 2>&1 | tee -a "$LOG"
  rc=${PIPESTATUS[0]}
  dt=$((SECONDS - t0))

  if [[ $rc -eq 0 ]]; then
    STATUS[$fn]="OK"
    RESULTS+=("OK|${title}|${dt}")
    big "$GREEN" \
      "SUCCESS  [${STEP_NO}/${TOTAL_STEPS}]  ${title}" \
      "Done in ${dt}s."
  else
    STATUS[$fn]="FAILED"
    RESULTS+=("FAILED|${title}|${dt}")
    big "$RED" \
      "FAILED   [${STEP_NO}/${TOTAL_STEPS}]  ${title}" \
      "Exit code: ${rc}. The script will keep going." \
      "Last lines of this step are shown below."
    tail -n +"$((start_line + 1))" "$LOG" | tail -n 12
    echo
  fi
  return 0
}

# ============================================================ the steps
# Each function runs inside its own "set -e" subshell. Last lines of each
# one VERIFY the result, so GREEN really means it works.

s_update() {
  apt-get update -y
  apt-get upgrade -y -o Dpkg::Options::=--force-confold
}

s_packages() {
  apt-get install -y \
    curl ca-certificates gnupg lsb-release software-properties-common \
    tar unzip git cron openssl \
    nginx redis-server mariadb-server \
    php8.3 php8.3-cli php8.3-fpm php8.3-gd php8.3-mysql php8.3-mbstring \
    php8.3-bcmath php8.3-xml php8.3-curl php8.3-zip
  command -v nginx php mariadb redis-server >/dev/null
}

s_services() {
  systemctl enable --now mariadb redis-server php8.3-fpm nginx cron
  systemctl is-active --quiet mariadb
  systemctl is-active --quiet redis-server
  systemctl is-active --quiet php8.3-fpm
}

s_composer() {
  curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
  composer --version
}

s_download_panel() {
  mkdir -p "$PANEL_DIR"
  cd "$PANEL_DIR"
  curl -fLo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
  tar -xzf panel.tar.gz
  rm -f panel.tar.gz
  chmod -R 755 storage/* bootstrap/cache/
  cp .env.example .env
  test -f artisan
}

s_composer_install() {
  cd "$PANEL_DIR"
  composer install --no-dev --optimize-autoloader --no-interaction --no-progress
  test -d vendor
}

s_key() {
  cd "$PANEL_DIR"
  php artisan key:generate --force
  grep -q '^APP_KEY=base64:' .env
}

s_database() {
  mariadb -u root -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;"
  mariadb -u root -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';"
  mariadb -u root -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1' WITH GRANT OPTION;"
  mariadb -u root -e "FLUSH PRIVILEGES;"
  # verify the new user can really log in over TCP
  mariadb -u"${DB_USER}" -p"${DB_PASS}" -h127.0.0.1 -e "USE \`${DB_NAME}\`;"
}

s_configure() {
  cd "$PANEL_DIR"
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

  grep -q "^APP_URL=" .env
  grep -q "^DB_DATABASE=${DB_NAME}" .env
}

s_migrate() {
  cd "$PANEL_DIR"
  php artisan migrate --seed --force
  mariadb -u root -N -e "SHOW TABLES FROM \`${DB_NAME}\`;" | grep -qx "users"
}

s_admin() {
  cd "$PANEL_DIR"
  php artisan p:user:make \
    --email="$ADMIN_EMAIL" \
    --username="$ADMIN_USER" \
    --name-first="$AUTHOR" \
    --name-last="Admin" \
    --password="$ADMIN_PASS" \
    --admin=1
  mariadb -u root -N -e \
    "SELECT COUNT(*) FROM \`${DB_NAME}\`.users WHERE email='${ADMIN_EMAIL}';" | grep -qx "1"
}

s_location() {
  cd "$PANEL_DIR"
  php artisan p:location:make --short="dc1" --long="${BRAND} Datacenter"
  mariadb -u root -N -e \
    "SELECT COUNT(*) FROM \`${DB_NAME}\`.locations WHERE short='dc1';" | grep -qx "1"
}

s_permissions() {
  chown -R www-data:www-data "$PANEL_DIR"
  [[ "$(stat -c %U "$PANEL_DIR/.env")" == "www-data" ]]
}

s_cron() {
  # "|| true": crontab -l returns 1 when no crontab exists yet (this was the
  # bug that silently killed the old script under "set -e").
  ( crontab -l -u www-data 2>/dev/null || true; \
    echo "* * * * * php ${PANEL_DIR}/artisan schedule:run >> /dev/null 2>&1" ) \
    | sort -u | crontab -u www-data -
  crontab -l -u www-data | grep -q "schedule:run"
}

s_pteroq() {
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
  sleep 3
  systemctl is-active --quiet pteroq.service
}

s_nginx() {
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

  sed -i "s|__HOST__|${HOST}|" /etc/nginx/sites-available/pterodactyl.conf
  ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
  nginx -t
  systemctl restart nginx
  systemctl is-active --quiet nginx
}

s_docker() {
  curl -fsSL https://get.docker.com/ | CHANNEL=stable bash
  systemctl enable --now docker
  docker info >/dev/null
}

s_wings() {
  mkdir -p /etc/pterodactyl
  local arch
  arch="$([[ "$(uname -m)" == "x86_64" ]] && echo amd64 || echo arm64)"
  curl -fLo /usr/local/bin/wings \
    "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${arch}"
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
  # Enabled but NOT started: it needs config.yml from the Panel first.
  systemctl enable wings
  /usr/local/bin/wings --version
}

s_ufw() {
  apt-get install -y ufw
  ufw allow 22/tcp
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow 8080/tcp
  ufw allow 2022/tcp
  ufw allow 3000:3999/tcp
  ufw --force enable
  ufw status | grep -q "Status: active"
}

s_credentials() {
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
  test -s "$CRED_FILE"
}

s_health() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${HOST}" http://127.0.0.1/ || true)"
  echo "Panel answered HTTP ${code} on http://127.0.0.1/"
  [[ "$code" =~ ^(200|301|302)$ ]]
}

# ===================================================== run everything
big "$CYAN" \
  "${BRAND} Pterodactyl Installer v2" \
  "Host: ${HOST}   |   Admin: ${ADMIN_USER} <${ADMIN_EMAIL}>" \
  "Log file: ${LOG}" \
  "Do NOT close this window until the final summary appears."

run_step "Update system"                 s_update
run_step "Install packages (nginx, PHP 8.3, MariaDB, Redis)" s_packages
run_step "Start core services"           s_services      s_packages
run_step "Install Composer"              s_composer      s_packages
run_step "Download Panel files"          s_download_panel s_packages
run_step "Install Panel dependencies"    s_composer_install s_download_panel s_composer
run_step "Generate application key"      s_key           s_composer_install
run_step "Create database + user"        s_database      s_services
run_step "Configure Panel environment"   s_configure     s_key s_database
run_step "Run database migrations"       s_migrate       s_configure
run_step "Create admin user"             s_admin         s_migrate
run_step "Create location (dc1)"         s_location      s_migrate
run_step "Fix file permissions"          s_permissions   s_download_panel
run_step "Set up cron job"               s_cron          s_permissions
run_step "Set up queue worker (pteroq)"  s_pteroq        s_migrate s_permissions s_services
run_step "Configure nginx (HTTP)"        s_nginx         s_download_panel s_services
run_step "Install Docker"                s_docker
run_step "Install Wings"                 s_wings         s_docker
if $USE_UFW; then
  run_step "Enable firewall (ufw)"       s_ufw
else
  echo -e "\n${YELLOW}[skip]${NC} ufw not touched (--no-ufw). Use your provider firewall."
fi
run_step "Save credentials file"         s_credentials
run_step "Final health check (Panel answers)" s_health  s_nginx s_migrate

# ============================================================ summary
OK_N=0; FAIL_N=0; SKIP_N=0
echo
echo "${CYAN}══════════════════════  SUMMARY  ══════════════════════${NC}"
for r in "${RESULTS[@]}"; do
  IFS='|' read -r st title secs <<< "$r"
  case "$st" in
    OK)      printf '  %s✔ OK     %s %s(%ss)\n' "$GREEN"  "$title" "$NC" "$secs"; OK_N=$((OK_N+1)) ;;
    FAILED)  printf '  %s✘ FAILED %s %s(%ss)\n' "$RED"    "$title" "$NC" "$secs"; FAIL_N=$((FAIL_N+1)) ;;
    SKIPPED) printf '  %s↷ SKIPPED%s %s\n'      "$YELLOW" "$NC" "$title";          SKIP_N=$((SKIP_N+1)) ;;
  esac
done
echo

if [[ $FAIL_N -eq 0 && $SKIP_N -eq 0 ]]; then
  big "$GREEN" \
    "ALL ${OK_N} STEPS SUCCEEDED  -  ${BRAND} Panel is installed" \
    "" \
    "Panel URL   : ${APP_URL}" \
    "Credentials : cat ${CRED_FILE}" \
    "" \
    "NEXT STEPS:" \
    " 1) Open the Panel, log in, set Company Name in Admin > Settings." \
    " 2) Admin > Nodes > Create New (Memory/Disk Overallocate = 0)." \
    " 3) Node > Configuration > paste into /etc/pterodactyl/config.yml" \
    " 4) systemctl start wings" \
    " 5) Add Allocations, import your eggs." \
    "" \
    "(No reboot was done. Reboot manually if the kernel was updated.)"
  exit 0
else
  big "$RED" \
    "FINISHED WITH PROBLEMS:  ${OK_N} ok / ${FAIL_N} failed / ${SKIP_N} skipped" \
    "" \
    "Full log     : ${LOG}" \
    "Send me the last 30 lines:  tail -n 30 ${LOG}" \
    "(Do NOT send ${CRED_FILE} - it contains passwords.)"
  exit 1
fi
