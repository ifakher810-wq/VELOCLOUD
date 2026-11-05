#!/usr/bin/env bash
# ╔════════════════════════════════════════════════════════════╗
# ║ ArizNodesLabs • VPS Deployer Bot bundle — by Vasplayz90    ║
# ║ Creates bot.py + requirements.txt + .env + systemd service ║
# ║ Usage:  bash ariznodes-vps-bundle.sh [--install]           ║
# ╚════════════════════════════════════════════════════════════╝
set -e
DIR="$(pwd)"
echo "📦 Writing files into $DIR"

cat > bot.py <<'ARIZ_BOT_PY'
# ╔══════════════════════════════════════════════════════════════╗
# ║  ArizNodesLabs • VPS Deployer Bot  —  made by Vasplayz90     ║
# ║  LXC containers + Pinggy SSH tunnels + sshx web terminals    ║
# ╚══════════════════════════════════════════════════════════════╝
import os, re, sys, time, ast, random, string, base64, hashlib, secrets, asyncio, sqlite3, uuid as uuidlib, operator as op, datetime as dt
from asyncio.subprocess import PIPE, STDOUT, DEVNULL
import discord, psutil
from discord.ext import commands
from dotenv import load_dotenv
try: import pyfiglet
except Exception: pyfiglet = None

load_dotenv()
def env(k, d=""): return os.getenv(k, d).strip()
TOKEN = env("DISCORD_TOKEN"); PREFIX = env("PREFIX", "!")
OWNERS = {int(x) for x in re.findall(r"\d+", env("OWNER_IDS"))}
MAX_VPS = int(env("MAX_VPS_PER_USER", "3")); MAX_RAM = int(env("MAX_RAM_MB", "8192"))
MAX_CPU = int(env("MAX_CPU", "4")); MAX_DISK = int(env("MAX_DISK_GB", "50"))
PINGGY_TOKEN = env("PINGGY_TOKEN"); LXC = env("LXC_BIN", "lxc")
FIRE, RED = 0xFF4500, 0xE74C3C
BRAND = "🔥 ArizNodesLabs • Vasplayz90"; START = time.time()

IMAGES = {  # key: (label, lxc image alias, emoji)  — edit freely
 "debian11": ("Debian 11 (Bullseye)", "images:debian/11", "🌀"),
 "debian12": ("Debian 12 (Bookworm)", "images:debian/12", "🌀"),
 "debian13": ("Debian 13 (Trixie)", "images:debian/13", "🌀"),
 "ubuntu2404": ("Ubuntu 24.04.5 LTS", "images:ubuntu/24.04", "🟠"),
 "ubuntu2204": ("Ubuntu 22.04.5 LTS", "images:ubuntu/22.04", "🟠"),
 "ubuntu2004": ("Ubuntu 20.04 LTS", "images:ubuntu/20.04", "🟠"),
 "alma9": ("AlmaLinux 9", "images:almalinux/9", "🦬"),
 "alma8": ("AlmaLinux 8", "images:almalinux/8", "🦬"),
 "rocky9": ("Rocky Linux 9", "images:rockylinux/9", "⛰️"),
 "centos9": ("CentOS 9 Stream", "images:centos/9-Stream", "💠"),
 "fedora": ("Fedora 42", "images:fedora/42", "🎩"),
 "alpine": ("Alpine Edge", "images:alpine/edge", "🏔️"),
 "arch": ("Arch Linux", "images:archlinux", "🏹"),
 "kali": ("Kali Linux", "images:kali", "🐉"),
 "opensuse": ("openSUSE Tumbleweed", "images:opensuse/tumbleweed", "🦎"),
}
_P = {"starter": (1024, 1, 10), "basic": (2048, 1, 20), "standard": (4096, 2, 30), "pro": (8192, 4, 50)}
PLANS = {k: v for k, v in _P.items() if v[0] <= MAX_RAM and v[1] <= MAX_CPU and v[2] <= MAX_DISK} or {"starter": _P["starter"]}
DEF_PLAN = next(iter(PLANS))

# ───────────────────────── database ─────────────────────────
db = sqlite3.connect("vps.db", check_same_thread=False); db.row_factory = sqlite3.Row
db.executescript("""
CREATE TABLE IF NOT EXISTS vps(name TEXT PRIMARY KEY, owner INTEGER, os TEXT, ram INTEGER, cpu INTEGER, disk INTEGER,
  created INTEGER, suspended INTEGER DEFAULT 0, ssh TEXT DEFAULT '', sshx TEXT DEFAULT '');
CREATE TABLE IF NOT EXISTS users(id INTEGER PRIMARY KEY, banned INTEGER DEFAULT 0, max_vps INTEGER);
CREATE TABLE IF NOT EXISTS admins(id INTEGER PRIMARY KEY);
CREATE TABLE IF NOT EXISTS warns(id INTEGER PRIMARY KEY AUTOINCREMENT, guild INTEGER, uid INTEGER, reason TEXT, ts INTEGER);
CREATE TABLE IF NOT EXISTS audit(id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER, uid INTEGER, action TEXT, detail TEXT);
CREATE TABLE IF NOT EXISTS settings(k TEXT PRIMARY KEY, v TEXT);
""")
def q(sql, a=(), one=False):
    cur = db.execute(sql, a); r = cur.fetchone() if one else cur.fetchall(); db.commit(); return r
def gset(k, d=""): r = q("SELECT v FROM settings WHERE k=?", (k,), True); return r["v"] if r else d
def sset(k, v): q("INSERT OR REPLACE INTO settings VALUES(?,?)", (k, str(v)))
def urow(uid): q("INSERT OR IGNORE INTO users(id) VALUES(?)", (uid,)); return q("SELECT * FROM users WHERE id=?", (uid,), True)
def is_admin(uid): return uid in OWNERS or bool(q("SELECT 1 FROM admins WHERE id=?", (uid,), True))
def ulimit(uid): m = urow(uid)["max_vps"]; return m if m is not None else MAX_VPS

# ───────────────────────── helpers ─────────────────────────
def emb(title=None, desc=None, color=FIRE):
    e = discord.Embed(title=title, description=desc, color=color, timestamp=dt.datetime.now(dt.timezone.utc))
    e.set_footer(text=BRAND); return e
def err(m): return emb("❌ Error", m, RED)
def trim(s, n=1800): s = s or ""; return s if len(s) <= n else s[:n] + "\n…"
def clean(s): return re.sub(r"\x1b\[[0-9;?]*[A-Za-z]|\r", "", s or "")
def bar(p, n=12): f = int(max(0, min(100, p)) / 100 * n); return "█" * f + "░" * (n - f) + f" {p:.0f}%"
def rpass(n=14): a = string.ascii_letters + string.digits; return "".join(secrets.choice(a) for _ in range(n))
def upt(s): d, r = divmod(int(s), 86400); h, r = divmod(r, 3600); m, s = divmod(r, 60); return f"{d}d {h}h {m}m {s}s"
def art(t, font="small"):
    try: return pyfiglet.figlet_format(t, font=font).rstrip()
    except Exception: return t
def audit(uid, action, detail=""):
    q("INSERT INTO audit(ts,uid,action,detail) VALUES(?,?,?,?)", (int(time.time()), uid, action, detail[:300]))
    ch = gset("logch")
    if ch:
        async def _s():
            c = bot.get_channel(int(ch))
            if c: await c.send(embed=emb("📜 Audit Log", f"<@{uid}> • **{action}**\n{detail[:300]}"))
        try: asyncio.get_running_loop().create_task(_s())
        except RuntimeError: pass

async def sh(*a, timeout=120):
    try:
        p = await asyncio.create_subprocess_exec(*a, stdout=PIPE, stderr=STDOUT, stdin=DEVNULL)
        out, _ = await asyncio.wait_for(p.communicate(), timeout)
        return p.returncode, clean(out.decode(errors="ignore")).strip()
    except asyncio.TimeoutError:
        try: p.kill()
        except Exception: pass
        return 124, "Timed out"
    except FileNotFoundError: return 127, f"`{a[0]}` not found on host"
async def lx(*a, timeout=120): return await sh(LXC, *a, timeout=timeout)
async def inside(c, script, timeout=300, envs=None):
    a = ["exec", c]
    for k, v in {"DEBIAN_FRONTEND": "noninteractive", **(envs or {})}.items(): a += ["--env", f"{k}={v}"]
    return await lx(*a, "--", "sh", "-c", script, timeout=timeout)
async def lxstate(c):
    rc, o = await lx("list", f"^{c}$", "-c", "s", "--format", "csv")
    return o.splitlines()[0].upper() if rc == 0 and o.strip() else "MISSING"
async def lxip(c):
    rc, o = await lx("list", f"^{c}$", "-c", "4", "--format", "csv")
    m = re.search(r"\d+\.\d+\.\d+\.\d+", o); return m.group(0) if m else None
def pm(pk):
    return ("if command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y {p}; "
            "elif command -v dnf >/dev/null 2>&1; then dnf install -y {p}; elif command -v apk >/dev/null 2>&1; then apk add --no-cache {p}; "
            "elif command -v pacman >/dev/null 2>&1; then pacman -Sy --noconfirm {p}; "
            "elif command -v zypper >/dev/null 2>&1; then zypper -n install {p}; fi").format(p=pk)
SETUP = r'''
if command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y openssh-server curl ca-certificates sudo nano;
elif command -v dnf >/dev/null 2>&1; then dnf install -y openssh-server curl ca-certificates sudo nano;
elif command -v apk >/dev/null 2>&1; then apk add --no-cache openssh curl ca-certificates sudo nano bash;
elif command -v pacman >/dev/null 2>&1; then pacman -Sy --noconfirm openssh curl sudo nano;
elif command -v zypper >/dev/null 2>&1; then zypper -n install openssh curl sudo nano; fi
mkdir -p /run/sshd /var/run/sshd; ssh-keygen -A >/dev/null 2>&1
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/;s/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
grep -q '^PermitRootLogin' /etc/ssh/sshd_config || echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
grep -q '^PasswordAuthentication' /etc/ssh/sshd_config || echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config
(systemctl enable --now ssh || systemctl enable --now sshd || (rc-update add sshd default && rc-service sshd start) || /usr/sbin/sshd) >/dev/null 2>&1
echo "root:$PW" | chpasswd
'''

# ───────────────────────── tunnels (pinggy + sshx) ─────────────────────────
TUN = {}
async def stop_tunnel(c):
    t = TUN.pop(c, None)
    if t:
        try: t["proc"].kill()
        except Exception: pass
    q("UPDATE vps SET ssh='' WHERE name=?", (c,))
async def start_tunnel(c):
    await stop_tunnel(c)
    ip = await lxip(c)
    if not ip: return None, "VPS has no IPv4 yet — is it running?"
    user, host = (f"{PINGGY_TOKEN}+tcp", "pro.pinggy.io") if PINGGY_TOKEN else ("tcp", "a.pinggy.io")
    try:
        p = await asyncio.create_subprocess_exec("ssh", "-p", "443", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
            "-o", "ServerAliveInterval=30", "-o", "ExitOnForwardFailure=yes", "-R", f"0:{ip}:22", f"{user}@{host}", stdin=PIPE, stdout=PIPE, stderr=STDOUT)
    except FileNotFoundError: return None, "`ssh` client missing on host (apt install openssh-client)"
    async def find():
        while True:
            l = await p.stdout.readline()
            if not l: return None
            m = re.search(r"tcp://([\w.\-]+):(\d+)", clean(l.decode(errors="ignore")))
            if m: return f"{m.group(1)}:{m.group(2)}"
    try: addr = await asyncio.wait_for(find(), 45)
    except asyncio.TimeoutError: addr = None
    if not addr:
        try: p.kill()
        except Exception: pass
        return None, "Pinggy did not return a TCP link (timeout / no outbound SSH on port 443?)"
    async def drain():
        try:
            while await p.stdout.readline(): pass
        finally:
            if TUN.get(c, {}).get("proc") is p: TUN.pop(c, None); q("UPDATE vps SET ssh='' WHERE name=?", (c,))
    TUN[c] = {"proc": p, "addr": addr, "task": asyncio.create_task(drain())}
    q("UPDATE vps SET ssh=? WHERE name=?", (addr, c)); return addr, None
async def start_sshx(c):
    if await lxstate(c) != "RUNNING": return None, "VPS is not running"
    await inside(c, "command -v curl >/dev/null 2>&1 || (" + pm("curl ca-certificates") + ")", 300)
    rc, o = await inside(c, "pkill -x sshx 2>/dev/null; rm -f /root/.sshx.log; (setsid nohup sh -c 'curl -sSf https://sshx.io/get | sh -s run' >/root/.sshx.log 2>&1 </dev/null &); sleep 14; cat /root/.sshx.log", 90)
    m = re.search(r"https://sshx\.io/s/[\w\-/#.]+", o)
    if not m: return None, "sshx did not return a link:\n" + trim(o, 400)
    q("UPDATE vps SET sshx=? WHERE name=?", (m.group(0), c)); return m.group(0), None
async def stop_sshx(c):
    await inside(c, "pkill -x sshx 2>/dev/null; true", 20); q("UPDATE vps SET sshx='' WHERE name=?", (c,))

# ───────────────────────── VPS core ─────────────────────────
def find(ref):
    ref = (ref or "").lower().strip()
    for n in (ref, "ariz-" + ref):
        r = q("SELECT * FROM vps WHERE name=?", (n,), True)
        if r: return r
def guard(r, uid, active=True):
    if r["owner"] != uid and not is_admin(uid): return "That VPS is not yours."
    if active and r["suspended"] and not is_admin(uid): return "⛔ This VPS is suspended. Contact an admin."
async def do_act(act, r):
    c = r["name"]
    if act in ("start", "resume"): rc, o = await lx("start", c)
    elif act == "stop":
        await stop_tunnel(c); rc, o = await lx("stop", c, "--timeout", "30")
        if rc != 0: rc, o = await lx("stop", c, "--force")
    elif act == "kill": await stop_tunnel(c); rc, o = await lx("stop", c, "--force")
    elif act == "restart": rc, o = await lx("restart", c, "--timeout", "30")
    elif act == "pause": rc, o = await lx("pause", c)
    elif act == "delete":
        await stop_tunnel(c); rc, o = await lx("delete", c, "--force", timeout=180)
        if rc == 0 or "not found" in o.lower(): q("DELETE FROM vps WHERE name=?", (c,)); rc = 0
    else: return False, "unknown action"
    audit(r["owner"], act, c); return rc == 0, o or "Done."
async def provision(c, alias, ram, cpu, disk, say=None):
    async def S(n, t):
        if say: await say(n, t)
    await S(1, "Creating LXC container")
    base = ["launch", alias, c, "-c", f"limits.memory={ram}MiB", "-c", f"limits.cpu={cpu}", "-c", "security.nesting=true"]
    rc, o = await lx(*base, "-d", f"root,size={disk}GiB", timeout=900)
    if rc != 0: await lx("delete", "-f", c); rc, o = await lx(*base, timeout=900)
    if rc != 0: await lx("delete", "-f", c); return None, "LXC launch failed:\n" + trim(o, 600)
    await S(2, "Waiting for network")
    for _ in range(30):
        if await lxip(c): break
        await asyncio.sleep(2)
    await asyncio.sleep(3); await S(3, "Installing & configuring SSH")
    pw = rpass(); rc, o = await inside(c, SETUP, 600, {"PW": pw})
    if rc != 0: await lx("delete", "-f", c); return None, "SSH setup failed:\n" + trim(o, 600)
    return pw, None
async def deploy_vps(uid, osk, plan, prog=None):
    if osk not in IMAGES: return None, "Unknown OS. See `%simages`." % PREFIX
    if plan not in PLANS: return None, "Unknown plan. See `%splans`." % PREFIX
    if urow(uid)["banned"]: return None, "You are banned."
    if gset("maint") == "1" and not is_admin(uid): return None, "🛠️ Maintenance mode is on."
    n = q("SELECT COUNT(*) c FROM vps WHERE owner=?", (uid,), True)["c"]
    if n >= ulimit(uid) and not is_admin(uid): return None, f"VPS limit reached ({n}/{ulimit(uid)})."
    ram, cpu, disk = PLANS[plan]; c = "ariz-" + "".join(random.choices(string.ascii_lowercase + string.digits, k=6))
    pw, e = await provision(c, IMAGES[osk][1], ram, cpu, disk, prog)
    if e: return None, e
    q("INSERT INTO vps(name,owner,os,ram,cpu,disk,created) VALUES(?,?,?,?,?,?,?)", (c, uid, osk, ram, cpu, disk, int(time.time())))
    if prog: await prog(4, "Opening Pinggy SSH tunnel")
    addr, te = await start_tunnel(c)
    if prog: await prog(5, "Finalizing")
    audit(uid, "deploy", f"{c} {osk} {plan}")
    return {"name": c, "os": osk, "pw": pw, "ssh": addr, "tunnel_err": te, "ram": ram, "cpu": cpu, "disk": disk}, None
def progress_embed(n, t):
    return emb("🚀 Deploying your VPS", f"`{'█' * n}{'░' * (5 - n)}` **{n}/5**\n⚙️ {t}…\n\n*This can take 1–3 minutes.*")
def ssh_line(addr): h, p = addr.rsplit(":", 1); return f"ssh root@{h} -p {p}"
def cred_embed(res):
    e = emb("🔥 VPS Credentials", f"**{IMAGES[res['os']][0]}** • `{res['name']}`", 0x2ECC71)
    e.add_field(name="🔑 Username / Password", value=f"`root` / `{res['pw']}`", inline=False)
    e.add_field(name="🔌 SSH (Pinggy IPv4)", value=f"```{ssh_line(res['ssh'])}```" if res["ssh"] else f"⚠️ {res['tunnel_err']}\nUse **New SSH** in `{PREFIX}manage`.", inline=False)
    e.add_field(name="📦 Resources", value=f"{res['ram']}MB RAM • {res['cpu']} vCPU • {res['disk']}GB disk"); e.add_field(name="⏳ Note", value="Free Pinggy links last ~60 min. Hit **New SSH** to renew.")
    return e
async def vps_embed(r):
    c = r["name"]; st = await lxstate(c); ip = await lxip(c) if st == "RUNNING" else None
    e = emb(f"🖥️ {c}", {"RUNNING": "🟢", "STOPPED": "🔴", "FROZEN": "🧊"}.get(st, "⚪") + f" **{st}**" + ("  •  ⛔ **SUSPENDED**" if r["suspended"] else ""))
    e.add_field(name="💿 OS", value=IMAGES.get(r["os"], (r["os"],))[0]); e.add_field(name="📦 Specs", value=f"{r['ram']}MB • {r['cpu']} vCPU • {r['disk']}GB")
    e.add_field(name="🌐 Internal IP", value=f"`{ip or 'n/a'}`"); e.add_field(name="👤 Owner", value=f"<@{r['owner']}>"); e.add_field(name="📅 Created", value=f"<t:{r['created']}:R>")
    e.add_field(name="🔌 Pinggy SSH", value=f"`{ssh_line(r['ssh'])}`" if r["ssh"] else "not active", inline=False)
    e.add_field(name="🌍 sshx", value=r["sshx"] or "not active", inline=False); return e
def deploy_intro():
    return emb("🚀 Deploy a VPS", "Pick an **OS** and a **plan**, then hit **Deploy**.\n\n" + "\n".join(f"{'**%s**' % k}: {v[0]}MB • {v[1]}vCPU • {v[2]}GB" for k, v in PLANS.items()))
def manage_embed(uid):
    n = q("SELECT COUNT(*) c FROM vps WHERE owner=?", (uid,), True)["c"]
    return emb("🎛️ VPS Manager", f"You own **{n}/{ulimit(uid)}** VPS.\nSelect one below to start / stop / restart, open SSH (Pinggy), sshx, snapshots and more.")

# ───────────────────────── UI ─────────────────────────
class OV(discord.ui.View):
    def __init__(s, uid, timeout=900): super().__init__(timeout=timeout); s.uid = uid
    async def interaction_check(s, i):
        if i.user.id == s.uid or is_admin(i.user.id): return True
        await i.response.send_message("🔒 This panel isn't yours — run it yourself.", ephemeral=True); return False

class ConfirmView(OV):
    def __init__(s, uid, fn, label="Confirm"): super().__init__(uid, 120); s.fn = fn; s.b_ok.label = label
    @discord.ui.button(label="Confirm", emoji="✅", style=discord.ButtonStyle.danger)
    async def b_ok(s, i, b):
        await i.response.edit_message(embed=emb("⏳ Working…"), view=None); ok, m = await s.fn()
        await i.edit_original_response(embed=emb("✅ Done" if ok else "❌ Failed", f"```{trim(m, 800)}```" if m else None, 0x2ECC71 if ok else RED))
    @discord.ui.button(label="Cancel", emoji="✖️", style=discord.ButtonStyle.secondary)
    async def b_no(s, i, b): await i.response.edit_message(embed=emb("Cancelled"), view=None)

class DeployView(OV):
    def __init__(s, uid):
        super().__init__(uid); s.os = "debian12"; s.plan = DEF_PLAN
        a = discord.ui.Select(placeholder="🐧 Choose operating system", options=[discord.SelectOption(label=v[0], value=k, emoji=v[2], default=(k == "debian12")) for k, v in IMAGES.items()])
        b = discord.ui.Select(placeholder="📦 Choose plan", row=1, options=[discord.SelectOption(label=k.title(), value=k, description=f"{v[0]}MB • {v[1]}vCPU • {v[2]}GB", default=(k == DEF_PLAN)) for k, v in PLANS.items()])
        async def ca(i): s.os = a.values[0]; await i.response.defer()
        async def cb(i): s.plan = b.values[0]; await i.response.defer()
        a.callback, b.callback = ca, cb; s.add_item(a); s.add_item(b)
    @discord.ui.button(label="Deploy", emoji="🚀", style=discord.ButtonStyle.success, row=2)
    async def go(s, i, b):
        await i.response.edit_message(embed=progress_embed(0, "Starting"), view=None)
        async def prog(n, t): await i.edit_original_response(embed=progress_embed(n, t))
        res, e = await deploy_vps(s.uid, s.os, s.plan, prog)
        if e: return await i.edit_original_response(embed=err(e))
        await i.edit_original_response(embed=emb("✅ VPS Deployed", f"`{res['name']}` is online!\nCredentials are in the private message below (and your DMs).\nControl it with `{PREFIX}manage`.", 0x2ECC71))
        ce = cred_embed(res); await i.followup.send(embed=ce, ephemeral=True)
        try: await i.user.send(embed=ce)
        except Exception: pass

class ManageView(OV):
    def __init__(s, uid):
        super().__init__(uid)
        rows = q("SELECT name,os FROM vps WHERE owner=? ORDER BY created DESC LIMIT 25", (uid,))
        if rows:
            sel = discord.ui.Select(placeholder="🖥️ Select a VPS to manage", options=[discord.SelectOption(label=r["name"], description=IMAGES.get(r["os"], (r["os"],))[0][:90], emoji="🖥️") for r in rows])
            async def cb(i):
                r = find(sel.values[0])
                if not r: return await i.response.send_message(embed=err("VPS not found."), ephemeral=True)
                await i.response.edit_message(embed=await vps_embed(r), view=VPSPanel(s.uid, r["name"]))
            sel.callback = cb; s.add_item(sel)
    @discord.ui.button(label="Deploy New VPS", emoji="🚀", style=discord.ButtonStyle.success, row=1)
    async def b_new(s, i, b): await i.response.edit_message(embed=deploy_intro(), view=DeployView(s.uid))

class VPSPanel(OV):
    def __init__(s, uid, c): super().__init__(uid); s.c = c
    async def pre(s, i, defer=True):
        r = find(s.c); g = guard(r, i.user.id) if r else "VPS no longer exists."
        if g: await i.response.send_message(embed=err(g), ephemeral=True); return None
        if defer: await i.response.defer()
        return r
    async def refresh(s, i):
        r = find(s.c)
        if r: await i.edit_original_response(embed=await vps_embed(r), view=s)
    async def act(s, i, act, label):
        r = await s.pre(i)
        if not r: return
        ok, o = await do_act(act, r)
        await i.followup.send(embed=emb(("✅ " if ok else "❌ ") + label, f"```{trim(o, 500)}```", 0x2ECC71 if ok else RED), ephemeral=True); await s.refresh(i)
    @discord.ui.button(label="Start", emoji="▶️", style=discord.ButtonStyle.success, row=0)
    async def b1(s, i, b): await s.act(i, "start", "Start")
    @discord.ui.button(label="Stop", emoji="⏹️", style=discord.ButtonStyle.danger, row=0)
    async def b2(s, i, b): await s.act(i, "stop", "Stop")
    @discord.ui.button(label="Restart", emoji="🔄", style=discord.ButtonStyle.primary, row=0)
    async def b3(s, i, b): await s.act(i, "restart", "Restart")
    @discord.ui.button(label="Refresh", emoji="♻️", style=discord.ButtonStyle.secondary, row=0)
    async def b4(s, i, b):
        if await s.pre(i): await s.refresh(i)
    @discord.ui.button(label="New SSH (Pinggy)", emoji="🔌", style=discord.ButtonStyle.primary, row=1)
    async def b5(s, i, b):
        r = await s.pre(i)
        if not r: return
        addr, e = await start_tunnel(r["name"])
        await i.followup.send(embed=err(e) if e else emb("🔌 Pinggy SSH Ready", f"```{ssh_line(addr)}```\nLogin: `root` + your password (use **Reset Pass** if lost).", 0x2ECC71), ephemeral=True); await s.refresh(i)
    @discord.ui.button(label="sshx Terminal", emoji="🌍", style=discord.ButtonStyle.primary, row=1)
    async def b6(s, i, b):
        r = await s.pre(i)
        if not r: return
        await i.followup.send(embed=emb("🌍 Starting sshx…", "Takes ~15 seconds."), ephemeral=True)
        url, e = await start_sshx(r["name"])
        await i.followup.send(embed=err(e) if e else emb("🌍 sshx Web Terminal", url, 0x2ECC71), ephemeral=True); await s.refresh(i)
    @discord.ui.button(label="Stop Tunnels", emoji="🛑", style=discord.ButtonStyle.secondary, row=1)
    async def b7(s, i, b):
        r = await s.pre(i)
        if not r: return
        await stop_tunnel(r["name"]); await stop_sshx(r["name"]); await s.refresh(i)
    @discord.ui.button(label="Snapshot", emoji="📸", style=discord.ButtonStyle.secondary, row=2)
    async def b8(s, i, b):
        r = await s.pre(i)
        if not r: return
        n = "snap-" + time.strftime("%m%d-%H%M%S"); rc, o = await lx("snapshot", r["name"], n, timeout=300)
        await i.followup.send(embed=emb("📸 Snapshot", f"`{n}` created" if rc == 0 else o, 0x2ECC71 if rc == 0 else RED), ephemeral=True)
    @discord.ui.button(label="Stats", emoji="📈", style=discord.ButtonStyle.secondary, row=2)
    async def b9(s, i, b):
        r = await s.pre(i)
        if not r: return
        rc, o = await lx("info", r["name"]); await i.followup.send(embed=emb("📈 Live Stats", f"```\n{trim(o, 1700)}\n```"), ephemeral=True)
    @discord.ui.button(label="Reset Pass", emoji="🔐", style=discord.ButtonStyle.secondary, row=2)
    async def b10(s, i, b):
        r = await s.pre(i)
        if not r: return
        pw = rpass(); rc, o = await inside(r["name"], 'echo "root:$PW" | chpasswd', 30, {"PW": pw})
        await i.followup.send(embed=emb("🔐 New root password", f"`{pw}`", 0x2ECC71) if rc == 0 else err(o), ephemeral=True)
    @discord.ui.button(label="Delete", emoji="🗑️", style=discord.ButtonStyle.danger, row=3)
    async def b11(s, i, b):
        r = await s.pre(i, False)
        if not r: return
        async def fn(): return await do_act("delete", r)
        await i.response.send_message(embed=emb("⚠️ Delete VPS?", f"`{r['name']}` and all its data will be destroyed.", RED), view=ConfirmView(i.user.id, fn, "Delete forever"), ephemeral=True)
    @discord.ui.button(label="Back", emoji="⬅️", style=discord.ButtonStyle.secondary, row=3)
    async def b12(s, i, b): await i.response.edit_message(embed=manage_embed(s.uid), view=ManageView(s.uid))

async def dash_embed():
    vm, du = psutil.virtual_memory(), psutil.disk_usage("/")
    rc, o = await lx("list", "-c", "ns", "--format", "csv"); live = dict(l.split(",", 1) for l in o.splitlines() if "," in l) if rc == 0 else {}
    rows = q("SELECT name,suspended FROM vps"); run = sum(1 for r in rows if live.get(r["name"], "").upper() == "RUNNING")
    e = emb("📊 ArizNodes Dashboard", f"Maintenance: **{'ON 🛠️' if gset('maint') == '1' else 'OFF'}**  •  Uptime `{upt(time.time() - START)}`", FIRE)
    e.add_field(name="🧠 CPU", value=f"`{bar(psutil.cpu_percent())}`", inline=False); e.add_field(name="💾 RAM", value=f"`{bar(vm.percent)}`", inline=False)
    e.add_field(name="💽 Disk", value=f"`{bar(du.percent)}`", inline=False)
    e.add_field(name="🖥️ VPS", value=f"{len(rows)} total\n{run} running"); e.add_field(name="⛔ Suspended", value=str(sum(r['suspended'] for r in rows)))
    e.add_field(name="🔌 Tunnels", value=str(len(TUN))); e.add_field(name="👥 Users", value=str(q("SELECT COUNT(DISTINCT owner) c FROM vps", one=True)["c"]))
    e.add_field(name="🏓 Latency", value=f"{bot.latency * 1000:.0f}ms"); return e
class DashView(OV):
    @discord.ui.button(label="Refresh", emoji="♻️", style=discord.ButtonStyle.primary)
    async def d1(s, i, b): await i.response.edit_message(embed=await dash_embed(), view=s)
    @discord.ui.button(label="All VPS", emoji="📋", style=discord.ButtonStyle.secondary)
    async def d2(s, i, b):
        rows = q("SELECT * FROM vps ORDER BY created DESC LIMIT 25"); await i.response.send_message(embed=emb("📋 Latest VPS", "\n".join(f"`{r['name']}` <@{r['owner']}> {'⛔' if r['suspended'] else ''}" for r in rows) or "none"), ephemeral=True)
    @discord.ui.button(label="Maintenance", emoji="🛠️", style=discord.ButtonStyle.secondary)
    async def d3(s, i, b): sset("maint", "0" if gset("maint") == "1" else "1"); await i.response.edit_message(embed=await dash_embed(), view=s)
    @discord.ui.button(label="Kill Tunnels", emoji="🛑", style=discord.ButtonStyle.danger)
    async def d4(s, i, b):
        for c in list(TUN): await stop_tunnel(c)
        await i.response.edit_message(embed=await dash_embed(), view=s)

TITLES = {"vps": "🖥️ VPS", "admin": "🛡️ Admin & Dashboard", "util": "🧰 Utility & Fun"}; CAT = {}
def help_home():
    e = emb("🔥 ArizNodesLabs VPS Deployer", f"Prefix `{PREFIX}` • **{len(CAT)} commands**\nPick a category below, or use `{PREFIX}help <command>`.\n\n```\n{art('ArizNodes')}\n```")
    for k, t in TITLES.items(): e.add_field(name=t, value=f"{sum(1 for c in CAT.values() if c == k)} commands")
    return e
def help_cat(k):
    names = sorted(n for n, c in CAT.items() if c == k); return emb(f"{TITLES[k]} — {len(names)} commands", " ".join(f"`{PREFIX}{n}`" for n in names))
class HelpView(OV):
    def __init__(s, uid):
        super().__init__(uid); sel = discord.ui.Select(placeholder="📚 Choose a category", options=[discord.SelectOption(label="Home", value="home", emoji="🏠")] + [discord.SelectOption(label=t[2:].strip(), value=k, emoji=t[0]) for k, t in TITLES.items()])
        async def cb(i): v = sel.values[0]; await i.response.edit_message(embed=help_home() if v == "home" else help_cat(v), view=s)
        sel.callback = cb; s.add_item(sel)
class PanelView(discord.ui.View):
    def __init__(s): super().__init__(timeout=None)
    @discord.ui.button(label="Deploy VPS", emoji="🚀", style=discord.ButtonStyle.success, custom_id="ariz:deploy")
    async def p1(s, i, b): await i.response.send_message(embed=deploy_intro(), view=DeployView(i.user.id), ephemeral=True)
    @discord.ui.button(label="My VPS", emoji="🖥️", style=discord.ButtonStyle.primary, custom_id="ariz:manage")
    async def p2(s, i, b): await i.response.send_message(embed=manage_embed(i.user.id), view=ManageView(i.user.id), ephemeral=True)
    @discord.ui.button(label="Dashboard", emoji="📊", style=discord.ButtonStyle.secondary, custom_id="ariz:dash")
    async def p3(s, i, b):
        if not is_admin(i.user.id): return await i.response.send_message(embed=err("Admins only."), ephemeral=True)
        await i.response.send_message(embed=await dash_embed(), view=DashView(i.user.id), ephemeral=True)
    @discord.ui.button(label="Help", emoji="❓", style=discord.ButtonStyle.secondary, custom_id="ariz:help")
    async def p4(s, i, b): await i.response.send_message(embed=help_home(), view=HelpView(i.user.id), ephemeral=True)

# ───────────────────────── bot + command registry ─────────────────────────
intents = discord.Intents.default(); intents.message_content = True
bot = commands.Bot(command_prefix=commands.when_mentioned_or(PREFIX), intents=intents, help_command=None, case_insensitive=True)
def chk_admin(ctx):
    if is_admin(ctx.author.id): return True
    raise commands.CheckFailure("🔒 Admins only.")
def chk_owner(ctx):
    if ctx.author.id in OWNERS: return True
    raise commands.CheckFailure("🔒 Bot owner only.")
def cmd(cat, brief="", level=0, name=None, **kw):
    def deco(f):
        c = commands.Command(f, name=name or f.__name__.rstrip("_"), brief=brief, **kw)
        if level == 1: c.add_check(chk_admin)
        if level == 2: c.add_check(chk_owner)
        bot.add_command(c); CAT[c.name] = cat; return f
    return deco
@bot.check
async def gate(ctx):
    if is_admin(ctx.author.id): return True
    if urow(ctx.author.id)["banned"]: raise commands.CheckFailure("🚫 You are banned from this bot.")
    if gset("maint") == "1" and CAT.get(ctx.command.name) == "vps": raise commands.CheckFailure("🛠️ Maintenance mode — VPS commands are temporarily disabled.")
    return True
@bot.event
async def on_command_error(ctx, e):
    e = getattr(e, "original", e)
    if isinstance(e, commands.CommandNotFound): return
    if isinstance(e, commands.CheckFailure): m = str(e) or "You can't use that."
    elif isinstance(e, commands.MissingRequiredArgument): m = f"Missing `{e.param.name}`.\nUsage: `{PREFIX}{ctx.command.name} {ctx.command.signature}`"
    elif isinstance(e, (commands.BadArgument, commands.BadUnionArgument)): m = f"Bad argument. Usage: `{PREFIX}{ctx.command.name} {ctx.command.signature}`"
    elif isinstance(e, discord.Forbidden): m = "I lack permission to do that."
    else: m = f"{type(e).__name__}: {e}"; print("ERR", ctx.command, repr(e))
    await ctx.send(embed=err(m))
async def mine(ctx, ref=None, active=True):
    if ref is None:
        rows = q("SELECT * FROM vps WHERE owner=?", (ctx.author.id,))
        if len(rows) != 1: await ctx.send(embed=err(f"Specify a VPS name — see `{PREFIX}myvps`.")); return None
        r = rows[0]
    else: r = find(ref)
    if not r: await ctx.send(embed=err(f"VPS not found. See `{PREFIX}myvps`.")); return None
    g = guard(r, ctx.author.id, active)
    if g: await ctx.send(embed=err(g)); return None
    return r
async def dm_or_here(ctx, e):
    try: await ctx.author.send(embed=e); return "📬 Details sent to your DMs."
    except discord.Forbidden: await ctx.send(embed=e, delete_after=120); return "⚠️ DMs closed — shown above for 2 min."

# ═════════════════════ CATEGORY 1 — VPS (50) ═════════════════════
@cmd("vps", "Deploy a VPS: !deploy [os] [plan]")
async def deploy(ctx, osk: str = None, plan: str = None):
    if not osk: return await ctx.send(embed=deploy_intro(), view=DeployView(ctx.author.id))
    m = await ctx.send(embed=progress_embed(0, "Starting"))
    async def prog(n, t): await m.edit(embed=progress_embed(n, t))
    res, e = await deploy_vps(ctx.author.id, osk.lower(), (plan or DEF_PLAN).lower(), prog)
    if e: return await m.edit(embed=err(e))
    note = await dm_or_here(ctx, cred_embed(res)); await m.edit(embed=emb("✅ VPS Deployed", f"`{res['name']}` is online!\n{note}\nControl it with `{PREFIX}manage`.", 0x2ECC71))
@cmd("vps", "Open the premium VPS manager")
async def manage(ctx): await ctx.send(embed=manage_embed(ctx.author.id), view=ManageView(ctx.author.id))
@cmd("vps", "List your VPS")
async def myvps(ctx):
    rows = q("SELECT * FROM vps WHERE owner=?", (ctx.author.id,)); lines = []
    for r in rows: lines.append(f"{'🟢' if await lxstate(r['name']) == 'RUNNING' else '🔴'} `{r['name']}` • {IMAGES.get(r['os'], (r['os'],))[0]} • {r['ram']}MB/{r['cpu']}c/{r['disk']}G")
    await ctx.send(embed=emb(f"🖥️ Your VPS ({len(rows)}/{ulimit(ctx.author.id)})", "\n".join(lines) or f"None yet — `{PREFIX}deploy`"))
@cmd("vps", "Detailed VPS info")
async def vpsinfo(ctx, name: str = None):
    r = await mine(ctx, name, False)
    if r: await ctx.send(embed=await vps_embed(r))
def mk_act(act, brief):
    async def f(ctx, name: str = None):
        r = await mine(ctx, name)
        if not r: return
        ok, o = await do_act(act, r); await ctx.send(embed=emb(("✅ " if ok else "❌ ") + act.title(), f"`{r['name']}` — {trim(o, 400)}", 0x2ECC71 if ok else RED))
    f.__name__ = act; cmd("vps", brief)(f)
for _a, _b in [("start", "Start a VPS"), ("stop", "Stop a VPS"), ("restart", "Restart a VPS"), ("kill", "Force-stop a VPS"), ("pause", "Freeze a VPS"), ("resume", "Unfreeze a VPS")]: mk_act(_a, _b)
@cmd("vps", "Delete a VPS (confirm)")
async def delete(ctx, name: str = None):
    r = await mine(ctx, name, False)
    if not r: return
    async def fn(): return await do_act("delete", r)
    await ctx.send(embed=emb("⚠️ Delete VPS?", f"`{r['name']}` will be destroyed forever.", RED), view=ConfirmView(ctx.author.id, fn, "Delete forever"))
@cmd("vps", "Open a new Pinggy SSH link")
async def ssh(ctx, name: str = None):
    r = await mine(ctx, name)
    if not r: return
    m = await ctx.send(embed=emb("🔌 Opening Pinggy tunnel…")); addr, e = await start_tunnel(r["name"])
    if e: return await m.edit(embed=err(e))
    note = await dm_or_here(ctx, emb("🔌 Pinggy SSH Ready", f"`{r['name']}`\n```{ssh_line(addr)}```Login: `root` + password (`{PREFIX}resetpass` if lost).", 0x2ECC71)); await m.edit(embed=emb("✅ Tunnel ready", note, 0x2ECC71))
@cmd("vps", "Close the Pinggy tunnel")
async def sshstop(ctx, name: str = None):
    r = await mine(ctx, name)
    if r: await stop_tunnel(r["name"]); await ctx.send(embed=emb("🛑 Tunnel closed", r["name"]))
@cmd("vps", "Start an sshx web terminal link")
async def sshx(ctx, name: str = None):
    r = await mine(ctx, name)
    if not r: return
    m = await ctx.send(embed=emb("🌍 Starting sshx…", "~15 seconds")); url, e = await start_sshx(r["name"])
    if e: return await m.edit(embed=err(e))
    note = await dm_or_here(ctx, emb("🌍 sshx Terminal", url, 0x2ECC71)); await m.edit(embed=emb("✅ sshx ready", note, 0x2ECC71))
@cmd("vps", "Stop the sshx session")
async def sshxstop(ctx, name: str = None):
    r = await mine(ctx, name)
    if r: await stop_sshx(r["name"]); await ctx.send(embed=emb("🛑 sshx stopped", r["name"]))
@cmd("vps", "Reset the root password")
async def resetpass(ctx, name: str = None):
    r = await mine(ctx, name)
    if not r: return
    pw = rpass(); rc, o = await inside(r["name"], 'echo "root:$PW" | chpasswd', 30, {"PW": pw})
    await ctx.send(embed=err(o)) if rc else await ctx.send(embed=emb("🔐 Password reset", await dm_or_here(ctx, emb("🔐 New root password", f"`{r['name']}`: `{pw}`", 0x2ECC71)), 0x2ECC71))
@cmd("vps", "Rename a VPS: !rename old new")
async def rename(ctx, name: str, new: str):
    r = await mine(ctx, name)
    if not r: return
    new = "ariz-" + re.sub(r"[^a-z0-9-]", "", new.lower().removeprefix("ariz-"))[:20]
    if len(new) < 8 or find(new): return await ctx.send(embed=err("Invalid or taken name (3+ chars, a-z 0-9 -)."))
    await do_act("stop", r); rc, o = await lx("rename", r["name"], new)
    if rc: return await ctx.send(embed=err(o))
    q("UPDATE vps SET name=? WHERE name=?", (new, r["name"])); await lx("start", new); await ctx.send(embed=emb("✏️ Renamed", f"`{r['name']}` → `{new}`", 0x2ECC71))
@cmd("vps", "Create a snapshot: !snapshot [name] [label]")
async def snapshot(ctx, name: str = None, label: str = None):
    r = await mine(ctx, name)
    if not r: return
    label = re.sub(r"[^\w-]", "", label or "snap-" + time.strftime("%m%d-%H%M%S")); rc, o = await lx("snapshot", r["name"], label, timeout=300)
    await ctx.send(embed=emb("📸 Snapshot", f"`{label}` created" if rc == 0 else o, 0x2ECC71 if rc == 0 else RED))
async def snaps(c):
    rc, o = await lx("query", f"/1.0/instances/{c}/snapshots")
    try: import json; return [p.split("/")[-1] for p in json.loads(o)]
    except Exception: return []
@cmd("vps", "List snapshots")
async def snapshots(ctx, name: str = None):
    r = await mine(ctx, name, False)
    if r: s = await snaps(r["name"]); await ctx.send(embed=emb(f"📸 Snapshots • {r['name']}", "\n".join(f"`{x}`" for x in s) or "none"))
@cmd("vps", "Restore a snapshot: !restore name snap")
async def restore(ctx, name: str, snap: str):
    r = await mine(ctx, name)
    if r: rc, o = await lx("restore", r["name"], snap, timeout=300); await ctx.send(embed=emb("↩️ Restore", f"`{snap}` restored" if rc == 0 else o, 0x2ECC71 if rc == 0 else RED))
@cmd("vps", "Delete a snapshot: !delsnapshot name snap")
async def delsnapshot(ctx, name: str, snap: str):
    r = await mine(ctx, name)
    if r: rc, o = await lx("delete", f"{r['name']}/{snap}"); await ctx.send(embed=emb("🗑️ Snapshot", "deleted" if rc == 0 else o, 0x2ECC71 if rc == 0 else RED))
async def resize(ctx, name, val, lo, hi, key, unit):
    r = await mine(ctx, name)
    if not r: return
    if not lo <= val <= hi: return await ctx.send(embed=err(f"Allowed range: {lo}–{hi}{unit}."))
    if key == "disk":
        rc, o = await lx("config", "device", "set", r["name"], "root", f"size={val}GiB")
        if rc: rc, o = await lx("config", "device", "override", r["name"], "root", f"size={val}GiB")
    else: rc, o = await lx("config", "set", r["name"], "limits.memory" if key == "ram" else "limits.cpu", f"{val}MiB" if key == "ram" else str(val))
    if rc: return await ctx.send(embed=err(o))
    q(f"UPDATE vps SET {key}=? WHERE name=?", (val, r["name"])); await ctx.send(embed=emb("⚙️ Resized", f"`{r['name']}` {key.upper()} → **{val}{unit}**", 0x2ECC71))
@cmd("vps", "Set RAM (MB): !setram name mb")
async def setram(ctx, name: str, mb: int): await resize(ctx, name, mb, 256, MAX_RAM, "ram", "MB")
@cmd("vps", "Set vCPU: !setcpu name n")
async def setcpu(ctx, name: str, n: int): await resize(ctx, name, n, 1, MAX_CPU, "cpu", " vCPU")
@cmd("vps", "Set disk (GB): !setdisk name gb")
async def setdisk(ctx, name: str, gb: int): await resize(ctx, name, gb, 1, MAX_DISK, "disk", "GB")
@cmd("vps", "Reinstall with another OS: !reinstall name [os]")
async def reinstall(ctx, name: str, osk: str = None):
    r = await mine(ctx, name)
    if not r: return
    osk = (osk or r["os"]).lower()
    if osk not in IMAGES: return await ctx.send(embed=err("Unknown OS."))
    async def fn():
        await stop_tunnel(r["name"]); await lx("delete", "-f", r["name"], timeout=180)
        pw, e = await provision(r["name"], IMAGES[osk][1], r["ram"], r["cpu"], r["disk"])
        if e: q("DELETE FROM vps WHERE name=?", (r["name"],)); return False, e
        q("UPDATE vps SET os=?, ssh='', sshx='' WHERE name=?", (osk, r["name"])); await dm_or_here(ctx, emb("♻️ Reinstalled", f"`{r['name']}` root password: `{pw}`", 0x2ECC71)); return True, "Reinstalled. New password sent."
    await ctx.send(embed=emb("⚠️ Reinstall?", f"All data on `{r['name']}` will be wiped.", RED), view=ConfirmView(ctx.author.id, fn, "Reinstall"))
@cmd("vps", "List available operating systems")
async def images(ctx): await ctx.send(embed=emb("💿 Operating Systems", "\n".join(f"{v[2]} `{k}` — {v[0]}" for k, v in IMAGES.items()) + f"\n\nUse `{PREFIX}deploy <key> [plan]`"))
@cmd("vps", "List plans")
async def plans(ctx): await ctx.send(embed=emb("📦 Plans", "\n".join(f"**{k}** — {v[0]}MB RAM • {v[1]} vCPU • {v[2]}GB disk" for k, v in PLANS.items())))
@cmd("vps", "Run a command inside your VPS: !exec name <cmd>")
async def exec_(ctx, name: str, *, command: str):
    r = await mine(ctx, name)
    if not r: return
    if await lxstate(r["name"]) != "RUNNING": return await ctx.send(embed=err("VPS must be running."))
    rc, o = await inside(r["name"], command, 120); await ctx.send(embed=emb(f"💻 {r['name']} (exit {rc})", f"```\n{trim(o, 1800) or 'no output'}\n```"))
@cmd("vps", "Live resource stats")
async def stats(ctx, name: str = None):
    r = await mine(ctx, name, False)
    if r: rc, o = await lx("info", r["name"]); await ctx.send(embed=emb(f"📈 {r['name']}", f"```\n{trim(o, 1800)}\n```"))
def mk_quick(n, brief, script, to=60):
    async def f(ctx, name: str = None):
        r = await mine(ctx, name)
        if not r: return
        if await lxstate(r["name"]) != "RUNNING": return await ctx.send(embed=err("VPS must be running."))
        m = await ctx.send(embed=emb(f"⏳ {n}", "Running…")); rc, o = await inside(r["name"], script, to)
        await m.edit(embed=emb(f"{'✅' if rc == 0 else '⚠️'} {n} • {r['name']}", f"```\n{trim(o, 1800) or 'no output'}\n```"))
    f.__name__ = n; cmd("vps", brief)(f)
for _n, _b, _s, _t in [
 ("vuptime", "VPS uptime", "uptime -p 2>/dev/null || uptime", 30), ("vprocs", "Top processes by memory", "(ps aux --sort=-%mem 2>/dev/null || ps aux) | head -12", 30),
 ("vdisk", "Disk usage", "df -h /", 30), ("vmem", "Memory usage", "free -h", 30), ("vcpu", "CPU info", '(lscpu 2>/dev/null || (nproc; grep -m1 "model name" /proc/cpuinfo)) | head -15', 30),
 ("vos", "OS release", "head -6 /etc/os-release", 30), ("vkernel", "Kernel", "uname -a", 30), ("vnet", "Network interfaces", "ip -br a 2>/dev/null || ifconfig", 30),
 ("vports", "Listening ports", "ss -tulpn 2>/dev/null || netstat -tulpn", 30), ("vusers", "System users", "cut -d: -f1 /etc/passwd | tr '\\n' ' '", 30),
 ("vdate", "Date/time", "date", 30), ("vhost", "Hostname", "hostname", 30), ("vload", "Load average", "cat /proc/loadavg", 30), ("vtop", "top snapshot", "top -bn1 | head -15", 30),
 ("vupdate", "Refresh package lists", "if command -v apt-get >/dev/null; then apt-get update -y; elif command -v dnf >/dev/null; then dnf makecache; elif command -v apk >/dev/null; then apk update; elif command -v pacman >/dev/null; then pacman -Sy --noconfirm; fi", 300),
 ("vdocker", "Install Docker", "curl -fsSL https://get.docker.com | sh && docker --version", 900), ("vnode", "Install Node.js", pm("nodejs npm") + "; node -v", 600),
 ("vpython", "Install Python 3 + pip", pm("python3 python3-pip") + "; python3 --version", 600), ("vgit", "Install Git", pm("git") + "; git --version", 600),
 ("vtools", "Install curl/wget/git/nano/htop", pm("curl wget git nano htop"), 600), ("vneofetch", "System summary", "neofetch --stdout 2>/dev/null || cat /etc/os-release", 30)]: mk_quick(_n, _b, _s, _t)

# ═════════════════════ CATEGORY 2 — ADMIN & DASHBOARD (50) ═════════════════════
@cmd("admin", "Open the admin dashboard", 1)
async def dashboard(ctx): await ctx.send(embed=await dash_embed(), view=DashView(ctx.author.id))
@cmd("admin", "Post the public deploy panel", 1)
async def panel(ctx):
    e = emb("🔥 ArizNodesLabs — VPS Deployer", f"```\n{art('ArizNodes')}\n```\n🚀 **Deploy** • 🖥️ **Manage** • 🔌 **Pinggy SSH** • 🌍 **sshx**\nPremium LXC VPS in seconds — tap a button below.")
    await ctx.send(embed=e, view=PanelView())
@cmd("admin", "Host CPU/RAM/disk stats", 1)
async def hoststats(ctx):
    vm, du = psutil.virtual_memory(), psutil.disk_usage("/"); await ctx.send(embed=emb("🖥️ Host Stats", f"CPU `{bar(psutil.cpu_percent(1))}`\nRAM `{bar(vm.percent)}` {vm.used >> 20}/{vm.total >> 20}MB\nDisk `{bar(du.percent)}` {du.used >> 30}/{du.total >> 30}GB\nLoad `{os.getloadavg()}`"))
@cmd("admin", "List all VPS: !allvps [page]", 1)
async def allvps(ctx, page: int = 1):
    rows = q("SELECT * FROM vps ORDER BY created DESC LIMIT 15 OFFSET ?", ((max(page, 1) - 1) * 15,)); await ctx.send(embed=emb(f"📋 All VPS • page {page}", "\n".join(f"`{r['name']}` <@{r['owner']}> {r['ram']}MB {'⛔' if r['suspended'] else ''}" for r in rows) or "empty"))
@cmd("admin", "A user's VPS", 1)
async def uservps(ctx, user: discord.User):
    rows = q("SELECT * FROM vps WHERE owner=?", (user.id,)); await ctx.send(embed=emb(f"🖥️ {user}", "\n".join(f"`{r['name']}` {IMAGES.get(r['os'], (r['os'],))[0]}" for r in rows) or "none"))
@cmd("admin", "A user's profile", 1)
async def userstats(ctx, user: discord.User):
    u = urow(user.id); n = q("SELECT COUNT(*) c FROM vps WHERE owner=?", (user.id,), True)["c"]; w = q("SELECT COUNT(*) c FROM warns WHERE uid=?", (user.id,), True)["c"]
    await ctx.send(embed=emb(f"👤 {user}", f"VPS: **{n}/{ulimit(user.id)}**\nBanned: **{bool(u['banned'])}**\nWarnings: **{w}**\nAdmin: **{is_admin(user.id)}**"))
def mk_susp(n, v):
    async def f(ctx, name: str):
        r = find(name)
        if not r: return await ctx.send(embed=err("VPS not found."))
        q("UPDATE vps SET suspended=? WHERE name=?", (v, r["name"]))
        if v: await do_act("stop", r)
        audit(ctx.author.id, n, r["name"]); await ctx.send(embed=emb(f"✅ {n.title()}", f"`{r['name']}`", 0x2ECC71))
    f.__name__ = n; cmd("admin", f"{n.title()} a VPS", 1)(f)
mk_susp("suspend", 1); mk_susp("unsuspend", 0)
def mk_ban(n, v):
    async def f(ctx, user: discord.User):
        urow(user.id); q("UPDATE users SET banned=? WHERE id=?", (v, user.id)); audit(ctx.author.id, n, str(user.id)); await ctx.send(embed=emb(f"✅ {n.title()}ned" if v else "✅ Unbanned", f"{user.mention}", 0x2ECC71))
    f.__name__ = n; cmd("admin", f"{n.title()} a user from the bot", 1)(f)
mk_ban("ban", 1); mk_ban("unban", 0)
@cmd("admin", "Bot-banned users", 1)
async def banlist(ctx): await ctx.send(embed=emb("🚫 Banned", "\n".join(f"<@{r['id']}>" for r in q("SELECT id FROM users WHERE banned=1")) or "none"))
@cmd("admin", "Set a user's VPS limit", 1)
async def setlimit(ctx, user: discord.User, n: int): urow(user.id); q("UPDATE users SET max_vps=? WHERE id=?", (n, user.id)); await ctx.send(embed=emb("✅ Limit set", f"{user.mention} → **{n}**", 0x2ECC71))
@cmd("admin", "Add a bot admin", 2)
async def addadmin(ctx, user: discord.User): q("INSERT OR IGNORE INTO admins VALUES(?)", (user.id,)); await ctx.send(embed=emb("✅ Admin added", user.mention, 0x2ECC71))
@cmd("admin", "Remove a bot admin", 2)
async def removeadmin(ctx, user: discord.User): q("DELETE FROM admins WHERE id=?", (user.id,)); await ctx.send(embed=emb("✅ Admin removed", user.mention, 0x2ECC71))
@cmd("admin", "List bot admins", 1)
async def admins(ctx): await ctx.send(embed=emb("👑 Admins", "\n".join(f"<@{i}>" for i in OWNERS | {r['id'] for r in q("SELECT id FROM admins")})))
def mk_force(act):
    async def f(ctx, name: str):
        r = find(name)
        if not r: return await ctx.send(embed=err("VPS not found."))
        ok, o = await do_act(act, r); await ctx.send(embed=emb(("✅ " if ok else "❌ ") + "Force " + act, f"`{r['name']}` {trim(o, 300)}", 0x2ECC71 if ok else RED))
    n = "force" + {"stop": "stop", "start": "start", "delete": "delete"}[act]; f.__name__ = n; cmd("admin", f"Admin: {act} any VPS", 1)(f)
for _a in ("delete", "stop", "start"): mk_force(_a)
@cmd("admin", "DM every VPS owner", 1)
async def broadcast(ctx, *, msg: str):
    n = 0
    for r in q("SELECT DISTINCT owner FROM vps"):
        try: u = await bot.fetch_user(r["owner"]); await u.send(embed=emb("📢 Announcement", msg)); n += 1; await asyncio.sleep(1)
        except Exception: pass
    await ctx.send(embed=emb("📢 Broadcast sent", f"Delivered to **{n}** users.", 0x2ECC71))
@cmd("admin", "Announce in a channel", 1)
async def announce(ctx, ch: discord.TextChannel, *, msg: str): await ch.send(embed=emb("📢 Announcement", msg)); await ctx.message.add_reaction("✅")
@cmd("admin", "Set audit-log channel", 1)
async def setlog(ctx, ch: discord.TextChannel): sset("logch", ch.id); await ctx.send(embed=emb("✅ Log channel set", ch.mention, 0x2ECC71))
@cmd("admin", "Maintenance mode: !maintenance on|off", 1)
async def maintenance(ctx, mode: str = None):
    sset("maint", "1" if (mode or ("off" if gset("maint") == "1" else "on")).lower() == "on" else "0"); await ctx.send(embed=emb("🛠️ Maintenance", "ON" if gset("maint") == "1" else "OFF"))
@cmd("admin", "Reload .env limits", 2)
async def reloadcfg(ctx):
    global OWNERS, MAX_VPS
    load_dotenv(override=True); OWNERS = {int(x) for x in re.findall(r"\d+", env("OWNER_IDS"))}; MAX_VPS = int(env("MAX_VPS_PER_USER", "3")); await ctx.send(embed=emb("♻️ Config reloaded", None, 0x2ECC71))
@cmd("admin", "Restart the bot", 2)
async def restartbot(ctx): await ctx.send(embed=emb("🔄 Restarting…")); os.execv(sys.executable, [sys.executable] + sys.argv)
@cmd("admin", "Shut the bot down", 2)
async def shutdown(ctx): await ctx.send(embed=emb("🛑 Shutting down…")); await bot.close()
@cmd("admin", "Run a shell command on the HOST", 2)
async def hostexec(ctx, *, command: str): rc, o = await sh("bash", "-c", command, timeout=120); await ctx.send(embed=emb(f"🖥️ host (exit {rc})", f"```\n{trim(o, 1800) or 'no output'}\n```"))
@cmd("admin", "Delete messages", 1)
async def purge(ctx, n: int): d = await ctx.channel.purge(limit=max(1, min(n, 200)) + 1); await ctx.send(embed=emb("🧹 Purged", f"{len(d) - 1} messages"), delete_after=5)
@cmd("admin", "Kick a member", 1)
async def kick(ctx, m: discord.Member, *, reason: str = "-"): await m.kick(reason=reason); await ctx.send(embed=emb("👢 Kicked", f"{m} — {reason}"))
@cmd("admin", "Timeout a member: !timeout @u minutes", 1)
async def timeout(ctx, m: discord.Member, minutes: int = 10): await m.timeout(dt.timedelta(minutes=minutes)); await ctx.send(embed=emb("⏳ Timed out", f"{m.mention} for {minutes}m"))
def mk_lock(n, v):
    async def f(ctx):
        ow = ctx.channel.overwrites_for(ctx.guild.default_role); ow.send_messages = v; await ctx.channel.set_permissions(ctx.guild.default_role, overwrite=ow); await ctx.send(embed=emb("🔒 Channel locked" if v is False else "🔓 Channel unlocked"))
    f.__name__ = n; cmd("admin", f"{n.title()} this channel", 1)(f)
mk_lock("lock", False); mk_lock("unlock", None)
@cmd("admin", "Set slowmode seconds", 1)
async def slowmode(ctx, s: int = 0): await ctx.channel.edit(slowmode_delay=max(0, min(s, 21600))); await ctx.send(embed=emb("🐌 Slowmode", f"{s}s"))
@cmd("admin", "Change a member nickname", 1)
async def nick(ctx, m: discord.Member, *, nick: str = None): await m.edit(nick=nick); await ctx.send(embed=emb("✏️ Nickname", nick or "reset"))
@cmd("admin", "Give a role", 1)
async def addrole(ctx, m: discord.Member, role: discord.Role): await m.add_roles(role); await ctx.send(embed=emb("✅ Role added", f"{role.mention} → {m.mention}"))
@cmd("admin", "Remove a role", 1)
async def removerole(ctx, m: discord.Member, role: discord.Role): await m.remove_roles(role); await ctx.send(embed=emb("✅ Role removed", f"{role.mention} ← {m.mention}"))
@cmd("admin", "Warn a user", 1)
async def warn(ctx, m: discord.Member, *, reason: str = "-"): q("INSERT INTO warns(guild,uid,reason,ts) VALUES(?,?,?,?)", (ctx.guild.id, m.id, reason, int(time.time()))); await ctx.send(embed=emb("⚠️ Warned", f"{m.mention}: {reason}"))
@cmd("admin", "Show warnings", 1)
async def warnings(ctx, m: discord.Member): await ctx.send(embed=emb(f"⚠️ Warnings • {m}", "\n".join(f"<t:{r['ts']}:d> {r['reason']}" for r in q("SELECT * FROM warns WHERE uid=? AND guild=?", (m.id, ctx.guild.id))) or "none"))
@cmd("admin", "Clear warnings", 1)
async def clearwarns(ctx, m: discord.Member): q("DELETE FROM warns WHERE uid=? AND guild=?", (m.id, ctx.guild.id)); await ctx.send(embed=emb("✅ Cleared", m.mention, 0x2ECC71))
@cmd("admin", "Close every Pinggy tunnel", 1)
async def stopalltunnels(ctx):
    n = len(TUN)
    for c in list(TUN): await stop_tunnel(c)
    await ctx.send(embed=emb("🛑 Tunnels closed", str(n)))
@cmd("admin", "Remove DB rows of missing containers", 1)
async def cleanup(ctx):
    n = 0
    for r in q("SELECT name FROM vps"):
        if await lxstate(r["name"]) == "MISSING": q("DELETE FROM vps WHERE name=?", (r["name"],)); n += 1
    await ctx.send(embed=emb("🧹 Cleanup", f"Removed **{n}** orphan records.", 0x2ECC71))
@cmd("admin", "Send DB backup to your DMs", 2)
async def backupdb(ctx): await ctx.author.send(file=discord.File("vps.db")); await ctx.send(embed=emb("💾 Backup sent to DMs"))
@cmd("admin", "Database statistics", 1)
async def dbstats(ctx): await ctx.send(embed=emb("🗄️ Database", "\n".join(f"**{t}**: {q(f'SELECT COUNT(*) c FROM {t}', one=True)['c']}" for t in ("vps", "users", "admins", "warns", "audit"))))
@cmd("admin", "Transfer VPS: !transfer name @user", 1)
async def transfer(ctx, name: str, user: discord.User):
    r = find(name)
    if not r: return await ctx.send(embed=err("VPS not found."))
    q("UPDATE vps SET owner=? WHERE name=?", (user.id, r["name"])); await ctx.send(embed=emb("🔁 Transferred", f"`{r['name']}` → {user.mention}", 0x2ECC71))
@cmd("admin", "Local LXC image cache", 1)
async def hostimages(ctx): rc, o = await lx("image", "list", "-c", "lfd"); await ctx.send(embed=emb("🗃️ Cached images", f"```\n{trim(o, 1800)}\n```"))
@cmd("admin", "Raw `lxc list`", 1)
async def hostcontainers(ctx): rc, o = await lx("list", "-c", "ns4mc"); await ctx.send(embed=emb("📦 Containers", f"```\n{trim(o, 1800)}\n```"))
@cmd("admin", "LXC version", 1)
async def lxcversion(ctx): rc, o = await lx("version"); await ctx.send(embed=emb("ℹ️ LXC", f"```{o}```"))
@cmd("admin", "Change bot status text", 1)
async def setstatus(ctx, *, text: str): await bot.change_presence(activity=discord.Game(text)); await ctx.send(embed=emb("✅ Status set", text))
@cmd("admin", "Recent audit log", 1)
async def auditlog(ctx): await ctx.send(embed=emb("📜 Audit", "\n".join(f"<t:{r['ts']}:t> <@{r['uid']}> **{r['action']}** {r['detail']}" for r in q("SELECT * FROM audit ORDER BY id DESC LIMIT 15")) or "empty"))
@cmd("admin", "Count users & VPS", 1)
async def usercount(ctx): await ctx.send(embed=emb("👥 Users", f"Known: **{q('SELECT COUNT(*) c FROM users', one=True)['c']}**\nWith VPS: **{q('SELECT COUNT(DISTINCT owner) c FROM vps', one=True)['c']}**"))
@cmd("admin", "Top VPS owners", 1)
async def topusers(ctx): await ctx.send(embed=emb("🏆 Top owners", "\n".join(f"<@{r['owner']}> — {r['c']}" for r in q("SELECT owner,COUNT(*) c FROM vps GROUP BY owner ORDER BY c DESC LIMIT 10")) or "none"))

# ═════════════════════ CATEGORY 3 — UTILITY & FUN (50) ═════════════════════
@cmd("util", "Show commands")
async def help_(ctx, *, query: str = None):
    if query:
        c = bot.get_command(query.lower().lstrip(PREFIX))
        if not c: return await ctx.send(embed=err("Unknown command."))
        return await ctx.send(embed=emb(f"📖 {PREFIX}{c.name}", f"{c.brief or '-'}\n**Usage:** `{PREFIX}{c.name} {c.signature}`\n**Category:** {TITLES.get(CAT.get(c.name), '-')}"))
    await ctx.send(embed=help_home(), view=HelpView(ctx.author.id))
@cmd("util", "Latency")
async def ping(ctx): await ctx.send(embed=emb("🏓 Pong!", f"`{bot.latency * 1000:.0f} ms`"))
@cmd("util", "Bot uptime")
async def uptime(ctx): await ctx.send(embed=emb("⏱️ Uptime", f"`{upt(time.time() - START)}`"))
@cmd("util", "Bot information")
async def botinfo(ctx):
    e = emb("🤖 Bot Info", f"Servers **{len(bot.guilds)}** • Commands **{len(CAT)}** • VPS **{q('SELECT COUNT(*) c FROM vps', one=True)['c']}**\ndiscord.py `{discord.__version__}` • Python `{sys.version.split()[0]}`"); await ctx.send(embed=e)
@cmd("util", "Invite link")
async def invite(ctx): await ctx.send(embed=emb("🔗 Invite", f"https://discord.com/oauth2/authorize?client_id={bot.user.id}&permissions=8&scope=bot"))
@cmd("util", "About the project")
async def about(ctx): await ctx.send(embed=emb("🔥 About", f"```\n{art('ArizNodesLabs')}\n{art('Vasplayz90')}\n```LXC VPS deployer with Pinggy SSH + sshx."))
@cmd("util", "Credits")
async def credits(ctx): await ctx.send(embed=emb("💎 Credits", "Made by **Vasplayz90**\nPowered by **ArizNodesLabs**\nLXC • Pinggy • sshx • discord.py"))
@cmd("util", "Server info")
async def serverinfo(ctx):
    g = ctx.guild; await ctx.send(embed=emb(f"🏰 {g.name}", f"Members **{g.member_count}** • Channels **{len(g.channels)}** • Roles **{len(g.roles)}**\nOwner <@{g.owner_id}> • Created <t:{int(g.created_at.timestamp())}:R>"))
@cmd("util", "User info")
async def whois(ctx, m: discord.Member = None):
    m = m or ctx.author; e = emb(f"👤 {m}", f"ID `{m.id}`\nCreated <t:{int(m.created_at.timestamp())}:R>\nJoined <t:{int(m.joined_at.timestamp())}:R>"); e.set_thumbnail(url=m.display_avatar.url); await ctx.send(embed=e)
@cmd("util", "Avatar")
async def avatar(ctx, u: discord.User = None): u = u or ctx.author; e = emb(f"🖼️ {u}"); e.set_image(url=u.display_avatar.url); await ctx.send(embed=e)
@cmd("util", "Make the bot say something")
async def say(ctx, *, text: str):
    try: await ctx.message.delete()
    except Exception: pass
    await ctx.send(text, allowed_mentions=discord.AllowedMentions.none())
@cmd("util", "Custom embed: !embed title | text")
async def embed(ctx, *, text: str): t, _, d = text.partition("|"); await ctx.send(embed=emb(t.strip(), d.strip() or None))
@cmd("util", "Poll: !poll Q | a | b | c")
async def poll(ctx, *, text: str):
    p = [x.strip() for x in text.split("|")]
    if len(p) < 3: return await ctx.send(embed=err("Usage: `poll Question | a | b`"))
    m = await ctx.send(embed=emb("📊 " + p[0], "\n".join(f"{i + 1}\ufe0f\u20e3 {o}" for i, o in enumerate(p[1:10]))))
    for i in range(len(p[1:10])): await m.add_reaction(f"{i + 1}\ufe0f\u20e3")
@cmd("util", "Flip a coin")
async def coinflip(ctx): await ctx.send(embed=emb("🪙 Coin", random.choice(["Heads", "Tails"])))
@cmd("util", "Roll a d6")
async def dice(ctx): await ctx.send(embed=emb("🎲 Dice", str(random.randint(1, 6))))
@cmd("util", "Magic 8-ball", name="8ball")
async def eightball(ctx, *, q_: str = "?"): await ctx.send(embed=emb("🎱 8-Ball", random.choice(["Yes.", "No.", "Maybe.", "Definitely!", "Ask later.", "Doubtful.", "Without a doubt.", "Very unlikely.", "Signs point to yes.", "Cannot predict now."])))
@cmd("util", "Random joke")
async def joke(ctx): await ctx.send(embed=emb("😂 Joke", random.choice(["Why do programmers prefer dark mode? Light attracts bugs.", "There are 10 kinds of people: those who know binary and those who don't.", "A SQL query walks into a bar, sees two tables and asks: 'Can I join you?'", "!false — it's funny because it's true.", "I'd tell you a UDP joke, but you might not get it."])))
@cmd("util", "Choose: !choose a | b | c")
async def choose(ctx, *, opts: str): await ctx.send(embed=emb("🤔 I choose", random.choice([o.strip() for o in opts.split("|") if o.strip()] or ["nothing"])))
@cmd("util", "Roll NdM: !roll 2d20")
async def roll(ctx, spec: str = "1d20"):
    m = re.fullmatch(r"(\d{1,2})d(\d{1,4})", spec)
    if not m: return await ctx.send(embed=err("Use NdM, e.g. 2d20"))
    r = [random.randint(1, int(m.group(2))) for _ in range(int(m.group(1)))]; await ctx.send(embed=emb("🎲 Roll", f"{r} = **{sum(r)}**"))
_O = {ast.Add: op.add, ast.Sub: op.sub, ast.Mult: op.mul, ast.Div: op.truediv, ast.Pow: op.pow, ast.Mod: op.mod, ast.FloorDiv: op.floordiv}
def _ev(n):
    if isinstance(n, ast.Constant) and isinstance(n.value, (int, float)): return n.value
    if isinstance(n, ast.BinOp) and type(n.op) in _O:
        a, b = _ev(n.left), _ev(n.right)
        if isinstance(n.op, ast.Pow) and abs(b) > 100: raise ValueError("exponent too large")
        return _O[type(n.op)](a, b)
    if isinstance(n, ast.UnaryOp) and isinstance(n.op, ast.USub): return -_ev(n.operand)
    raise ValueError("unsupported expression")
@cmd("util", "Safe calculator")
async def calc(ctx, *, expr: str):
    try: await ctx.send(embed=emb("🧮 Result", f"`{expr}` = **{_ev(ast.parse(expr, mode='eval').body)}**"))
    except Exception as e: await ctx.send(embed=err(str(e)))
@cmd("util", "Discord timestamp")
async def timestamp(ctx): t = int(time.time()); await ctx.send(embed=emb("🕒 Timestamp", f"<t:{t}:F>\n`<t:{t}:F>`"))
def mk_text(n, brief, fn):
    async def f(ctx, *, text: str):
        try: await ctx.send(embed=emb(f"✨ {n}", f"```{trim(str(fn(text)), 1800)}```"))
        except Exception as e: await ctx.send(embed=err(str(e)))
    f.__name__ = n; cmd("util", brief)(f)
for _n, _b, _f in [("b64e", "Base64 encode", lambda s: base64.b64encode(s.encode()).decode()), ("b64d", "Base64 decode", lambda s: base64.b64decode(s.encode()).decode()),
 ("reverse", "Reverse text", lambda s: s[::-1]), ("upper", "UPPERCASE", lambda s: s.upper()), ("lower", "lowercase", lambda s: s.lower()), ("count", "Count characters", lambda s: f"{len(s)} characters"),
 ("binary", "Text to binary", lambda s: " ".join(f"{ord(c):08b}" for c in s[:100])), ("mock", "mOcKiNg text", lambda s: "".join(c.upper() if i % 2 else c.lower() for i, c in enumerate(s))),
 ("wordcount", "Count words", lambda s: f"{len(s.split())} words")]: mk_text(_n, _b, _f)
@cmd("util", "Hash text (sha256)", name="hash")
async def hash_(ctx, *, text: str): await ctx.send(embed=emb("🔏 SHA-256", f"```{hashlib.sha256(text.encode()).hexdigest()}```"))
@cmd("util", "Generate a password")
async def genpass(ctx, n: int = 16):
    try: await ctx.author.send(embed=emb("🔑 Password", f"`{''.join(secrets.choice(string.ascii_letters + string.digits + '!@#$%^&*') for _ in range(max(8, min(n, 64))))}`")); await ctx.message.add_reaction("📬")
    except discord.Forbidden: await ctx.send(embed=err("Open your DMs first."))
@cmd("util", "Random UUID")
async def uuid(ctx): await ctx.send(embed=emb("🆔 UUID", f"`{uuidlib.uuid4()}`"))
@cmd("util", "Preview a hex color")
async def color(ctx, hexcode: str):
    h = hexcode.lstrip("#")
    try: v = int(h, 16); assert len(h) == 6
    except Exception: return await ctx.send(embed=err("Use 6-digit hex, e.g. `ff4500`"))
    await ctx.send(embed=emb(f"🎨 #{h}", f"RGB `{(v >> 16, (v >> 8) & 255, v & 255)}`", v))
@cmd("util", "Rock paper scissors")
async def rps(ctx, pick: str):
    pick = pick.lower(); b = random.choice(["rock", "paper", "scissors"])
    if pick not in ("rock", "paper", "scissors"): return await ctx.send(embed=err("rock / paper / scissors"))
    await ctx.send(embed=emb("✂️ RPS", f"You: **{pick}** • Me: **{b}**\n" + ("Draw!" if pick == b else "You win! 🎉" if (pick, b) in [("rock", "scissors"), ("paper", "rock"), ("scissors", "paper")] else "I win 😎")))
def mk_act2(n, verb):
    async def f(ctx, m: discord.Member = None): await ctx.send(embed=emb(f"{verb}", f"{ctx.author.mention} {n}s {(m or ctx.author).mention}!"))
    f.__name__ = n; cmd("util", f"{n.title()} someone")(f)
for _n, _v in [("slap", "👋 Slap!"), ("hug", "🤗 Hug!"), ("pat", "🐾 Pat!")]: mk_act2(_n, _v)
@cmd("util", "Reminder: !remind 10m text")
async def remind(ctx, when: str, *, text: str = "⏰"):
    m = re.fullmatch(r"(\d+)([smhd])", when)
    if not m: return await ctx.send(embed=err("Use e.g. 30s, 10m, 2h, 1d"))
    s = int(m.group(1)) * {"s": 1, "m": 60, "h": 3600, "d": 86400}[m.group(2)]
    if s > 604800: return await ctx.send(embed=err("Max 7 days."))
    await ctx.send(embed=emb("⏰ Reminder set", f"in {when}"))
    async def _r(): await asyncio.sleep(s); await ctx.send(f"{ctx.author.mention}", embed=emb("⏰ Reminder", text))
    asyncio.create_task(_r())
@cmd("util", "Member count")
async def membercount(ctx): await ctx.send(embed=emb("👥 Members", str(ctx.guild.member_count)))
@cmd("util", "List roles")
async def roles(ctx): await ctx.send(embed=emb("🎭 Roles", trim(" ".join(r.mention for r in ctx.guild.roles[1:]), 3000) or "none"))
@cmd("util", "Channel info")
async def channelinfo(ctx, ch: discord.TextChannel = None): ch = ch or ctx.channel; await ctx.send(embed=emb(f"#{ch.name}", f"ID `{ch.id}`\nCreated <t:{int(ch.created_at.timestamp())}:R>\nSlowmode {ch.slowmode_delay}s"))
@cmd("util", "Role info")
async def roleinfo(ctx, role: discord.Role): await ctx.send(embed=emb(f"🎭 {role.name}", f"ID `{role.id}` • Members **{len(role.members)}** • Color `{role.color}`", role.color.value or FIRE))
@cmd("util", "Snowflake → date")
async def snowflake(ctx, sid: int): await ctx.send(embed=emb("❄️ Snowflake", f"<t:{int(discord.utils.snowflake_time(sid).timestamp())}:F>"))
@cmd("util", "Big ASCII text")
async def bigtext(ctx, *, text: str): await ctx.send(f"```\n{trim(art(text[:14], 'big'), 1900)}\n```")
@cmd("util", "Rate anything")
async def rate(ctx, *, thing: str): await ctx.send(embed=emb("⭐ Rating", f"**{thing}** → `{random.Random(thing.lower()).randint(0, 10)}/10`"))
@cmd("util", "Ship two names")
async def ship(ctx, a: str, b: str): p = int(hashlib.md5("".join(sorted([a.lower(), b.lower()])).encode()).hexdigest(), 16) % 101; await ctx.send(embed=emb("💘 Ship", f"{a} × {b}\n`{bar(p)}`"))
@cmd("util", "Current UTC time")
async def utc(ctx): await ctx.send(embed=emb("🌐 UTC", dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%S")))
@cmd("util", "Random tech fact")
async def fact(ctx): await ctx.send(embed=emb("🧠 Fact", random.choice(["LXC shares the host kernel, so containers boot in seconds.", "The first computer bug was a real moth, found in 1947.", "Linux powers the vast majority of the world's servers.", "SSH replaced telnet in 1995 to encrypt remote logins.", "The first domain ever registered was symbolics.com."])))
@cmd("util", "Inspirational quote")
async def quote(ctx): await ctx.send(embed=emb("💬 Quote", random.choice(["Talk is cheap. Show me the code. — Linus Torvalds", "Premature optimization is the root of all evil. — Donald Knuth", "Simplicity is prerequisite for reliability. — Edsger Dijkstra", "Make it work, make it right, make it fast. — Kent Beck"])))

# ───────────────────────── startup ─────────────────────────
async def _hook(): bot.add_view(PanelView())
bot.setup_hook = _hook
@bot.event
async def on_ready():
    q("UPDATE vps SET ssh=''"); await bot.change_presence(activity=discord.Activity(type=discord.ActivityType.watching, name=f"{PREFIX}help • ArizNodesLabs"))
    print(f"\n✅ Logged in as {bot.user} • {len(bot.commands)} commands • {len(bot.guilds)} servers")
def banner():
    print("\033[38;5;208m")
    for t in ("ArizNodesLabs", "Vasplayz90"): print(art(t, "big"))
    print("\033[0m  🔥 VPS Deployer Bot • LXC + Pinggy + sshx\n")
if __name__ == "__main__":
    banner(); cnt = {k: sum(1 for c in CAT.values() if c == k) for k in TITLES}; print("Commands:", cnt, "total", len(CAT))
    if not TOKEN or "YOUR_BOT_TOKEN" in TOKEN: sys.exit("❌ Set DISCORD_TOKEN in .env")
    bot.run(TOKEN, log_handler=None)
ARIZ_BOT_PY

cat > requirements.txt <<'ARIZ_REQ'
discord.py>=2.4.0
python-dotenv>=1.0.0
psutil>=5.9.0
pyfiglet>=1.0.2
ARIZ_REQ

if [ ! -f .env ]; then
cat > .env <<'ARIZ_ENV'
# ── ArizNodesLabs VPS Deployer — edit ONLY this file ──
DISCORD_TOKEN=YOUR_BOT_TOKEN_HERE
OWNER_IDS=123456789012345678
PREFIX=!
MAX_VPS_PER_USER=3
MAX_RAM_MB=8192
MAX_CPU=4
MAX_DISK_GB=50
# Optional: Pinggy Pro token for non-expiring tunnels (leave empty for free)
PINGGY_TOKEN=
LXC_BIN=lxc
ARIZ_ENV
fi

cat > ariznodes-vpsbot.service <<ARIZ_SVC
[Unit]
Description=ArizNodesLabs VPS Deployer Bot
After=network-online.target snap.lxd.daemon.service
Wants=network-online.target

[Service]
User=root
WorkingDirectory=$DIR
ExecStart=$DIR/venv/bin/python bot.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
ARIZ_SVC

if [ "$1" = "--install" ]; then
  [ "$(id -u)" = 0 ] || { echo "Run as root for --install"; exit 1; }
  apt-get update -y && apt-get install -y python3 python3-venv python3-pip openssh-client snapd
  if ! command -v lxc >/dev/null 2>&1; then
    snap install lxd && export PATH=$PATH:/snap/bin && lxd init --auto
  fi
  python3 -m venv venv && ./venv/bin/pip install -r requirements.txt
  cp ariznodes-vpsbot.service /etc/systemd/system/
  systemctl daemon-reload && systemctl enable ariznodes-vpsbot
  echo "✅ Installed. Edit .env, then:  systemctl start ariznodes-vpsbot"
else
  echo "✅ Files written. Run again with --install to set up LXD, venv and systemd."
fi
