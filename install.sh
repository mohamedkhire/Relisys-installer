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
#   sudo bash install.sh <IP-or-domain> <admin-email> <admin-username> [--no-ufw] [--reset]
#
# Options:
#   --no-ufw   do not touch the firewall (use this on Lightsail)
#   --reset    wipe a previous install of THIS script first (panel, database,
#              cron, pteroq, nginx site) then install again from scratch
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

# ---------------------------------------------------------- arguments
USE_UFW=true
RESET=false
POS=()
for a in "$@"; do
  case "$a" in
    --no-ufw) USE_UFW=false ;;
    --reset)  RESET=true ;;
    -*)       die "Unknown option: $a   (valid: --no-ufw  --reset)" ;;
    *)        POS+=("$a") ;;
  esac
done
HOST="${POS[0]:-}"
ADMIN_EMAIL="${POS[1]:-}"
ADMIN_USER="${POS[2]:-}"

do_reset() {
  big "$RED" \
    "RESET MODE: a previous install will be DELETED in 10 seconds." \
    "Removes: ${PANEL_DIR}, database 'panel' + user 'pterodactyl'," \
    "         www-data cron, pteroq service, nginx site, old Wings config.yml." \
    "Keeps  : Docker, Wings binary, /var/lib/pterodactyl (server files)." \
    "Press Ctrl+C NOW to cancel."
  local i
  for i in 10 9 8 7 6 5 4 3 2 1; do printf '%s ' "$i"; sleep 1; done
  echo
  systemctl stop pteroq wings >/dev/null 2>&1 || true
  systemctl disable pteroq >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/pteroq.service
  systemctl daemon-reload >/dev/null 2>&1 || true
  rm -rf "$PANEL_DIR"
  rm -f /etc/nginx/sites-enabled/pterodactyl.conf /etc/nginx/sites-available/pterodactyl.conf
  if command -v mariadb >/dev/null 2>&1; then
    mariadb -u root -e "DROP DATABASE IF EXISTS \`panel\`; DROP USER IF EXISTS 'pterodactyl'@'127.0.0.1';" || true
  fi
  crontab -r -u www-data >/dev/null 2>&1 || true
  command -v redis-cli >/dev/null 2>&1 && redis-cli flushall >/dev/null 2>&1 || true
  rm -f "$CRED_FILE" /etc/pterodactyl/config.yml
  echo "Previous install removed."
}

# ---------------------------------------------------------------- checks
[[ $EUID -eq 0 ]] || die "Run as root (sudo -i)."

[[ -n "$HOST" && -n "$ADMIN_EMAIL" && -n "$ADMIN_USER" ]] \
  || die "Usage: bash install.sh <IP-or-domain> <admin-email> <admin-username> [--no-ufw] [--reset]"

[[ "$ADMIN_EMAIL" != "your@email.com" && "$ADMIN_USER" != "yourusername" ]] \
  || die "You pasted the placeholder email/username. Put your REAL ones."

[[ "$ADMIN_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] \
  || die "Admin email looks invalid: $ADMIN_EMAIL"

[[ "$ADMIN_USER" =~ ^[A-Za-z0-9_.-]{3,}$ ]] \
  || die "Username must be 3+ chars: letters, numbers, _ . - only."

SAFE_TEXT='^[A-Za-z0-9 ._-]+$'
[[ "$BRAND"  =~ $SAFE_TEXT ]] || die "BRAND may only contain letters, numbers, space . _ -"
[[ "$AUTHOR" =~ $SAFE_TEXT ]] || die "AUTHOR may only contain letters, numbers, space . _ -"

[[ "$HOST" =~ ^[A-Za-z0-9.:-]+$ ]] \
  || die "Host/IP contains invalid characters: $HOST"

. /etc/os-release
[[ "$ID" == "ubuntu" && "$VERSION_ID" == "24.04" ]] \
  || die "This script supports Ubuntu 24.04 only (found: $ID $VERSION_ID)."

# make every apt/dpkg call wait (up to 5 min) if another process holds the lock
echo 'DPkg::Lock::Timeout "300";' > /etc/apt/apt.conf.d/99relisys-lock

if [[ -d "$PANEL_DIR" ]]; then
  if $RESET; then
    do_reset
  else
    die "$PANEL_DIR already exists. Re-run with --reset to wipe it, or use a fresh server."
  fi
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

s_swap() {
  if swapon --show --noheadings | grep -q .; then
    echo "Swap already active:"; swapon --show
    return 0
  fi
  fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  swapon --show --noheadings | grep -q .
}

s_update() {
  # fresh VPSs often run unattended-upgrades for the first minutes: wait for it
  local waited=0
  while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock >/dev/null 2>&1; do
    [[ $waited -ge 300 ]] && { echo "apt is still locked after 5 minutes"; return 1; }
    echo "Waiting for another apt process to finish... (${waited}s)"
    sleep 5; waited=$((waited + 5))
  done
  timedatectl set-timezone "$TIMEZONE"
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
  mariadb -u root -e "ALTER USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';"
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

s_egg() {
  # Creates the "Discord Bots" nest and imports OUR OWN egg (no vndel / third-party
  # launcher: the start logic lives inside the egg's startup command).
  local NEST_NAME="Discord Bots"
  local NEST_DESC="${BRAND} hosting - Discord bots and Node.js apps"
  local EGG_NAME="${BRAND} Node.js"
  local WORK
  WORK="$(mktemp -d /tmp/relisys-egg.XXXXXX)"
  trap "rm -rf '${WORK}'" EXIT   # expand now: WORK is local and gone when the trap fires
  chmod 755 "$WORK"

  cat > "$WORK/egg.json" <<'EGG_JSON_EOF'
{
    "_comment": "Generated for __BRAND__ - PTDL_v2 egg",
    "meta": {
        "version": "PTDL_v2",
        "update_url": null
    },
    "exported_at": "2026-10-02T00:00:00+00:00",
    "name": "__BRAND__ Node.js",
    "author": "__AUTHOR_EMAIL__",
    "description": "__BRAND__ Node.js runner for Discord bots and any Node.js app (by __AUTHOR__). Runs a .js/.mjs/.ts file or any command (npm run start), installs dependencies with npm / yarn / pnpm, optional git clone.",
    "features": [],
    "docker_images": {
        "Node.js 22 (LTS)": "ghcr.io/ptero-eggs/yolks:nodejs_22",
        "Node.js 24 (LTS)": "ghcr.io/ptero-eggs/yolks:nodejs_24",
        "Node.js 25": "ghcr.io/ptero-eggs/yolks:nodejs_25",
        "Node.js 23": "ghcr.io/ptero-eggs/yolks:nodejs_23",
        "Node.js 21": "ghcr.io/ptero-eggs/yolks:nodejs_21",
        "Node.js 20 (LTS)": "ghcr.io/ptero-eggs/yolks:nodejs_20",
        "Node.js 19": "ghcr.io/ptero-eggs/yolks:nodejs_19",
        "Node.js 18": "ghcr.io/ptero-eggs/yolks:nodejs_18",
        "Node.js 17": "ghcr.io/ptero-eggs/yolks:nodejs_17",
        "Node.js 16": "ghcr.io/ptero-eggs/yolks:nodejs_16",
        "Node.js 14": "ghcr.io/ptero-eggs/yolks:nodejs_14",
        "Node.js 12": "ghcr.io/ptero-eggs/yolks:nodejs_12"
    },
    "file_denylist": [],
    "startup": "cd /home/container; if [ \"${AUTO_UPDATE}\" = \"1\" ] && [ -d .git ]; then git pull --ff-only || echo \"__BRAND__: git pull failed - keeping the current files\"; fi; if [ -n \"${UNNODE_PACKAGES}\" ]; then npm uninstall ${UNNODE_PACKAGES}; fi; if [ \"${INSTALL_DEPS}\" = \"1\" ] && [ -f package.json ]; then if [ -f pnpm-lock.yaml ]; then npx --yes pnpm install; elif [ -f yarn.lock ]; then npx --yes yarn install; else npm install; fi; fi; if [ -n \"${NODE_PACKAGES}\" ]; then npm install ${NODE_PACKAGES}; fi; CMD=\"${COMMAND}\"; if [ -z \"${CMD}\" ]; then if [ -f package.json ] && grep -q '\"start\"' package.json; then CMD=\"npm start\"; else CMD=\"index.js\"; fi; fi; NOSP=\"${CMD// /}\"; echo \"__BRAND__:\" \"starting\" \"${CMD}\"; if [ \"${#NOSP}\" != \"${#CMD}\" ]; then exec sh -c \"${CMD}\"; elif [ \"${CMD%.ts}\" != \"${CMD}\" ]; then if [ \"${TS_RUNNER}\" = \"ts-node\" ]; then exec npx --yes -p typescript -p ts-node ts-node ${NODE_ARGS} ${CMD}; else exec npx --yes tsx ${NODE_ARGS} ${CMD}; fi; else exec node ${NODE_ARGS} ${CMD}; fi",
    "config": {
        "files": "{}",
        "startup": "{\"done\": \"__BRAND__: starting\"}",
        "logs": "{}",
        "stop": "^C"
    },
    "scripts": {
        "installation": {
            "script": "#!/bin/bash\n# __BRAND__ Node.js egg - install script (runs once, in a temporary container)\nset -u\napt-get update -qq\napt-get install -y -qq --no-install-recommends git ca-certificates\nmkdir -p /mnt/server\ncd /mnt/server || exit 1\n\nif [ \"${USER_UPLOAD:-0}\" = \"1\" ] || [ \"${USER_UPLOAD:-0}\" = \"true\" ] || [ -z \"${GIT_ADDRESS:-}\" ]; then\n    echo \"__BRAND__: no git repository to clone. Upload your files from the Files tab (or SFTP).\"\n    exit 0\nfi\n\nADDRESS=\"${GIT_ADDRESS}\"\ncase \"${ADDRESS}\" in\n    *.git) ;;\n    *) ADDRESS=\"${ADDRESS}.git\" ;;\nesac\nif [ -n \"${USERNAME:-}\" ] && [ -n \"${ACCESS_TOKEN:-}\" ]; then\n    ADDRESS=\"https://${USERNAME}:${ACCESS_TOKEN}@$(printf '%s' \"${ADDRESS}\" | cut -d/ -f3-)\"\nfi\n\nif [ -n \"$(ls -A /mnt/server 2>/dev/null)\" ]; then\n    if [ -d .git ]; then\n        echo \"__BRAND__: folder is already a git checkout, pulling the latest changes.\"\n        git pull --ff-only || echo \"__BRAND__: git pull failed, the files were left as they are.\"\n    else\n        echo \"__BRAND__: folder is not empty and not a git checkout, nothing was changed.\"\n    fi\n    exit 0\nfi\n\nif [ -n \"${BRANCH:-}\" ]; then\n    git clone --single-branch --branch \"${BRANCH}\" \"${ADDRESS}\" . || exit 1\nelse\n    git clone \"${ADDRESS}\" . || exit 1\nfi\necho \"__BRAND__: repository cloned. Dependencies are installed on the first start.\"\n",
            "container": "node:22-bookworm-slim",
            "entrypoint": "bash"
        }
    },
    "variables": [
        {
            "name": "Start file or command",
            "description": "A file to run (index.js, bot.mjs, src/main.ts) or a full command (npm run start). Empty = package.json start script, else index.js.",
            "env_variable": "COMMAND",
            "default_value": "index.js",
            "user_viewable": true,
            "user_editable": true,
            "rules": "nullable|string|max:500",
            "field_type": "text"
        },
        {
            "name": "Node options",
            "description": "Extra options for node, e.g. --enable-source-maps",
            "env_variable": "NODE_ARGS",
            "default_value": "",
            "user_viewable": true,
            "user_editable": true,
            "rules": "nullable|string|max:300",
            "field_type": "text"
        },
        {
            "name": "Install dependencies",
            "description": "1 = install package.json dependencies on every start (npm, or yarn / pnpm when their lock file exists).",
            "env_variable": "INSTALL_DEPS",
            "default_value": "1",
            "user_viewable": true,
            "user_editable": true,
            "rules": "required|boolean",
            "field_type": "text"
        },
        {
            "name": "Additional Node packages",
            "description": "Packages to install, separated by spaces (e.g. axios discord.js@14)",
            "env_variable": "NODE_PACKAGES",
            "default_value": "",
            "user_viewable": true,
            "user_editable": true,
            "rules": "nullable|string|max:500",
            "field_type": "text"
        },
        {
            "name": "Uninstall Node packages",
            "description": "Packages to remove, separated by spaces",
            "env_variable": "UNNODE_PACKAGES",
            "default_value": "",
            "user_viewable": true,
            "user_editable": true,
            "rules": "nullable|string|max:500",
            "field_type": "text"
        },
        {
            "name": "TypeScript runner",
            "description": "tsx (default, fast) or ts-node. Only used when the start file ends with .ts",
            "env_variable": "TS_RUNNER",
            "default_value": "tsx",
            "user_viewable": true,
            "user_editable": true,
            "rules": "required|string|in:tsx,ts-node",
            "field_type": "text"
        },
        {
            "name": "Git Repo Address",
            "description": "Cloned on install. Leave empty to upload your files instead.",
            "env_variable": "GIT_ADDRESS",
            "default_value": "",
            "user_viewable": true,
            "user_editable": true,
            "rules": "nullable|string|max:300",
            "field_type": "text"
        },
        {
            "name": "Install Branch",
            "description": "Empty = the default branch",
            "env_variable": "BRANCH",
            "default_value": "",
            "user_viewable": true,
            "user_editable": true,
            "rules": "nullable|string|max:100",
            "field_type": "text"
        },
        {
            "name": "Auto Update",
            "description": "1 = git pull on every start (when the folder is a git checkout)",
            "env_variable": "AUTO_UPDATE",
            "default_value": "0",
            "user_viewable": true,
            "user_editable": true,
            "rules": "required|boolean",
            "field_type": "text"
        },
        {
            "name": "User Uploaded Files",
            "description": "1 = skip the git clone on install",
            "env_variable": "USER_UPLOAD",
            "default_value": "0",
            "user_viewable": true,
            "user_editable": true,
            "rules": "required|boolean",
            "field_type": "text"
        },
        {
            "name": "Git Username",
            "description": "For a private repository",
            "env_variable": "USERNAME",
            "default_value": "",
            "user_viewable": true,
            "user_editable": true,
            "rules": "nullable|string|max:100",
            "field_type": "text"
        },
        {
            "name": "Git Access Token",
            "description": "For a private repository (a token, not your password)",
            "env_variable": "ACCESS_TOKEN",
            "default_value": "",
            "user_viewable": true,
            "user_editable": true,
            "rules": "nullable|string|max:200",
            "field_type": "text"
        }
    ]
}
EGG_JSON_EOF

  cat > "$WORK/seed.php" <<'SEED_PHP_EOF'
<?php
// Creates the Nest + imports the egg using the Panel's own services
// (same classes the official EggSeeder uses).
use Illuminate\Http\UploadedFile;
use Pterodactyl\Models\Egg;
use Pterodactyl\Models\Nest;
use Pterodactyl\Services\Eggs\Sharing\EggImporterService;
use Pterodactyl\Services\Nests\NestCreationService;

$panel = getenv('RELISYS_PANEL_DIR');
require $panel . '/vendor/autoload.php';
$app = require $panel . '/bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();

$nestName = getenv('RELISYS_NEST_NAME');
$nestDesc = getenv('RELISYS_NEST_DESC');
$eggName  = getenv('RELISYS_EGG_NAME');
$eggFile  = getenv('RELISYS_EGG_FILE');
$author   = getenv('RELISYS_AUTHOR');

foreach (['nestName', 'nestDesc', 'eggName', 'eggFile', 'author'] as $v) {
    if (!$$v) { fwrite(STDERR, "Missing value: $v\n"); exit(2); }
}

$nest = Nest::where('name', $nestName)->first();
if (!$nest) {
    $nest = $app->make(NestCreationService::class)->handle(
        ['name' => $nestName, 'description' => $nestDesc],
        $author
    );
    echo "Created nest: {$nest->name} (id {$nest->id})\n";
} else {
    echo "Nest already exists: {$nest->name} (id {$nest->id})\n";
}

$egg = Egg::where('nest_id', $nest->id)->where('name', $eggName)->first();
if (!$egg) {
    $file = new UploadedFile($eggFile, basename($eggFile), 'application/json', null, true);
    $egg = $app->make(EggImporterService::class)->handle($file, $nest->id);
    echo "Imported egg: {$egg->name} (id {$egg->id})\n";
} else {
    echo "Egg already exists: {$egg->name} (id {$egg->id})\n";
}
SEED_PHP_EOF

  # brand the egg
  sed -i -e "s|__BRAND__|${BRAND}|g" \
         -e "s|__AUTHOR_EMAIL__|${ADMIN_EMAIL}|g" \
         -e "s|__AUTHOR__|${AUTHOR}|g" "$WORK/egg.json"
  if grep -q '__BRAND__\|__AUTHOR' "$WORK/egg.json"; then
    echo "Unreplaced placeholders left in the egg file"; return 1
  fi
  php -r 'exit(json_decode(file_get_contents($argv[1])) === null ? 1 : 0);' "$WORK/egg.json" \
    || { echo "The egg JSON is not valid"; return 1; }

  chmod 644 "$WORK/egg.json" "$WORK/seed.php"
  runuser -u www-data -- env \
    RELISYS_PANEL_DIR="$PANEL_DIR" \
    RELISYS_NEST_NAME="$NEST_NAME" \
    RELISYS_NEST_DESC="$NEST_DESC" \
    RELISYS_EGG_NAME="$EGG_NAME" \
    RELISYS_EGG_FILE="$WORK/egg.json" \
    RELISYS_AUTHOR="$ADMIN_EMAIL" \
    php "$WORK/seed.php"

  # verify in the database: nest exists, egg exists, and all 12 variables came with it
  mariadb -u root -N -e "SELECT COUNT(*) FROM \`${DB_NAME}\`.eggs e JOIN \`${DB_NAME}\`.nests n ON n.id = e.nest_id WHERE n.name='${NEST_NAME}' AND e.name='${EGG_NAME}';" | grep -qx "1"
  mariadb -u root -N -e "SELECT COUNT(*) FROM \`${DB_NAME}\`.egg_variables v JOIN \`${DB_NAME}\`.eggs e ON e.id = v.egg_id WHERE e.name='${EGG_NAME}';" | grep -qx "12"
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
  # verify: real executable (ELF) of sensible size, service enabled
  [[ "$(head -c4 /usr/local/bin/wings | tail -c3)" == "ELF" ]]
  [[ "$(stat -c %s /usr/local/bin/wings)" -gt 10000000 ]]
  systemctl is-enabled --quiet wings
  /usr/local/bin/wings version || echo "(wings version check skipped - not important)"
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

run_step "Create 2GB swap (if none)"     s_swap
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
run_step "Create 'Discord Bots' nest + our own egg" s_egg s_migrate s_permissions s_configure
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
    " 5) Admin > Nodes > your node > Allocation: add IP + ports 3000-3999." \
    " 6) Create a server: Nest 'Discord Bots' > egg '${BRAND} Node.js'." \
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
