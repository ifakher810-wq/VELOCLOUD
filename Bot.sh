
#!/usr/bin/env bash
set -Eeuo pipefail

# =========================================================
# ARIZNODESLABS VPS BOT - ONE CLICK AUTO INSTALLER
# Original bot source: VELOCLOUD / bo.sh
# =========================================================

SOURCE_URL="https://raw.githubusercontent.com/ifakher810-wq/VELOCLOUD/refs/heads/main/bo.sh"
SERVICE="ariznodes-vpsbot"
DIR="$(pwd)"

clear 2>/dev/null || true
echo "=============================================="
echo "       ARIZNODESLABS VPS AUTO INSTALLER"
echo "=============================================="

# Root permission
if [ "$(id -u)" != "0" ]; then
    echo "Getting automatic root permission..."
    command -v sudo >/dev/null 2>&1 || {
        echo "sudo is required. Run this installer as root."
        exit 1
    }
    exec sudo -E bash "$0" "$@"
fi

# Ask credentials first
read -rsp "Enter Discord Bot Token: " BOT_TOKEN
echo
read -rp "Enter Owner Discord ID: " OWNER_ID

if [ -z "$BOT_TOKEN" ]; then
    echo "ERROR: Bot token cannot be empty."
    exit 1
fi

if ! [[ "$OWNER_ID" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Owner ID must contain digits only."
    exit 1
fi

# LXD choice
echo
echo "=============================================="
echo "        LXD AUTOMATIC INSTALLER"
echo "=============================================="
read -rp "Install LXD automatically? (YES/NO): " LXD_CHOICE
LXD_CHOICE="$(echo "$LXD_CHOICE" | tr '[:lower:]' '[:upper:]')"

if [[ "$LXD_CHOICE" != "YES" && "$LXD_CHOICE" != "NO" ]]; then
    echo "Invalid choice. Enter YES or NO."
    exit 1
fi

# Internet check
echo
echo "[1/8] Checking internet connection..."

if ! curl -fsSL --connect-timeout 10 https://github.com >/dev/null; then
    echo "ERROR: Internet connection unavailable."
    exit 1
fi

echo "Internet connection OK."

export DEBIAN_FRONTEND=noninteractive

# System packages
echo "[2/8] Installing system requirements..."

apt-get update -y
apt-get install -y \
    curl wget git ca-certificates \
    python3 python3-pip python3-venv \
    sudo snapd openssh-client openssh-server \
    sqlite3 nano

# LXD installation
echo "[3/8] LXD setup..."

if [ "$LXD_CHOICE" = "YES" ]; then
    if ! command -v snap >/dev/null 2>&1; then
        apt-get install -y snapd
    fi

    systemctl enable --now snapd.socket || true
    systemctl start snapd || true

    if ! command -v lxd >/dev/null 2>&1; then
        snap install lxd
    fi

    export PATH="/snap/bin:$PATH"

    if ! lxc info >/dev/null 2>&1; then
        lxd init --auto
    fi

    systemctl enable --now snap.lxd.daemon.service || true

    if ! lxc info >/dev/null 2>&1; then
        echo "ERROR: LXD is installed but not responding."
        exit 1
    fi

    echo "LXD installation and initialization completed."
else
    echo "LXD installation skipped."
    if ! command -v lxc >/dev/null 2>&1; then
        echo "WARNING: VPS deployment will not work until LXD is installed."
    fi
fi

# Download original bot bundle
echo "[4/8] Downloading original ArizNodesLabs bot..."

TMP_SOURCE="$(mktemp)"
trap 'rm -f "$TMP_SOURCE"' EXIT

curl -fL --retry 3 "$SOURCE_URL" -o "$TMP_SOURCE"

if ! grep -q 'ARIZ_BOT_PY' "$TMP_SOURCE"; then
    echo "ERROR: Unexpected source file."
    exit 1
fi

# Create configuration before source runs
umask 077
cat > "$DIR/.env" <<EOF
DISCORD_TOKEN=$BOT_TOKEN
OWNER_IDS=$OWNER_ID
PREFIX=!
MAX_VPS_PER_USER=3
MAX_RAM_MB=8192
MAX_CPU=4
MAX_DISK_GB=50
PINGGY_TOKEN=
LXC_BIN=/snap/bin/lxc
EOF

# Generate bot.py and requirements.txt from source
echo "[5/8] Generating bot files..."
bash "$TMP_SOURCE"

# Python environment
echo "[6/8] Installing Python dependencies..."

python3 -m venv "$DIR/venv"

"$DIR/venv/bin/pip" install --upgrade pip
"$DIR/venv/bin/pip" install -r "$DIR/requirements.txt"

# Validate Python syntax
"$DIR/venv/bin/python" -m py_compile "$DIR/bot.py"

# Create systemd service
echo "[7/8] Creating 24/7 systemd service..."

cat > "/etc/systemd/system/${SERVICE}.service" <<EOF
[Unit]
Description=ArizNodesLabs VPS Deployer Bot
After=network-online.target snap.lxd.daemon.service
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$DIR
EnvironmentFile=$DIR/.env
ExecStart=$DIR/venv/bin/python $DIR/bot.py
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

chmod 600 "$DIR/.env"

systemctl daemon-reload
systemctl enable "$SERVICE"

# Start bot
echo "[8/8] Starting Discord VPS Bot..."

systemctl restart "$SERVICE"

sleep 3

if systemctl is-active --quiet "$SERVICE"; then
    echo
    echo "=============================================="
    echo "       INSTALLATION COMPLETED"
    echo "=============================================="
    echo "Bot service: RUNNING"
    echo "Working directory: $DIR"
    echo
    echo "Useful commands:"
    echo "Status:  systemctl status $SERVICE"
    echo "Logs:    journalctl -u $SERVICE -f"
    echo "Restart: systemctl restart $SERVICE"
    echo "Stop:    systemctl stop $SERVICE"
    echo
else
    echo "Bot did not start. Showing recent logs:"
    journalctl -u "$SERVICE" -n 60 --no-pager || true
    exit 1
fi
