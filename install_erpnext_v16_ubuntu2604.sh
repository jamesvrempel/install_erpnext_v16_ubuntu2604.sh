#!/usr/bin/env bash
#
# Frappe / ERPNext v16 installer for Ubuntu 26.04 LTS
# Bench user: enterprise
#
# Usage
#   1. As root (first run): creates the "enterprise" user, then tells you to log in as it.
#        sudo bash install_erpnext_v16_ubuntu2604.sh
#   2. As enterprise: performs the installation.
#        bash install_erpnext_v16_ubuntu2604.sh
#
# Optional settings (environment variables), otherwise you will be prompted:
#   SITE_NAME          site name / FQDN              (prompted)
#   DB_ROOT_PW         MariaDB root password         (prompted)
#   ADMIN_PW           ERPNext Administrator password (prompted)
#   BENCH_NAME         bench folder                  (default: frappe-bench)
#   INSTALL_HRMS       yes|no                        (default: no)
#   PRODUCTION         yes|no  nginx + supervisor    (default: yes)
#   ENABLE_UFW         yes|no  allow 22/80/443 only  (default: no)
#
# Example (non-interactive passwords via env):
#   SITE_NAME=erp.example.com INSTALL_HRMS=yes bash install_erpnext_v16_ubuntu2604.sh

set -Eeo pipefail

BENCH_USER="enterprise"
FRAPPE_BRANCH="version-16"
NODE_MAJOR="24"
PYTHON_VERSION="3.14"
NVM_VERSION="v0.40.3"
WKHTML_VER="0.12.6.1-2"

BENCH_NAME="${BENCH_NAME:-frappe-bench}"
INSTALL_HRMS="${INSTALL_HRMS:-no}"
PRODUCTION="${PRODUCTION:-yes}"
ENABLE_UFW="${ENABLE_UFW:-no}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[1;34m'; NC='\033[0m'
step() { echo -e "\n${BLUE}==> $*${NC}"; }
ok()   { echo -e "${GREEN}✔ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠ $*${NC}"; }
die()  { echo -e "${RED}✖ $*${NC}" >&2; exit 1; }
trap 'die "Failed at line $LINENO: $BASH_COMMAND"' ERR

# ─── Stage 0: run as root → create the bench user ────────────────────────────────
if [[ "$EUID" -eq 0 ]]; then
    step "Running as root: preparing user '$BENCH_USER'"
    if id "$BENCH_USER" &>/dev/null; then
        ok "User '$BENCH_USER' already exists"
    else
        adduser --gecos "" "$BENCH_USER"
        ok "User '$BENCH_USER' created"
    fi
    usermod -aG sudo "$BENCH_USER"
    install -o "$BENCH_USER" -g "$BENCH_USER" -m 755 "$0" "/home/$BENCH_USER/$(basename "$0")"
    echo
    echo -e "${GREEN}Now log in as $BENCH_USER and run the installer:${NC}"
    echo "    su - $BENCH_USER"
    echo "    bash ~/$(basename "$0")"
    exit 0
fi

[[ "$(whoami)" == "$BENCH_USER" ]] || die "Run this script as '$BENCH_USER' (or as root to create that user)."
sudo -v || die "'$BENCH_USER' needs sudo rights."
# keep sudo alive for the duration of the install
( while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) 2>/dev/null &

# ─── OS check ───────────────────────────────────────────────────────────────────
. /etc/os-release
if [[ "$ID" != "ubuntu" || "$VERSION_ID" != "26.04" ]]; then
    warn "This script targets Ubuntu 26.04; detected $PRETTY_NAME."
    read -rp "Continue anyway? (yes/no): " a; [[ "$a" =~ ^(y|yes)$ ]] || exit 1
fi
case "$(uname -m)" in
    x86_64)  ARCH=amd64 ;;
    aarch64) ARCH=arm64 ;;
    *) die "Unsupported architecture $(uname -m)" ;;
esac

# ─── Collect settings ───────────────────────────────────────────────────────────
ask_secret() {   # ask_secret VAR "Prompt"
    local var="$1" p1 p2
    [[ -n "${!var:-}" ]] && return
    while true; do
        read -rsp "$2: " p1; echo
        read -rsp "Confirm: " p2; echo
        [[ -n "$p1" && "$p1" == "$p2" ]] && break
        warn "Empty or mismatched - try again."
    done
    printf -v "$var" '%s' "$p1"
}
[[ -n "${SITE_NAME:-}" ]] || read -rp "Site name (use the FQDN if you will add SSL later): " SITE_NAME
[[ -n "$SITE_NAME" ]] || die "Site name is required."
ask_secret DB_ROOT_PW "MariaDB root password"
ask_secret ADMIN_PW   "ERPNext Administrator password"

echo -e "\n${YELLOW}Summary${NC}
  User:        $BENCH_USER
  Bench:       ~/$BENCH_NAME  (Frappe/ERPNext $FRAPPE_BRANCH)
  Site:        $SITE_NAME
  HRMS:        $INSTALL_HRMS
  Production:  $PRODUCTION
  UFW:         $ENABLE_UFW"
read -rp "Proceed? (yes/no): " a; [[ "$a" =~ ^(y|yes)$ ]] || exit 0

# ─── 1. System packages ─────────────────────────────────────────────────────────
step "Installing system packages"
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get -y upgrade
PKGS=(git curl wget cron build-essential pkg-config
      libmariadb-dev mariadb-server mariadb-client
      xvfb libfontconfig1 fontconfig libxrender1 xfonts-75dpi xfonts-base
      nginx supervisor fail2ban ansible-core)
if apt-cache show redis-server &>/dev/null; then PKGS+=(redis-server); else
    PKGS+=(valkey-server)   # bench expects redis-server/redis-cli binaries
    apt-cache show valkey-redis-compat &>/dev/null && PKGS+=(valkey-redis-compat)
fi
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${PKGS[@]}"
sudo systemctl enable --now mariadb cron
ok "System packages installed"

# ─── 2. MariaDB ─────────────────────────────────────────────────────────────────
step "Configuring MariaDB ($(mariadb --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1))"
sudo tee /etc/mysql/mariadb.conf.d/60-frappe.cnf >/dev/null <<'EOF'
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

[mysql]
default-character-set = utf8mb4
EOF
# Password login for Frappe, keep unix_socket so `sudo mariadb` still works
DB_PW_SQL="${DB_ROOT_PW//\\/\\\\}"; DB_PW_SQL="${DB_PW_SQL//\'/\\\'}"
sudo mariadb <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('${DB_PW_SQL}') OR unix_socket;
DELETE FROM mysql.global_priv WHERE User='';
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
SQL
sudo systemctl restart mariadb
mariadb -uroot -p"$DB_ROOT_PW" -h localhost -e "SELECT 1" >/dev/null || die "MariaDB password login failed"
ok "MariaDB configured"

# ─── 3. wkhtmltopdf ─────────────────────────────────────────────────────────────
step "Installing wkhtmltopdf"
if ! command -v wkhtmltopdf &>/dev/null; then
    deb="wkhtmltox_${WKHTML_VER}.jammy_${ARCH}.deb"
    wget -q "https://github.com/wkhtmltopdf/packaging/releases/download/${WKHTML_VER}/${deb}" -O "/tmp/${deb}"
    if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "/tmp/${deb}"; then
        ok "$(wkhtmltopdf --version)"
    else
        warn "wkhtmltopdf failed to install - ERPNext will still work; use Chrome PDF generation in v16."
    fi
    rm -f "/tmp/${deb}"
else
    ok "wkhtmltopdf already present"
fi

# ─── 4. Node.js + Yarn via nvm ──────────────────────────────────────────────────
step "Installing Node.js $NODE_MAJOR and Yarn"
export NVM_DIR="$HOME/.nvm"
[[ -s "$NVM_DIR/nvm.sh" ]] || curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash
# shellcheck disable=SC1091
. "$NVM_DIR/nvm.sh"
nvm install "$NODE_MAJOR"
nvm alias default "$NODE_MAJOR"
nvm use default
npm install -g yarn
# supervisord doesn't source ~/.bashrc - make node visible system-wide
NODE_BIN_DIR="$(dirname "$(nvm which default)")"
for b in node npm npx yarn; do
    [[ -e "$NODE_BIN_DIR/$b" ]] && sudo ln -sf "$NODE_BIN_DIR/$b" "/usr/local/bin/$b"
done
ok "Node $(node -v), Yarn $(yarn -v)"

# ─── 5. uv, Python 3.14, bench ──────────────────────────────────────────────────
step "Installing uv, Python $PYTHON_VERSION and frappe-bench"
export PATH="$HOME/.local/bin:$PATH"
command -v uv &>/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh
uv python install "$PYTHON_VERSION"
PYTHON_BIN="$(uv python find "$PYTHON_VERSION")"
uv tool install --upgrade frappe-bench
grep -q '.local/bin' ~/.bashrc || echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
ok "Python: $PYTHON_BIN ($("$PYTHON_BIN" --version)), $(bench --version 2>&1 | tail -1)"

# ─── 6. Bench, site, apps ───────────────────────────────────────────────────────
cd "$HOME"
if [[ -d "$BENCH_NAME/apps/frappe" ]]; then
    warn "~/$BENCH_NAME already exists - skipping bench init"
else
    step "Initialising bench (this takes a while)"
    bench init "$BENCH_NAME" --frappe-branch "$FRAPPE_BRANCH" --python "$PYTHON_BIN" --verbose
fi
cd "$HOME/$BENCH_NAME"
chmod 711 "$HOME"   # nginx needs to traverse $HOME to reach sites/assets

# Temporary Redis from bench's own configs so site creation can reach cache/queue
start_bench_redis() {
    for c in config/redis_cache.conf config/redis_queue.conf; do
        [[ -f "$c" ]] || continue
        port=$(awk '/^port/{print $2}' "$c")
        redis-cli -p "$port" ping &>/dev/null || redis-server "$c" --daemonize yes
    done
}
stop_bench_redis() {
    for c in config/redis_cache.conf config/redis_queue.conf; do
        [[ -f "$c" ]] || continue
        port=$(awk '/^port/{print $2}' "$c")
        redis-cli -p "$port" shutdown nosave &>/dev/null || true
    done
}
start_bench_redis

if [[ -d "sites/$SITE_NAME" ]]; then
    warn "Site $SITE_NAME already exists - skipping new-site"
else
    step "Creating site $SITE_NAME"
    bench new-site "$SITE_NAME" \
        --db-root-username root \
        --db-root-password "$DB_ROOT_PW" \
        --admin-password "$ADMIN_PW"
fi

step "Installing ERPNext"
[[ -d apps/erpnext ]] || bench get-app erpnext --branch "$FRAPPE_BRANCH"
bench --site "$SITE_NAME" list-apps | grep -q '^erpnext' || bench --site "$SITE_NAME" install-app erpnext

if [[ "$INSTALL_HRMS" =~ ^(y|yes)$ ]]; then
    step "Installing HRMS"
    [[ -d apps/hrms ]] || bench get-app hrms --branch "$FRAPPE_BRANCH"
    bench --site "$SITE_NAME" list-apps | grep -q '^hrms' || bench --site "$SITE_NAME" install-app hrms
fi

bench use "$SITE_NAME"
chmod 600 sites/common_site_config.json "sites/$SITE_NAME/site_config.json"

# ─── 7. Production ──────────────────────────────────────────────────────────────
if [[ "$PRODUCTION" =~ ^(y|yes)$ ]]; then
    step "Setting up production (nginx + supervisor)"
    stop_bench_redis
    bench --site "$SITE_NAME" scheduler enable
    # bench lives in ~/.local/bin, so pass PATH through sudo
    sudo env "PATH=$PATH" bench setup production "$BENCH_USER" --yes

    SUPCONF=/etc/supervisor/supervisord.conf
    if ! grep -q "^chown=$BENCH_USER:$BENCH_USER" "$SUPCONF"; then
        sudo sed -i "/^\[unix_http_server\]/a chown=$BENCH_USER:$BENCH_USER" "$SUPCONF"
    fi
    sudo rm -f /etc/nginx/sites-enabled/default
    sudo systemctl enable supervisor nginx
    sudo systemctl restart supervisor
    sudo nginx -t && sudo systemctl reload nginx
    sleep 5
    sudo supervisorctl status || true

    if [[ "$ENABLE_UFW" =~ ^(y|yes)$ ]]; then
        step "Configuring ufw"
        sudo apt-get install -y ufw
        sudo ufw allow 22/tcp; sudo ufw allow 80/tcp; sudo ufw allow 443/tcp
        sudo ufw --force enable
    fi
    URL="http://$(hostname -I | awk '{print $1}')  (or http://$SITE_NAME)"
else
    stop_bench_redis
    URL="run 'cd ~/$BENCH_NAME && bench start', then open http://$(hostname -I | awk '{print $1}'):8000"
fi

echo -e "\n${GREEN}──────────────────────────────────────────────────────────────
 ERPNext $FRAPPE_BRANCH installed for user '$BENCH_USER'
 Bench:  ~/$BENCH_NAME
 Site:   $SITE_NAME
 Access: $URL
 Login:  Administrator / (the password you entered)
──────────────────────────────────────────────────────────────${NC}"
