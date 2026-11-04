
#!/usr/bin/env bash
set -Eeuo pipefail

echo "=================================="
echo "       VELOCLOUD BOT INSTALLER"
echo "=================================="

read -rsp "BOT_TOKEN: " BOT_TOKEN
echo
read -rp "OWNER_ID: " OWNER_ID

if [[ -z "$BOT_TOKEN" || ! "$OWNER_ID" =~ ^[0-9]+$ ]]; then
    echo "Invalid BOT_TOKEN or OWNER_ID"
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo bash"
    exit 1
fi

apt-get update -y
apt-get install -y python3 python3-venv

mkdir -p /opt/velocloud
cd /opt/velocloud

cat > .env <<EOF
BOT_TOKEN=$BOT_TOKEN
OWNER_ID=$OWNER_ID
EOF
chmod 600 .env
unset BOT_TOKEN OWNER_ID

python3 -m venv venv
venv/bin/pip install --upgrade pip
venv/bin/pip install "discord.py>=2.4,<3"

cat > bot.py <<'PY'
import os
import json
import asyncio
import discord
from datetime import datetime, timezone
from discord.ext import commands

def load_env():
    with open(".env") as f:
        return dict(line.strip().split("=", 1) for line in f if "=" in line)

ENV = load_env()
TOKEN = ENV["BOT_TOKEN"]
OWNER_ID = int(ENV["OWNER_ID"])

DB = "data.json"

def load_db():
    try:
        with open(DB) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {"applications": {}, "counters": {}, "warnings": {}}

data = load_db()

def save_db():
    with open(DB + ".tmp", "w") as f:
        json.dump(data, f, indent=2)
    os.replace(DB + ".tmp", DB)

intents = discord.Intents.default()
intents.message_content = True
intents.members = True

bot = commands.Bot(command_prefix="!", intents=intents)
active_apps = set()

QUESTIONS = [
    "What is your real age?",
    "What is your Discord username?",
    "Which staff position are you applying for?",
    "Why do you want to join our staff team?",
    "Do you have previous staff experience?",
    "How many hours can you be active daily?",
    "How would you handle a member breaking server rules?",
    "Why should we select you?"
]

def staff(ctx):
    return ctx.author.id == OWNER_ID or ctx.author.guild_permissions.manage_guild

@bot.event
async def on_ready():
    print(f"VELOCLOUD ONLINE: {bot.user}")
    print("Staff Apply and Announcement systems ready.")

@bot.command()
async def ping(ctx):
    await ctx.send(f"Pong! {round(bot.latency * 1000)}ms")

@bot.command()
@commands.check(lambda ctx: ctx.author.id == OWNER_ID)
async def setup(ctx):
    for name in ["announcements", "open-ticket", "server-logs"]:
        if not discord.utils.get(ctx.guild.text_channels, name=name):
            await ctx.guild.create_text_channel(name)
    await ctx.send("VELOCLOUD setup complete!")

@bot.command()
@commands.check(staff)
async def announce(ctx, *, message):
    channel = discord.utils.get(ctx.guild.text_channels, name="announcements")
    if channel is None:
        channel = await ctx.guild.create_text_channel("announcements")

    embed = discord.Embed(
        title="VELOCLOUD ANNOUNCEMENT",
        description=message,
        color=discord.Color.blurple(),
        timestamp=datetime.now(timezone.utc)
    )
    embed.set_footer(text=f"By {ctx.author}")
    await channel.send(embed=embed)
    await ctx.send("Announcement sent!")

@bot.command()
async def staffapply(ctx):
    if ctx.guild is None:
        return await ctx.send("Use this command inside your server.")

    if ctx.author.id in active_apps:
        return await ctx.send("Your application is already running.")

    try:
        await ctx.author.send(
            f"Welcome to {ctx.guild.name} Staff Application!\n"
            "I will ask questions one by one.\n"
            "Reply with your answer. Type cancel to stop."
        )
    except discord.Forbidden:
        return await ctx.send("Enable server member DMs and try again.")

    active_apps.add(ctx.author.id)
    await ctx.send(f"{ctx.author.mention}, check your DMs!")

    answers = []

    try:
        for i, question in enumerate(QUESTIONS, 1):
            await ctx.author.send(
                f"**Question {i}/{len(QUESTIONS)}**\n{question}"
            )

            def check(m):
                return (
                    m.author.id == ctx.author.id
                    and isinstance(m.channel, discord.DMChannel)
                )

            try:
                reply = await bot.wait_for(
                    "message", check=check, timeout=600
                )
            except asyncio.TimeoutError:
                await ctx.author.send("Application timed out.")
                return

            answer = reply.content.strip()

            if answer.lower() == "cancel":
                await ctx.author.send("Application cancelled.")
                return

            if not answer:
                await ctx.author.send("Please provide an answer.")
                # Ask the same question again.
                i -= 1
                continue

            answers.append({
                "question": question,
                "answer": answer
            })

            data["applications"][str(ctx.author.id)] = {
                "status": "in_progress",
                "username": str(ctx.author),
                "user_id": ctx.author.id,
                "guild_id": ctx.guild.id,
                "answers": answers
            }
            save_db()
            await ctx.author.send("Answer saved!")

        guild_key = str(ctx.guild.id)
        number = data["counters"].get(guild_key, 0) + 1
        channel_name = f"staff-apply-{number:03d}"

        role = discord.utils.get(
            ctx.guild.roles, name="VELOCLOUD Staff"
        )

        overwrites = {
            ctx.guild.default_role:
                discord.PermissionOverwrite(view_channel=False),
            ctx.author:
                discord.PermissionOverwrite(
                    view_channel=True,
                    send_messages=True,
                    read_message_history=True
                ),
            ctx.guild.me:
                discord.PermissionOverwrite(
                    view_channel=True,
                    send_messages=True,
                    read_message_history=True
                )
        }

        if role:
            overwrites[role] = discord.PermissionOverwrite(
                view_channel=True,
                send_messages=True,
                read_message_history=True
            )

        channel = await ctx.guild.create_text_channel(
            channel_name,
            overwrites=overwrites
        )

        embed = discord.Embed(
            title=f"STAFF APPLICATION #{number:03d}",
            color=discord.Color.gold(),
            timestamp=datetime.now(timezone.utc)
        )

        embed.add_field(
            name="Applicant",
            value=f"{ctx.author.mention}\n{ctx.author}",
            inline=False
        )
        embed.add_field(
            name="User ID",
            value=str(ctx.author.id),
            inline=False
        )

        for item in answers:
            embed.add_field(
                name=item["question"][:250],
                value=item["answer"][:900],
                inline=False
            )

        await channel.send(
            content=f"New application from {ctx.author.mention}",
            embed=embed
        )

        data["counters"][guild_key] = number
        data["applications"][str(ctx.author.id)].update({
            "status": "submitted",
            "channel_id": channel.id,
            "channel_name": channel_name,
            "submitted_at": datetime.now(timezone.utc).isoformat()
        })
        save_db()

        await ctx.author.send(
            f"Your application is submitted!\n"
            f"Application: {channel_name}"
        )

    except discord.Forbidden:
        await ctx.author.send(
            "Bot needs permission to create private channels."
        )
    finally:
        active_apps.discard(ctx.author.id)

@bot.command()
@commands.check(staff)
async def applications(ctx, member: discord.Member):
    record = data["applications"].get(str(member.id))

    if not record:
        return await ctx.send("No application found.")

    embed = discord.Embed(
        title="Saved Staff Application",
        description=f"Applicant: {member.mention}\nStatus: {record['status']}",
        color=discord.Color.gold()
    )

    for item in record["answers"]:
        embed.add_field(
            name=item["question"][:250],
            value=item["answer"][:900],
            inline=False
        )

    await ctx.send(embed=embed)

@bot.command()
async def ticket(ctx):
    if ctx.guild is None:
        return

    name = f"ticket-{ctx.author.id}"
    existing = discord.utils.get(ctx.guild.text_channels, name=name)

    if existing:
        return await ctx.send(f"Your ticket: {existing.mention}")

    role = discord.utils.get(ctx.guild.roles, name="VELOCLOUD Staff")

    permissions = {
        ctx.guild.default_role:
            discord.PermissionOverwrite(view_channel=False),
        ctx.author:
            discord.PermissionOverwrite(
                view_channel=True,
                send_messages=True,
                read_message_history=True
            ),
        ctx.guild.me:
            discord.PermissionOverwrite(
                view_channel=True,
                send_messages=True,
                read_message_history=True
            )
    }

    if role:
        permissions[role] = discord.PermissionOverwrite(
            view_channel=True,
            send_messages=True,
            read_message_history=True
        )

    channel = await ctx.guild.create_text_channel(
        name, overwrites=permissions
    )
    await channel.send(f"{ctx.author.mention} Your ticket is open!")

@bot.command()
@commands.check(staff)
async def close(ctx):
    if ctx.channel.name.startswith(("ticket-", "staff-apply-")):
        await ctx.send("Closing channel in 5 seconds...")
        await asyncio.sleep(5)
        await ctx.channel.delete()

@bot.command()
@commands.check(staff)
async def warn(ctx, member: discord.Member, *, reason="No reason"):
    key = str(member.id)
    data["warnings"].setdefault(key, []).append(reason)
    save_db()
    await ctx.send(f"{member.mention} warned: {reason}")

@bot.command()
async def warnings(ctx, member: discord.Member = None):
    target = member or ctx.author
    await ctx.send(
        f"Warnings for {target}: "
        f"{data['warnings'].get(str(target.id), [])}"
    )

@bot.command()
@commands.check(staff)
async def kick(ctx, member: discord.Member, *, reason="No reason"):
    await member.kick(reason=reason)
    await ctx.send(f"Kicked {member}.")

@bot.command()
@commands.check(staff)
async def ban(ctx, member: discord.Member, *, reason="No reason"):
    await member.ban(reason=reason)
    await ctx.send(f"Banned {member}.")

@bot.command()
@commands.check(staff)
async def purge(ctx, amount: int):
    amount = max(1, min(amount, 100))
    await ctx.channel.purge(limit=amount + 1)
    await ctx.send("Messages deleted.", delete_after=5)

@bot.command()
async def serverinfo(ctx):
    g = ctx.guild
    await ctx.send(
        f"Server: {g.name}\nMembers: {g.member_count}"
    )

@bot.command()
async def userinfo(ctx, member: discord.Member = None):
    member = member or ctx.author
    await ctx.send(f"User: {member}\nID: {member.id}")

@bot.command()
async def avatar(ctx, member: discord.Member = None):
    member = member or ctx.author
    await ctx.send(member.display_avatar.url)

@bot.command()
async def help(ctx):
    await ctx.send(
        "**VELOCLOUD COMMANDS**\n"
        "`!setup` - Setup channels (owner)\n"
        "`!announce message` - Announcement\n"
        "`!staffapply` - Staff application\n"
        "`!applications @member` - View application\n"
        "`!ticket` - Open ticket\n"
        "`!close` - Close ticket/application\n"
        "`!warn @member reason`\n"
        "`!warnings @member`\n"
        "`!kick @member reason`\n"
        "`!ban @member reason`\n"
        "`!purge number`\n"
        "`!ping` `!serverinfo` `!userinfo` `!avatar`"
    )

@bot.event
async def on_command_error(ctx, error):
    if isinstance(error, commands.CheckFailure):
        await ctx.send("You don't have permission.")
    elif isinstance(error, commands.MissingRequiredArgument):
        await ctx.send("Missing argument. Check !help.")
    elif isinstance(error, commands.CommandNotFound):
        pass
    else:
        print("ERROR:", repr(error))
        await ctx.send("Command error. Check VPS logs.")

bot.run(TOKEN)
PY

cat > /etc/systemd/system/velocloud.service <<'EOF'
[Unit]
Description=VELOCLOUD Discord Bot
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=/opt/velocloud
ExecStart=/opt/velocloud/venv/bin/python /opt/velocloud/bot.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now velocloud

echo
echo "VELOCLOUD INSTALLED!"
echo "Status: systemctl status velocloud"
echo "Logs: journalctl -u velocloud -f"
echo "Restart: systemctl restart velocloud"
