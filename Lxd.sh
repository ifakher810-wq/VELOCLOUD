
#!/bin/bash
set -Eeuo pipefail

clear

echo "======================================"
echo "       VELOCLOUD LXD INSTALLER"
echo "======================================"

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root!"
    exit 1
fi

if ! grep -qi ubuntu /etc/os-release; then
    echo "This installer currently supports Ubuntu only."
    exit 1
fi

echo "[1/8] Updating system..."
apt-get update -y
apt-get upgrade -y

echo "[2/8] Installing dependencies..."
apt-get install -y snapd curl ca-certificates

echo "[3/8] Installing LXD..."
if ! snap list lxd >/dev/null 2>&1; then
    snap install lxd
fi

echo "[4/8] Waiting for LXD..."
snap services lxd
sleep 5

echo "[5/8] Initializing LXD..."
if ! lxc info >/dev/null 2>&1; then
    lxd init --auto
fi

echo "[6/8] Checking LXD..."
lxc version
lxc info

echo "[7/8] Creating test container..."

if ! lxc info | grep -q "Storage pools:"; then
    echo "Checking storage configuration..."
fi

if ! lxc storage list | grep -q default; then
    lxc storage create default dir
fi

if ! lxc profile device show default | grep -q root; then
    lxc profile device add default root disk \
        path=/ pool=default
fi

if ! lxc network show lxdbr0 >/dev/null 2>&1; then
    lxc network create lxdbr0 \
        ipv4.address=auto \
        ipv4.nat=true \
        ipv6.address=none
fi

if ! lxc profile device show default | grep -q eth0; then
    lxc profile device add default eth0 nic \
        name=eth0 network=lxdbr0
fi

if ! lxc info --resources >/dev/null 2>&1; then
    echo "Resource information unavailable"
fi

if ! lxc list --format csv | grep -q lxd-test; then
    lxc launch ubuntu:24.04 lxd-test
fi

echo "[8/8] Testing container..."

for i in $(seq 1 30); do
    if lxc exec lxd-test -- true >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

lxc exec lxd-test -- bash -c \
    "apt-get update -y && apt-get install -y curl"

echo "Checking internet..."
lxc exec lxd-test -- curl -4 -sS --max-time 15 \
    https://api.ipify.org

echo
echo "======================================"
echo "       INSTALLATION SUCCESS"
echo "======================================"

echo "LXD VERSION:"
lxc version

echo
echo "CONTAINER LIST:"
lxc list

echo
echo "NETWORK:"
lxc network list

echo
echo "STORAGE:"
lxc storage list

echo
echo "PUBLIC IPv4:"
curl -4 -sS --max-time 15 https://api.ipify.org || true

echo
echo "VELOCLOUD LXD IS READY!"
