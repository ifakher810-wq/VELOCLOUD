
#!/usr/bin/env bash
set -Eeuo pipefail

# =====================================================
# VELOCLOUD - AUTOMATIC QEMU/KVM VPS BOT INSTALLER
# =====================================================

if [[ $EUID -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
fi

clear
echo "=========================================="
echo "       VELOCLOUD VPS AUTO INSTALLER"
echo "=========================================="

read -rp "Discord Bot Token: " BOT_TOKEN
read -rp "Owner Discord ID: " OWNER_ID

if [[ -z "$BOT_TOKEN" || ! "$OWNER_ID" =~ ^[0-9]+$ ]]; then
    echo "Invalid Discord Token or Owner ID."
    exit 1
fi

echo "[1/7] Installing system packages..."

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
    qemu-system-x86 qemu-utils \
    cloud-image-utils \
    curl wget openssl \
    python3 python3-venv \
    ca-certificates ufw

if [[ ! -e /dev/kvm ]]; then
    echo "ERROR: /dev/kvm not found. KVM is unavailable."
    exit 1
fi

echo "[2/7] Creating VELOCLOUD system..."

mkdir -p /opt/velocloud/{vms,images}
cd /opt/velocloud

echo "[3/7] Installing Python dependencies..."

python3 -m venv venv
./venv/bin/pip install --upgrade pip
./venv/bin/pip install discord.py

echo "[4/7] Downloading Ubuntu 24.04 image..."

IMAGE="/opt/velocloud/images/ubuntu-24.04.img"

if [[ ! -s "$IMAGE" ]]; then
    curl -fL --retry 3 \
      "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img" \
      -o "$IMAGE"
fi

echo "[5/7] Creating VELOCLOUD bot..."

cat > /opt/velocloud/bot.py <<'PY'
import os, sqlite3, secrets, string, subprocess, asyncio
import discord
from discord import app_commands
from discord.ext import commands

BASE = "/opt/velocloud"
VM_DIR = BASE + "/vms"
IMAGE = BASE + "/images/ubuntu-24.04.img"
OWNER = int(os.environ["OWNER_ID"])
TOKEN = os.environ["BOT_TOKEN"]
DB = sqlite3.connect(BASE + "/vps.db", check_same_thread=False)
DB.row_factory = sqlite3.Row

DB.execute("""
CREATE TABLE IF NOT EXISTS vps(
 name TEXT PRIMARY KEY,
 owner INTEGER,
 username TEXT,
 password TEXT,
 ram INTEGER,
 cpu INTEGER,
 port INTEGER
)
""")
DB.commit()

intents = discord.Intents.default()
bot = commands.Bot(command_prefix="!", intents=intents)

def query(sql, args=()):
    cur = DB.execute(sql, args)
    DB.commit()
    return cur.fetchall()

def random_id(n=8):
    return "".join(secrets.choice(string.ascii_lowercase + string.digits) for _ in range(n))

def getvm(name):
    rows = query("SELECT * FROM vps WHERE name=?", (name,))
    return rows[0] if rows else None

def is_admin(uid):
    return uid == OWNER

def run(args, check=True):
    return subprocess.run(args, check=check, capture_output=True, text=True)

def service_name(name):
    return "velocloud-" + name + ".service"

def create_service(name, disk, seed, ram, cpu, port):
    unit = f"""[Unit]
Description=VELOCLOUD VPS {name}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/qemu-system-x86_64 -name {name} -machine q35,accel=kvm -cpu host -smp {cpu} -m {ram} -display none -serial none -monitor none -netdev user,id=n1,hostfwd=tcp:0.0.0.0:{port}-:22 -device virtio-net-pci,netdev=n1 -drive file={disk},if=virtio,format=qcow2 -drive file={seed},if=virtio,format=raw
Restart=no
KillMode=control-group
TimeoutStopSec=45

[Install]
WantedBy=multi-user.target
"""
    path = "/etc/systemd/system/" + service_name(name)
    with open(path, "w") as f:
        f.write(unit)
    run(["systemctl", "daemon-reload"])
    run(["systemctl", "enable", service_name(name)])
    run(["systemctl", "start", service_name(name)])

def vm_running(name):
    r = run(["systemctl", "is-active", service_name(name)], check=False)
    return r.returncode == 0

async def create_vm(interaction, ram, cpu):
    await interaction.response.defer(ephemeral=True)

    count = query("SELECT name FROM vps WHERE owner=?", (interaction.user.id,))
    if count and not is_admin(interaction.user.id):
        return await interaction.followup.send(
            "You already have a VPS.", ephemeral=True
        )

    name = "vc-" + random_id()
    username = "vcuser" + random_id(4)
    password = secrets.token_urlsafe(18)

    used = {r["port"] for r in query("SELECT port FROM vps")}
    port = next((p for p in range(22000, 23000) if p not in used), None)

    if port is None:
        return await interaction.followup.send("VPS capacity is full.", ephemeral=True)

    disk = VM_DIR + "/" + name + ".qcow2"
    seed = VM_DIR + "/" + name + "-seed.img"
    userdata = VM_DIR + "/" + name + "-user-data"
    metadata = VM_DIR + "/" + name + "-meta-data"

    try:
        await asyncio.to_thread(
            run, ["qemu-img", "create", "-f", "qcow2", "-F", "qcow2",
                  "-b", IMAGE, disk, "10G"]
        )

        hashed = subprocess.check_output(
            ["openssl", "passwd", "-6", password],
            text=True
        ).strip()

        cloud = f"""#cloud-config
hostname: {name}
users:
  - name: {username}
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    passwd: '{hashed}'
ssh_pwauth: true
disable_root: true
package_update: true
packages:
  - openssh-server
runcmd:
  - systemctl enable --now ssh
"""
        with open(userdata, "w") as f:
            f.write(cloud)
        with open(metadata, "w") as f:
            f.write(f"instance-id: {name}\nlocal-hostname: {name}\n")

        os.chmod(userdata, 0o600)

        await asyncio.to_thread(
            run, ["cloud-localds", seed, userdata, metadata]
        )

        await asyncio.to_thread(
            create_service, name, disk, seed, ram, cpu, port
        )

        query(
            "INSERT INTO vps VALUES(?,?,?,?,?,?,?)",
            (name, interaction.user.id, username, password, ram, cpu, port)
        )

    except Exception as exc:
        run(["systemctl", "disable", "--now", service_name(name)], check=False)
        for p in (disk, seed, userdata, metadata,
                  "/etc/systemd/system/" + service_name(name)):
            if os.path.exists(p):
                os.remove(p)
        run(["systemctl", "daemon-reload"], check=False)
        return await interaction.followup.send(
            "Deployment failed: " + str(exc)[:800], ephemeral=True
        )

    embed = discord.Embed(
        title="VELOCLOUD VPS CREATED",
        description=f"Your VPS `{name}` is starting.",
        color=0x5865F2
    )
    embed.add_field(name="Operating System", value="Ubuntu 24.04")
    embed.add_field(name="CPU", value=f"{cpu} Core")
    embed.add_field(name="RAM", value=f"{ram} MB")
    embed.add_field(name="Disk", value="10 GB")
    embed.add_field(name="Hostname", value=name)
    embed.add_field(name="Username", value=username)
    embed.add_field(name="Password", value=password, inline=False)
    embed.add_field(name="SSH Port", value=str(port))
    embed.add_field(
        name="SSH Command",
        value=f"ssh {username}@YOUR_SERVER_PUBLIC_IP -p {port}",
        inline=False
    )
    await interaction.followup.send(embed=embed, ephemeral=True)

class DeployView(discord.ui.View):
    def __init__(self):
        super().__init__(timeout=None)

    @discord.ui.button(label="1 Core / 1 GB RAM", style=discord.ButtonStyle.primary)
    async def starter(self, interaction, button):
        await create_vm(interaction, 1024, 1)

    @discord.ui.button(label="2 Core / 2 GB RAM", style=discord.ButtonStyle.success)
    async def basic(self, interaction, button):
        await create_vm(interaction, 2048, 2)

@bot.event
async def on_ready():
    await bot.tree.sync()
    print("VELOCLOUD online:", bot.user)

@bot.tree.command(name="panel", description="Open VELOCLOUD VPS deployer")
async def panel(interaction):
    embed = discord.Embed(
        title="VELOCLOUD VPS DEPLOYER",
        description=(
            "Create your own QEMU/KVM VPS.\n\n"
            "**Available Plans**\n"
            "1 Core CPU / 1 GB RAM\n"
            "2 Core CPU / 2 GB RAM\n\n"
            "Ubuntu 24.04 | 10 GB Disk | SSH Access"
        ),
        color=0x5865F2
    )
    await interaction.response.send_message(embed=embed, view=DeployView())

@bot.tree.command(name="myvps", description="View your VPS")
async def myvps(interaction):
    rows = query("SELECT * FROM vps WHERE owner=?", (interaction.user.id,))
    if not rows:
        return await interaction.response.send_message("No VPS found.", ephemeral=True)

    embed = discord.Embed(title="YOUR VELOCLOUD VPS", color=0x5865F2)
    for r in rows:
        embed.add_field(
            name=r["name"],
            value=(
                f"CPU: {r['cpu']} Core | RAM: {r['ram']} MB\n"
                f"SSH Port: {r['port']}\n"
                f"Status: {'Running' if vm_running(r['name']) else 'Stopped'}"
            ),
            inline=False
        )
    await interaction.response.send_message(embed=embed, ephemeral=True)

@bot.tree.command(name="manage", description="Manage your VPS")
@app_commands.describe(name="Your VPS name", action="Choose action")
@app_commands.choices(action=[
    app_commands.Choice(name="Start", value="start"),
    app_commands.Choice(name="Stop", value="stop"),
    app_commands.Choice(name="Restart", value="restart"),
    app_commands.Choice(name="Delete", value="delete")
])
async def manage(interaction, name: str, action: str):
    r = getvm(name)
    if not r:
        return await interaction.response.send_message("VPS not found.", ephemeral=True)

    if r["owner"] != interaction.user.id and not is_admin(interaction.user.id):
        return await interaction.response.send_message("Not your VPS.", ephemeral=True)

    await interaction.response.defer(ephemeral=True)
    service = service_name(name)

    try:
        if action == "delete":
            run(["systemctl", "disable", "--now", service], check=False)
            for p in (
                VM_DIR + "/" + name + ".qcow2",
                VM_DIR + "/" + name + "-seed.img",
                VM_DIR + "/" + name + "-user-data",
                VM_DIR + "/" + name + "-meta-data",
                "/etc/systemd/system/" + service
            ):
                if os.path.exists(p):
                    os.remove(p)
            query("DELETE FROM vps WHERE name=?", (name,))
            run(["systemctl", "daemon-reload"])
        else:
            run(["systemctl", action, service])
        await interaction.followup.send(
            f"VPS `{name}`: {action.upper()} completed.",
            ephemeral=True
        )
    except Exception as exc:
        await interaction.followup.send(
            "Operation failed: " + str(exc)[:700], ephemeral=True
        )

@bot.tree.command(name="status", description="Check VPS status")
async def status(interaction, name: str):
    r = getvm(name)
    if not r or (r["owner"] != interaction.user.id and not is_admin(interaction.user.id)):
        return await interaction.response.send_message("VPS not found or not yours.", ephemeral=True)
    await interaction.response.send_message(
        f"`{name}`: {'Running' if vm_running(name) else 'Stopped'}",
        ephemeral=True
    )

@bot.tree.command(name="capacity", description="Owner: view host capacity")
async def capacity(interaction):
    if not is_admin(interaction.user.id):
        return await interaction.response.send_message("Owner only.", ephemeral=True)
    total = query("SELECT COUNT(*) AS n FROM vps")[0]["n"]
    await interaction.response.send_message(
        f"Registered VPS: {total}\nSSH ports allocated: {total}",
        ephemeral=True
    )

bot.run(TOKEN)
PY

echo "[6/7] Saving bot configuration..."

cat > /opt/velocloud/.env <<EOF
BOT_TOKEN=$BOT_TOKEN
OWNER_ID=$OWNER_ID
EOF
chmod 600 /opt/velocloud/.env

echo "[7/7] Creating and starting 24/7 service..."

cat > /etc/systemd/system/velocloud-bot.service <<'SERVICE'
[Unit]
Description=VELOCLOUD Discord VPS Bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/velocloud
EnvironmentFile=/opt/velocloud/.env
ExecStart=/opt/velocloud/venv/bin/python /opt/velocloud/bot.py
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
SERVICE

if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    ufw allow 22000:22999/tcp
fi

systemctl daemon-reload
systemctl enable --now velocloud-bot

echo
echo "=========================================="
echo "       VELOCLOUD INSTALLATION COMPLETE"
echo "=========================================="
echo "Discord bot service: ONLINE"
echo "Panel command: /panel"
echo "Manage VPS: /manage"
echo "View VPS: /myvps"
echo "Logs: journalctl -u velocloud-bot -f"
echo "=========================================="
