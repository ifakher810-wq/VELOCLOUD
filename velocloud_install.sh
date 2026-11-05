#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="/opt/velocloud-maker"
DATA_DIR="/var/lib/velocloud-maker"
SERVICE="velocloud-maker"
PYTHON="/usr/bin/python3"

if [[ $EUID -ne 0 ]]; then
  echo "Run this installer with sudo."
  exit 1
fi

echo "======================================"
echo "       VELOCLOUD BOT MAKER"
echo "======================================"

apt-get update
apt-get install -y python3 python3-venv python3-pip curl

mkdir -p "$APP_DIR" "$DATA_DIR"
chmod 750 "$APP_DIR" "$DATA_DIR"

if [[ ! -f "$APP_DIR/.env" ]]; then
  read -rp "Enter Discord Panel Bot Token: " BOT_TOKEN
  read -rp "Enter Owner Discord User ID: " OWNER_ID

  if [[ -z "$BOT_TOKEN" || -z "$OWNER_ID" ]]; then
    echo "Token and Owner ID are required."
    exit 1
  fi

  cat > "$APP_DIR/.env" <<EOF
BOT_TOKEN=$BOT_TOKEN
OWNER_ID=$OWNER_ID
EOF
  chmod 600 "$APP_DIR/.env"
fi

python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install --upgrade pip
"$APP_DIR/venv/bin/pip" install "discord.py>=2.4,<3"

cat > "$APP_DIR/bot.py" <<'PY'
import os
import re
import sys
import asyncio
import logging
import subprocess
from pathlib import Path

import discord
from discord.ext import commands
from discord import app_commands

BASE = Path("/opt/velocloud-maker")
DATA = Path("/var/lib/velocloud-maker")
PROJECTS = DATA / "projects"

PROJECTS.mkdir(parents=True, exist_ok=True)

def load_env():
    env = {}
    path = BASE / ".env"
    for line in path.read_text().splitlines():
        if "=" in line and not line.strip().startswith("#"):
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    return env

ENV = load_env()
TOKEN = ENV.get("BOT_TOKEN", "")
OWNER_ID = int(ENV.get("OWNER_ID", "0"))

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s"
)
log = logging.getLogger("velocloud")

intents = discord.Intents.default()
intents.message_content = True

bot = commands.Bot(command_prefix="!", intents=intents)

def owner_check(interaction):
    return interaction.user.id == OWNER_ID

def error_help(message):
    msg = message.lower()

    rules = [
        (["missing privileged intent", "message content intent"],
         "Message Content Intent बंद है। Discord Developer Portal में Bot > Privileged Gateway Intents खोलकर Message Content Intent ON करें।"),
        (["improper token", "invalid token", "401 unauthorized"],
         "Discord Bot Token गलत या रद्द हो चुका है। Developer Portal से सही Token लें और .env अपडेट करें।"),
        (["missing access", "50001"],
         "बॉट के पास चैनल या सर्वर access नहीं है। उसे सही permissions और channel access दें।"),
        (["missing permissions", "50013"],
         "बॉट के पास आवश्यक permissions नहीं हैं। Discord में उसकी Role और Channel Permissions जाँचें।"),
        (["application did not respond", "interaction failed"],
         "Interaction का जवाब समय पर नहीं मिला। Callback में defer() करें और बाद में followup भेजें।"),
        (["execstart", "203/exec"],
         "systemd ExecStart गलत है। Python executable और script path के बीच स्पेस होना चाहिए।"),
        (["modulenotfounderror"],
         "Python package उपलब्ध नहीं है। सही virtual environment में pip install से dependency इंस्टॉल करें।"),
        (["address already in use", "errno 98"],
         "यह Port पहले से इस्तेमाल हो रहा है। ss -ltnp से उस Port की जाँच करें।"),
        (["permission denied"],
         "फाइल या directory permission की समस्या है। सही owner और permissions जाँचें।"),
        (["no such file or directory"],
         "बताया गया file या path मौजूद नहीं है। Path और file name जाँचें।"),
        (["connection refused"],
         "Target service चल नहीं रही या गलत Port पर connection हो रहा है। Service और firewall जाँचें।"),
        (["out of memory", "oom-kill"],
         "सिस्टम में RAM कम पड़ रही है। Memory usage और service limits जाँचें।"),
        (["syntaxerror"],
         "Python code में syntax की गलती है। Error की line number पर brackets, quotes और indentation जाँचें।"),
        (["database is locked"],
         "SQLite database पर एक साथ कई writes हो रही हैं। Transactions और database connections जाँचें।"),
    ]

    for keys, answer in rules:
        if any(key in msg for key in keys):
            return answer

    return (
        "इस Error का exact कारण उपलब्ध जानकारी से तय नहीं हुआ। "
        "पूरा traceback, संबंधित service log और command जाँचें। "
        "यहाँ अनुमान से कोई destructive fix नहीं दिया जा रहा।"
    )

def create_project(name):
    safe = re.sub(r"[^a-zA-Z0-9_-]", "", name)[:32]
    if not safe:
        raise ValueError("Invalid project name")

    folder = PROJECTS / safe
    folder.mkdir(parents=True, exist_ok=True)

    main_py = folder / "bot.py"
    requirements = folder / "requirements.txt"
    readme = folder / "README.txt"

    if not main_py.exists():
        main_py.write_text('''import os
import discord
from discord.ext import commands

TOKEN = os.environ.get("BOT_TOKEN")
if not TOKEN:
    raise RuntimeError("BOT_TOKEN is missing")

intents = discord.Intents.default()
bot = commands.Bot(command_prefix="!", intents=intents)

@bot.event
async def on_ready():
    print(f"Bot online: {bot.user}")

@bot.command()
async def ping(ctx):
    await ctx.send("Pong!")

bot.run(TOKEN)
''')

    requirements.write_text("discord.py>=2.4,<3\n")
    readme.write_text(
        "VELOCLOUD generated Discord bot project\n"
        "Set BOT_TOKEN as an environment variable before starting.\n"
    )

    return folder

class ErrorModal(discord.ui.Modal, title="ERROR CODE ABOUT"):
    error = discord.ui.TextInput(
        label="Paste your error or traceback",
        style=discord.TextStyle.paragraph,
        placeholder="Paste the complete error here...",
        max_length=3000
    )

    async def on_submit(self, interaction: discord.Interaction):
        result = error_help(str(self.error))
        await interaction.response.send_message(
            f"**Error analysis**\n{result}",
            ephemeral=True
        )

class CreateModal(discord.ui.Modal, title="CREATE BOT PROJECT"):
    name = discord.ui.TextInput(
        label="New bot project name",
        placeholder="MyDiscordBot",
        max_length=32
    )

    async def on_submit(self, interaction: discord.Interaction):
        if not owner_check(interaction):
            return await interaction.response.send_message(
                "Only the configured owner can create projects.",
                ephemeral=True
            )

        await interaction.response.defer(ephemeral=True)

        try:
            folder = create_project(str(self.name))
            await interaction.followup.send(
                f"**Project created successfully!**\n"
                f"Project: `{folder.name}`\n"
                f"Location: `{folder}`\n\n"
                "Add a separate Bot Token securely before starting this project. "
                "A new Discord Bot Account must first be created in Developer Portal.",
                ephemeral=True
            )
        except Exception as exc:
            log.exception("Project creation failed")
            await interaction.followup.send(
                f"Project creation failed: `{type(exc).__name__}: {exc}`",
                ephemeral=True
            )

class MakerPanel(discord.ui.View):
    def __init__(self):
        super().__init__(timeout=None)

    @discord.ui.button(
        label="CREATE BOT AUTOMATIC",
        style=discord.ButtonStyle.success,
        emoji="🤖",
        custom_id="vc:create"
    )
    async def create(self, interaction, button):
        if not owner_check(interaction):
            return await interaction.response.send_message(
                "Only the configured owner can create projects.",
                ephemeral=True
            )
        await interaction.response.send_modal(CreateModal())

    @discord.ui.button(
        label="ERROR CODE ABOUT",
        style=discord.ButtonStyle.primary,
        emoji="🛠️",
        custom_id="vc:error"
    )
    async def error(self, interaction, button):
        await interaction.response.send_modal(ErrorModal())

@bot.event
async def on_ready():
    bot.add_view(MakerPanel())
    try:
        await bot.tree.sync()
    except Exception:
        log.exception("Slash command sync failed")
    log.info("Logged in as %s", bot.user)

@bot.command(name="panel")
async def panel(ctx):
    if ctx.author.id != OWNER_ID:
        return
    embed = discord.Embed(
        title="VELOCLOUD BOT MAKER",
        description=(
            "🤖 **CREATE BOT AUTOMATIC**\n"
            "Create a new Discord bot project automatically.\n\n"
            "🛠️ **ERROR CODE ABOUT**\n"
            "Submit an error to get its explanation and possible fix."
        ),
        color=discord.Color.blurple()
    )
    await ctx.send(embed=embed, view=MakerPanel())

@bot.command(name="helpvc")
async def helpvc(ctx):
    await ctx.send(
        "**VELOCLOUD BOT MAKER**\n"
        "`!panel` - Open the main panel\n"
        "`!helpvc` - Show help"
    )

@bot.tree.command(name="panel", description="Open VELOCLOUD Bot Maker")
async def slash_panel(interaction: discord.Interaction):
    if not owner_check(interaction):
        return await interaction.response.send_message(
            "Owner only.", ephemeral=True
        )
    embed = discord.Embed(
        title="VELOCLOUD BOT MAKER",
        description="Choose an option below.",
        color=discord.Color.blurple()
    )
    await interaction.response.send_message(embed=embed, view=MakerPanel())

if not TOKEN or not OWNER_ID:
    raise RuntimeError("BOT_TOKEN or OWNER_ID missing in /opt/velocloud-maker/.env")

bot.run(TOKEN)
PY

cat > /etc/systemd/system/${SERVICE}.service <<EOF
[Unit]
Description=VELOCLOUD Bot Maker
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
ExecStart=${APP_DIR}/venv/bin/python ${APP_DIR}/bot.py
Restart=on-failure
RestartSec=5
User=root
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

"$APP_DIR/venv/bin/python" -m py_compile "$APP_DIR/bot.py"
systemctl daemon-reload
systemctl enable "$SERVICE"
systemctl restart "$SERVICE"

echo
echo "Installation completed."
echo "Check: systemctl status ${SERVICE} --no-pager"
echo "Logs: journalctl -u ${SERVICE} -f"
echo "Discord command: !panel"
echo "Slash command: /panel"
