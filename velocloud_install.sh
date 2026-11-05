#!/usr/bin/env bash
set -Eeuo pipefail
# VELOCLOUD QEMU/KVM Discord VPS installer
# English interface. Existing VM data and database are preserved.

APP=/opt/velocloud
DATA=/var/lib/velocloud
VMS=$DATA/vms
IMAGES=$DATA/images
BACKUPS=$DATA/backups
ENV=$APP/.env
BOT=$APP/bot.py
SERVICE=/etc/systemd/system/velocloud-bot.service
IMAGE=$IMAGES/ubuntu-24.04-cloudimg-amd64.img
IMAGE_URL=https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

log(){ echo; echo "[VELOCLOUD] $*"; }
die(){ echo "[ERROR] $*" >&2; exit 1; }
trap 'echo "[ERROR] Failed at line $LINENO. Existing VM data was not intentionally removed." >&2' ERR
[[ $EUID -eq 0 ]] || die "Run: sudo bash install.sh"

install -d -m 0750 "$APP" "$DATA" "$VMS" "$IMAGES" "$BACKUPS"
export DEBIAN_FRONTEND=noninteractive
log "Installing QEMU/KVM and system packages"
apt-get update
apt-get install -y qemu-system-x86 qemu-utils cloud-image-utils python3 python3-venv python3-pip curl ca-certificates iproute2 procps openssh-client

if [[ ! -e /dev/kvm ]]; then
  log "WARNING: /dev/kvm is missing. Bot installation can continue, but real VM deployment requires host KVM support."
fi

log "Preparing Ubuntu 24.04 cloud image"
if [[ ! -s "$IMAGE" ]]; then
  curl -fL --retry 4 "$IMAGE_URL" -o "$IMAGE.tmp"
  mv "$IMAGE.tmp" "$IMAGE"
fi
qemu-img info "$IMAGE" >/dev/null

log "Installing Python packages"
python3 -m venv "$APP/venv"
"$APP/venv/bin/pip" install --upgrade pip
"$APP/venv/bin/pip" install "discord.py>=2.4,<3" "python-dotenv>=1.0" "asyncssh>=2.14"

if [[ ! -f "$ENV" ]]; then
  read -r -p "Discord Bot Token: " TOKEN
  read -r -p "Owner Discord User ID: " OWNER
  [[ -n "$TOKEN" && "$OWNER" =~ ^[0-9]+$ ]] || die "Invalid token or owner ID."
  cat > "$ENV" <<EOF
BOT_TOKEN=$TOKEN
OWNER_ID=$OWNER
BOT_NAME=VELOCLOUD
PUBLIC_IP=
MAX_VPS_PER_USER=1
MAX_TOTAL_VPS=20
SSH_PORT_START=2200
SSH_PORT_END=2299
EOF
  chmod 600 "$ENV"
else
  log "Keeping existing .env file"
fi

log "Writing Discord bot"
cat > "$BOT" <<'PY'
import os, re, time, uuid, json, shutil, string, secrets, asyncio, subprocess, ipaddress
from pathlib import Path
import sqlite3
import discord
from discord.ext import commands
from dotenv import load_dotenv
import asyncssh

APP=Path("/opt/velocloud"); DATA=Path("/var/lib/velocloud")
VMS=DATA/"vms"; BACKUPS=DATA/"backups"; IMAGE=DATA/"images/ubuntu-24.04-cloudimg-amd64.img"
DB=DATA/"velocloud.sqlite3"
load_dotenv(APP/".env")
TOKEN=os.getenv("BOT_TOKEN",""); OWNER=int(os.getenv("OWNER_ID","0"))
BOT_NAME=os.getenv("BOT_NAME","VELOCLOUD")
PUBLIC_IP=os.getenv("PUBLIC_IP","").strip()
MAX_USER=int(os.getenv("MAX_VPS_PER_USER","1")); MAX_TOTAL=int(os.getenv("MAX_TOTAL_VPS","20"))
PORT_MIN=int(os.getenv("SSH_PORT_START","2200")); PORT_MAX=int(os.getenv("SSH_PORT_END","2299"))
DISK_GB=10
intents=discord.Intents.default(); intents.message_content=True
bot=commands.Bot(command_prefix="!",intents=intents,help_command=None)

def db():
    c=sqlite3.connect(DB,timeout=30); c.row_factory=sqlite3.Row; return c
def init():
    with db() as c:
        c.execute("""CREATE TABLE IF NOT EXISTS vps(
        id TEXT PRIMARY KEY,owner INTEGER,hostname TEXT,ram INTEGER,cpu INTEGER,
        disk INTEGER,port INTEGER UNIQUE,password TEXT,status TEXT,created REAL)""")
        c.execute("CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY,value TEXT)")
        c.execute("INSERT OR IGNORE INTO settings VALUES('deploy_enabled','1')")
        c.execute("INSERT OR IGNORE INTO settings VALUES('maintenance','0')")
        c.execute("""CREATE TABLE IF NOT EXISTS audit(
        id INTEGER PRIMARY KEY,actor INTEGER,vm TEXT,action TEXT,detail TEXT,created REAL)""")
def run(args,timeout=60,check=False):
    p=subprocess.run(args,text=True,capture_output=True,timeout=timeout)
    if check and p.returncode: raise RuntimeError((p.stderr or p.stdout)[-1500:])
    return p
def audit(actor,vid,action,detail=""):
    with db() as c: c.execute("INSERT INTO audit(actor,vm,action,detail,created) VALUES(?,?,?,?,?)",(actor,vid,action,detail[:800],time.time()))
def vm_dir(vid):
    if not re.fullmatch(r"[a-f0-9]{8}",vid): raise ValueError("Invalid VPS ID")
    return VMS/vid
def get_vm(vid):
    with db() as c: return c.execute("SELECT * FROM vps WHERE id=?",(vid,)).fetchone()
def user_vms(uid):
    with db() as c: return c.execute("SELECT * FROM vps WHERE owner=? ORDER BY created DESC",(uid,)).fetchall()
def setting(k,default):
    with db() as c:
        r=c.execute("SELECT value FROM settings WHERE key=?",(k,)).fetchone()
        return r["value"] if r else default
def set_setting(k,v):
    with db() as c: c.execute("INSERT INTO settings VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",(k,str(v)))
def pwgen():
    chars=string.ascii_letters+string.digits+"!@#_-"
    return "".join(secrets.choice(chars) for _ in range(22))
def ipaddr():
    if PUBLIC_IP: return PUBLIC_IP
    try:
        x=run(["curl","-4","-fsS","--max-time","8","https://api.ipify.org"],10,True).stdout.strip()
        ipaddress.ip_address(x); return x
    except Exception: return "SET_PUBLIC_IP_IN_ENV"
def free_port():
    with db() as c: used={r["port"] for r in c.execute("SELECT port FROM vps")}
    for p in range(PORT_MIN,PORT_MAX+1):
        if p not in used: return p
    raise RuntimeError("SSH port pool is full")
def unit(vid): return "velocloud-vm-"+vid+".service"
def systemctl(*args,timeout=60): return run(["systemctl",*args],timeout)
def write_seed(d,hostname,password):
    pw=password.replace("'","''")
    (d/"user-data").write_text(f"""#cloud-config
hostname: {hostname}
manage_etc_hosts: true
users:
  - default
  - name: ubuntu
    groups: [adm, sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    plain_text_passwd: '{pw}'
ssh_pwauth: true
disable_root: true
package_update: true
packages: [openssh-server, curl, sudo]
runcmd:
  - systemctl enable ssh
  - systemctl restart ssh
  - touch /var/lib/velocloud-ready
""")
    (d/"meta-data").write_text(f"instance-id: vc-{d.name}\nlocal-hostname: {hostname}\n")
    run(["cloud-localds",str(d/"seed.iso"),str(d/"user-data"),str(d/"meta-data")],60,True)
def create_unit(vid,ram,cpu,port):
    import shlex
    d=vm_dir(vid)
    args=["/usr/bin/qemu-system-x86_64","-name","VELOCLOUD-"+vid,
    "-machine","q35,accel=kvm","-enable-kvm","-cpu","host","-smp",str(cpu),"-m",str(ram),
    "-drive",f"file={d/'disk.qcow2'},if=virtio,format=qcow2",
    "-drive",f"file={d/'seed.iso'},if=virtio,format=raw,readonly=on",
    "-netdev",f"user,id=n1,hostfwd=tcp:0.0.0.0:{port}-:22","-device","virtio-net-pci,netdev=n1",
    "-display","none","-serial",f"file:{d/'console.log'}","-monitor","none","-no-reboot"]
    text=f"""[Unit]
Description=VELOCLOUD QEMU VPS {vid}
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart={shlex.join(args)}
Restart=on-failure
RestartSec=5
KillSignal=SIGTERM
TimeoutStopSec=40
[Install]
WantedBy=multi-user.target
"""
    Path("/etc/systemd/system",unit(vid)).write_text(text)
    systemctl("daemon-reload",timeout=30)
    p=systemctl("enable","--now",unit(vid))
    if p.returncode: raise RuntimeError(p.stderr[-1200:])
async def ssh_conn(vm):
    return await asyncssh.connect("127.0.0.1",port=vm["port"],username="ubuntu",
      password=vm["password"],known_hosts=None,connect_timeout=8)
async def ssh_ready(port,password,seconds=420):
    until=time.time()+seconds
    while time.time()<until:
        try:
            async with asyncssh.connect("127.0.0.1",port=port,username="ubuntu",password=password,known_hosts=None,connect_timeout=5) as s:
                r=await s.run("echo VC_SSH_READY",check=True,timeout=8)
                if "VC_SSH_READY" in r.stdout: return True
        except Exception: await asyncio.sleep(5)
    return False
async def progress(i,msg):
    try: await i.edit_original_response(content=msg)
    except Exception: pass

async def deploy(i,ram,cpu):
    uid=i.user.id
    if not Path("/dev/kvm").exists(): await progress(i,"❌ KVM is not available on the host."); return
    if not IMAGE.exists(): await progress(i,"❌ Ubuntu image is missing."); return
    if setting("maintenance","0")=="1" and uid!=OWNER: await progress(i,"🛠️ Platform is in maintenance mode."); return
    if setting("deploy_enabled","1")!="1" and uid!=OWNER: await progress(i,"⛔ Deployments are disabled."); return
    if len(user_vms(uid))>=MAX_USER and uid!=OWNER: await progress(i,"⛔ Your VPS limit has been reached."); return
    with db() as c: total=c.execute("SELECT COUNT(*) FROM vps").fetchone()[0]
    if total>=MAX_TOTAL and uid!=OWNER: await progress(i,"⛔ Platform capacity is full."); return
    vid=uuid.uuid4().hex[:8]; host="vc-"+vid; password=pwgen(); port=free_port(); d=vm_dir(vid)
    try:
        await progress(i,"🟡 **Creating virtual machine...**")
        d.mkdir(mode=0o750)
        await progress(i,"🟡 **Creating 10 GB virtual disk...**")
        run(["qemu-img","create","-f","qcow2","-F","qcow2","-b",str(IMAGE),str(d/"disk.qcow2"),f"{DISK_GB}G"],90,True)
        await progress(i,"🟡 **Preparing Ubuntu 24.04 cloud-init...**")
        write_seed(d,host,password)
        with db() as c:
            c.execute("INSERT INTO vps VALUES(?,?,?,?,?,?,?,?,?,?)",(vid,uid,host,ram,cpu,DISK_GB,port,password,"creating",time.time()))
        await progress(i,"🟡 **Starting QEMU/KVM...**")
        create_unit(vid,ram,cpu,port)
        with db() as c: c.execute("UPDATE vps SET status='booting' WHERE id=?",(vid,))
        await progress(i,"🟡 **Ubuntu is booting. Waiting for SSH verification...**")
        ok=await ssh_ready(port,password)
        if not ok:
            with db() as c: c.execute("UPDATE vps SET status='boot_failed' WHERE id=?",(vid,))
            audit(uid,vid,"deploy_failed","SSH timeout")
            await progress(i,f"⚠️ VPS `{vid}` exists, but SSH verification failed. It is NOT marked Ready. Check VM logs.")
            return
        with db() as c: c.execute("UPDATE vps SET status='running' WHERE id=?",(vid,))
        audit(uid,vid,"deploy","SSH verified")
        await progress(i,f"🟢 **Your VELOCLOUD VPS is Ready!**\n\n**ID:** `{vid}`\n**Hostname:** `{host}`\n**OS:** Ubuntu 24.04 LTS\n**RAM:** {ram} MB\n**CPU:** {cpu} vCPU\n**Disk:** 10 GB\n**SSH Host:** `{ipaddr()}`\n**SSH Port:** `{port}`\n**Username:** `ubuntu`\n**Password:** `{password}`\n\nUse `!manage {vid}` for controls. Keep credentials private.")
    except Exception as e:
        with db() as c: c.execute("UPDATE vps SET status='error' WHERE id=?",(vid,))
        audit(uid,vid,"deploy_error",str(e))
        await progress(i,f"❌ Deployment failed:\n```text\n{str(e)[:1000]}\n```\nVM files were retained for diagnosis.")

class DeployView(discord.ui.View):
    def __init__(self): super().__init__(timeout=None)
    @discord.ui.button(label="Deploy Starter | 1 GB",style=discord.ButtonStyle.primary,custom_id="vc:starter")
    async def starter(self,i,b):
        await i.response.defer(ephemeral=True); await deploy(i,1024,1)
    @discord.ui.button(label="Deploy Pro | 2 GB",style=discord.ButtonStyle.success,custom_id="vc:pro")
    async def pro(self,i,b):
        await i.response.defer(ephemeral=True); await deploy(i,2048,2)

class Confirm(discord.ui.View):
    def __init__(self,owner,vid,action):
        super().__init__(timeout=60); self.owner=owner; self.vid=vid; self.action=action
    @discord.ui.button(label="Confirm",style=discord.ButtonStyle.danger)
    async def yes(self,i,b):
        if i.user.id not in (self.owner,OWNER): await i.response.send_message("Not authorized.",ephemeral=True); return
        await i.response.defer(ephemeral=True)
        vm=get_vm(self.vid)
        if not vm: await i.followup.send("VPS not found.",ephemeral=True); return
        if self.action=="delete":
            systemctl("disable","--now",unit(self.vid))
            Path("/etc/systemd/system",unit(self.vid)).unlink(missing_ok=True)
            systemctl("daemon-reload")
            shutil.rmtree(vm_dir(self.vid),ignore_errors=True)
            with db() as c: c.execute("DELETE FROM vps WHERE id=?",(self.vid,))
            audit(i.user.id,self.vid,"delete")
            await i.followup.send("VPS and virtual disk deleted.",ephemeral=True)
        elif self.action=="reinstall":
            systemctl("stop",unit(self.vid))
            d=vm_dir(self.vid); (d/"disk.qcow2").unlink(missing_ok=True)
            run(["qemu-img","create","-f","qcow2","-F","qcow2","-b",str(IMAGE),str(d/"disk.qcow2"),f"{vm['disk']}G"],90,True)
            password=pwgen(); write_seed(d,vm["hostname"],password)
            with db() as c: c.execute("UPDATE vps SET password=?,status='reinstalling' WHERE id=?",(password,self.vid))
            systemctl("start",unit(self.vid))
            ok=await ssh_ready(vm["port"],password)
            with db() as c: c.execute("UPDATE vps SET status=? WHERE id=?",("running" if ok else "boot_failed",self.vid))
            await i.followup.send(("Reinstall complete. New password: `"+password+"`") if ok else "Reinstall started, but SSH verification failed.",ephemeral=True)
    @discord.ui.button(label="Cancel",style=discord.ButtonStyle.secondary)
    async def no(self,i,b): await i.response.edit_message(content="Cancelled.",view=None)

class Manage(discord.ui.View):
    def __init__(self,vid): super().__init__(timeout=600); self.vid=vid
    async def auth(self,i):
        vm=get_vm(self.vid)
        if not vm or i.user.id not in (vm["owner"],OWNER):
            await i.response.send_message("VPS not found or not authorized.",ephemeral=True); return None
        return vm
    async def service_action(self,i,op):
        vm=await self.auth(i)
        if not vm:return
        await i.response.defer(ephemeral=True)
        p=systemctl(op,unit(self.vid))
        if p.returncode==0:
            with db() as c: c.execute("UPDATE vps SET status=? WHERE id=?",("running" if op in ("start","restart") else "stopped",self.vid))
            audit(i.user.id,self.vid,op)
            await i.followup.send(f"{op.title()} command completed.",ephemeral=True)
        else: await i.followup.send(p.stderr[-900:],ephemeral=True)
    @discord.ui.button(label="Start",style=discord.ButtonStyle.success,row=0)
    async def start(self,i,b): await self.service_action(i,"start")
    @discord.ui.button(label="Stop",style=discord.ButtonStyle.danger,row=0)
    async def stop(self,i,b): await self.service_action(i,"stop")
    @discord.ui.button(label="Restart",style=discord.ButtonStyle.primary,row=0)
    async def restart(self,i,b): await self.service_action(i,"restart")
    @discord.ui.button(label="Information",style=discord.ButtonStyle.secondary,row=1)
    async def info(self,i,b):
        vm=await self.auth(i)
        if not vm:return
        active=systemctl("is-active",unit(self.vid)).stdout.strip()
        e=discord.Embed(title="VELOCLOUD VPS | "+self.vid,color=discord.Color.blurple())
        for k,v in [("Hostname",vm["hostname"]),("Service",active),("Status",vm["status"]),("RAM",str(vm["ram"])+" MB"),("CPU",str(vm["cpu"])),("Disk",str(vm["disk"])+" GB"),("SSH Port",str(vm["port"]))]: e.add_field(name=k,value=v)
        await i.response.send_message(embed=e,ephemeral=True)
    @discord.ui.button(label="SSH Connection",style=discord.ButtonStyle.secondary,row=1)
    async def ssh(self,i,b):
        vm=await self.auth(i)
        if vm: await i.response.send_message(f"Host: `{ipaddr()}`\nPort: `{vm['port']}`\nUser: `ubuntu`\nPassword: `{vm['password']}`",ephemeral=True)
    @discord.ui.button(label="SSHX Web Terminal",style=discord.ButtonStyle.primary,row=2)
    async def sshx(self,i,b):
        vm=await self.auth(i)
        if not vm:return
        await i.response.defer(ephemeral=True,thinking=True)
        try:
            async with await ssh_conn(vm) as s:
                await s.run('mkdir -p "$HOME/.velocloud"; nohup sh -c \'curl -sSf https://sshx.io/get | sh -s run\' > "$HOME/.velocloud/sshx.log" 2>&1 < /dev/null & echo $! > "$HOME/.velocloud/sshx.pid"',check=True,timeout=20)
                link=None
                for _ in range(30):
                    await asyncio.sleep(2)
                    r=await s.run('grep -Eo "https://[^[:space:]]+" "$HOME/.velocloud/sshx.log" | tail -1 || true',timeout=10)
                    candidate=r.stdout.strip().strip("\"'(),")
                    if candidate.startswith("https://"): link=candidate; break
                if link:
                    await i.followup.send("🔐 **Private SSHX terminal**\n"+link+"\nKeep this link secret. Anyone with the active link may access the terminal.",ephemeral=True)
                    audit(i.user.id,self.vid,"sshx_started")
                else:
                    r=await s.run('tail -25 "$HOME/.velocloud/sshx.log" || true')
                    await i.followup.send("SSHX did not return a link. Output:\n```text\n"+r.stdout[-1000:]+"```",ephemeral=True)
        except Exception as e: await i.followup.send("SSHX failed: "+str(e)[:800],ephemeral=True)
    @discord.ui.button(label="Stop SSHX",style=discord.ButtonStyle.secondary,row=2)
    async def stopsshx(self,i,b):
        vm=await self.auth(i)
        if not vm:return
        await i.response.defer(ephemeral=True)
        try:
            async with await ssh_conn(vm) as s:
                await s.run('test -f "$HOME/.velocloud/sshx.pid" && kill "$(cat "$HOME/.velocloud/sshx.pid")" 2>/dev/null || true; rm -f "$HOME/.velocloud/sshx.pid"',timeout=10)
            await i.followup.send("SSHX stop request sent.",ephemeral=True)
        except Exception as e: await i.followup.send(str(e)[:700],ephemeral=True)
    @discord.ui.button(label="Change Password",style=discord.ButtonStyle.secondary,row=3)
    async def password(self,i,b):
        vm=await self.auth(i)
        if not vm:return
        new=pwgen(); await i.response.defer(ephemeral=True)
        try:
            async with await ssh_conn(vm) as s: await s.run("echo "+json.dumps("ubuntu:"+new)+" | chpasswd",check=True,timeout=15)
            with db() as c: c.execute("UPDATE vps SET password=? WHERE id=?",(new,self.vid))
            await i.followup.send("Password changed. New password: `"+new+"`",ephemeral=True)
        except Exception as e: await i.followup.send("Password change failed: "+str(e)[:700],ephemeral=True)
    @discord.ui.button(label="Reinstall Ubuntu",style=discord.ButtonStyle.danger,row=3)
    async def reinstall(self,i,b):
        vm=await self.auth(i)
        if vm: await i.response.send_message("WARNING: Reinstall erases the guest's current files. Continue?",view=Confirm(vm["owner"],self.vid,"reinstall"),ephemeral=True)
    @discord.ui.button(label="Delete VPS",style=discord.ButtonStyle.danger,row=4)
    async def delete(self,i,b):
        vm=await self.auth(i)
        if vm: await i.response.send_message("WARNING: This permanently deletes the VM and its virtual disk. Continue?",view=Confirm(vm["owner"],self.vid,"delete"),ephemeral=True)

@bot.event
async def on_ready():
    bot.add_view(DeployView())
    print(f"{BOT_NAME} online as {bot.user}")

@bot.command(name="panel")
async def panel(ctx):
    e=discord.Embed(title="☁ VELOCLOUD | VPS DEPLOYMENT",description="Deploy a real Ubuntu 24.04 QEMU/KVM virtual machine.\n\n**STARTER**\n1 vCPU • 1 GB RAM • 10 GB Disk\n\n**PRO**\n2 vCPU • 2 GB RAM • 10 GB Disk\n\nYour VPS is marked Ready only after SSH verification.",color=discord.Color.blurple())
    await ctx.send(embed=e,view=DeployView())

@bot.command(name="myvps")
async def myvps(ctx):
    rows=user_vms(ctx.author.id)
    if not rows: await ctx.reply("No VPS found. Use `!panel`."); return
    for vm in rows:
        e=discord.Embed(title="VELOCLOUD VPS | "+vm["id"],color=discord.Color.blurple())
        e.add_field(name="Hostname",value=vm["hostname"]); e.add_field(name="Status",value=vm["status"])
        e.add_field(name="Plan",value=f'{vm["cpu"]} CPU / {vm["ram"]} MB RAM / {vm["disk"]} GB')
        await ctx.send(embed=e,view=Manage(vm["id"]))

@bot.command(name="manage")
async def manage(ctx,vid:str):
    vm=get_vm(vid)
    if not vm or ctx.author.id not in (vm["owner"],OWNER): await ctx.reply("VPS not found or not authorized."); return
    await ctx.send("VELOCLOUD Management | "+vid,view=Manage(vid))

@bot.command(name="status")
async def status(ctx):
    with db() as c:
        total=c.execute("SELECT COUNT(*) FROM vps").fetchone()[0]
        running=c.execute("SELECT COUNT(*) FROM vps WHERE status='running'").fetchone()[0]
    e=discord.Embed(title="VELOCLOUD Platform Status",color=discord.Color.green())
    e.add_field(name="Registered VPS",value=str(total)); e.add_field(name="SSH-verified VPS",value=str(running))
    e.add_field(name="Deployments",value=setting("deploy_enabled","1")); e.add_field(name="Maintenance",value=setting("maintenance","0"))
    await ctx.reply(embed=e)

def owner_check(ctx): return ctx.author.id==OWNER
@bot.command(name="deployswitch")
@commands.check(owner_check)
async def deployswitch(ctx,state:str):
    if state.lower() not in ("on","off"): await ctx.reply("Use `!deployswitch on/off`."); return
    set_setting("deploy_enabled","1" if state.lower()=="on" else "0"); await ctx.reply("Deployments: "+state.upper())
@bot.command(name="maintenance")
@commands.check(owner_check)
async def maintenance(ctx,state:str):
    if state.lower() not in ("on","off"): await ctx.reply("Use `!maintenance on/off`."); return
    set_setting("maintenance","1" if state.lower()=="on" else "0"); await ctx.reply("Maintenance: "+state.upper())
@bot.command(name="capacity")
@commands.check(owner_check)
async def capacity(ctx,n:int):
    global MAX_TOTAL
    if not 1<=n<=500: await ctx.reply("Choose 1 to 500."); return
    MAX_TOTAL=n
    with db() as c: c.execute("INSERT INTO settings VALUES('max_total',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",(str(n),))
    await ctx.reply(f"Maximum VPS count set to {n}.")
@bot.command(name="announce")
@commands.check(owner_check)
async def announce(ctx,channel:discord.TextChannel,*,message:str):
    e=discord.Embed(title="📢 VELOCLOUD Announcement",description=message,color=discord.Color.orange())
    await channel.send(embed=e); await ctx.reply("Announcement published.")
@bot.command(name="admininfo")
@commands.check(owner_check)
async def admininfo(ctx):
    cpu=run(["nproc"]).stdout.strip(); mem=run(["free","-h"]).stdout[-800:]; disk=run(["df","-h",str(DATA)]).stdout[-500:]
    await ctx.reply(f"**CPU threads:** {cpu}\n**KVM:** {'Available' if Path('/dev/kvm').exists() else 'Unavailable'}\n```text\n{mem}\n{disk}\n```")
@bot.command(name="logs")
@commands.check(owner_check)
async def logs(ctx,vid:str):
    if not re.fullmatch(r"[a-f0-9]{8}",vid): await ctx.reply("Invalid VPS ID."); return
    p=run(["journalctl","-u",unit(vid),"-n","35","--no-pager"])
    await ctx.reply("```text\n"+(p.stdout or p.stderr or "No logs.")[-1700:]+"\n```")
@bot.command(name="backup")
@commands.check(owner_check)
async def backup(ctx,vid:str):
    vm=get_vm(vid)
    if not vm: await ctx.reply("VPS not found."); return
    if systemctl("is-active",unit(vid)).stdout.strip()=="active": await ctx.reply("Stop the VPS first for a consistent backup."); return
    dest=BACKUPS/f"{vid}-{int(time.time())}.qcow2"
    try:
        await ctx.reply("Creating backup...")
        run(["qemu-img","convert","-p","-O","qcow2",str(vm_dir(vid)/"disk.qcow2"),str(dest)],1800,True)
        await ctx.send("Backup created: `"+dest.name+"`")
        audit(ctx.author.id,vid,"backup",dest.name)
    except Exception as e: await ctx.send("Backup failed: "+str(e)[:700])
@bot.command(name="helpvc")
async def helpvc(ctx):
    await ctx.reply("**VELOCLOUD Commands**\n`!panel` deploy panel\n`!myvps` list your VPS\n`!manage ID` manage VPS\n`!status` platform status\n`!helpvc` help\n\n**Owner only**\n`!deployswitch on/off`\n`!maintenance on/off`\n`!capacity NUMBER`\n`!announce #channel MESSAGE`\n`!admininfo`\n`!logs VPS_ID`\n`!backup VPS_ID` (VPS must be stopped)")

@bot.event
async def on_command_error(ctx,error):
    if isinstance(error,commands.CheckFailure): await ctx.reply("Owner permission required.")
    elif isinstance(error,(commands.MissingRequiredArgument,commands.BadArgument)): await ctx.reply("Invalid arguments. Use `!helpvc`.")
    else:
        print("Command error:",repr(error))
        try: await ctx.reply("Command failed: "+str(error)[:500])
        except Exception: pass

async def main():
    init()
    if not TOKEN or not OWNER: raise RuntimeError("BOT_TOKEN and OWNER_ID are required in .env")
    async with bot: await bot.start(TOKEN)
if __name__=="__main__": asyncio.run(main())
PY

chmod 0750 "$BOT"
log "Creating systemd service"
cat > "$SERVICE" <<EOF
[Unit]
Description=VELOCLOUD Discord QEMU/KVM VPS Bot
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
WorkingDirectory=$APP
ExecStart=$APP/venv/bin/python $BOT
Restart=always
RestartSec=8
Environment=PYTHONUNBUFFERED=1
User=root
Group=root
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=$APP $DATA /etc/systemd/system
[Install]
WantedBy=multi-user.target
EOF

log "Checking Python syntax and database"
"$APP/venv/bin/python" -m py_compile "$BOT"
"$APP/venv/bin/python" - <<'PY'
import sys
sys.path.insert(0,"/opt/velocloud")
import bot
bot.init()
print("Database initialized.")
PY

log "Starting VELOCLOUD"
systemctl daemon-reload
systemctl enable velocloud-bot
systemctl restart velocloud-bot
sleep 3
echo
echo "=================================================="
echo " VELOCLOUD INSTALLER FINISHED"
echo "=================================================="
echo "Bot status: systemctl status velocloud-bot --no-pager"
echo "Live logs:  journalctl -u velocloud-bot -f"
echo "Restart:    systemctl restart velocloud-bot"
echo "Discord:    !panel"
echo "Help:       !helpvc"
echo "VM data:    $VMS"
echo "Backups:    $BACKUPS"
echo
echo "IMPORTANT: Enable Message Content Intent in Discord Developer Portal."
echo "Allow inbound TCP $PORT_MIN-$PORT_MAX in your VPS provider firewall."
echo "Set PUBLIC_IP in $ENV if automatic public IP detection is incorrect."
echo "Real VM deployment requires /dev/kvm and sufficient host RAM/CPU."
echo "SSHX sessions are launched inside the selected guest and links are private."
echo "Test one VPS before opening deployment to other users."
echo "=================================================="
systemctl --no-pager --full status velocloud-bot || true
