
#!/bin/bash

clear
echo "=========================================="
echo "       VELOCLOUD STAFF + ANNOUNCEMENT"
echo "=========================================="

if [ "$EUID" -ne 0 ]; then
    echo "Restarting with sudo..."
    exec sudo bash "$0" "$@"
fi

read -rp "Enter BOT TOKEN: " BOT_TOKEN
read -rp "Enter OWNER ID: " OWNER_ID

if [ -z "$BOT_TOKEN" ] || [ -z "$OWNER_ID" ]; then
    echo "ERROR: Token and Owner ID are required!"
    exit 1
fi

echo "[1/5] Installing Python..."
apt update -y
apt install -y python3 python3-venv python3-pip

BOT_DIR="/root/velocloud-staff-bot"
mkdir -p "$BOT_DIR"
cd "$BOT_DIR" || exit 1

echo "[2/5] Creating virtual environment..."
python3 -m venv venv
./venv/bin/pip install --upgrade pip
./venv/bin/pip install discord.py

echo "[3/5] Saving configuration..."
export BOT_TOKEN OWNER_ID

python3 - <<'PY'
import os, json
with open("config.json", "w") as f:
    json.dump({
        "BOT_TOKEN": os.environ["BOT_TOKEN"],
        "OWNER_ID": int(os.environ["OWNER_ID"])
    }, f)
PY

echo "[4/5] Creating bot.py..."

cat > bot.py <<'PY'
import discord
from discord.ext import commands
import json
import os
import asyncio

with open("config.json") as f:
    config = json.load(f)

TOKEN = config["BOT_TOKEN"]
OWNER_ID = int(config["OWNER_ID"])

intents = discord.Intents.default()
intents.message_content = True
intents.members = True

bot = commands.Bot(command_prefix="!", intents=intents)

QUESTIONS = [
    "What is your Discord username?",
    "Why do you want to join our staff team?",
    "Do you have previous staff experience?",
    "How will you help our server?",
    "How much time can you give to the server?",
    "Why should we select you?"
]

active_users = set()
application_lock = asyncio.Lock()


def load_data():
    if not os.path.exists("applications.json"):
        return {"count": 0, "applications": []}
    try:
        with open("applications.json") as f:
            return json.load(f)
    except Exception:
        return {"count": 0, "applications": []}


def save_data(data):
    with open("applications.json", "w") as f:
        json.dump(data, f, indent=4)


def owner_or_admin():
    async def predicate(ctx):
        return (
            ctx.author.id == OWNER_ID
            or ctx.author.guild_permissions.manage_guild
        )
    return commands.check(predicate)


class StaffApplyView(discord.ui.View):
    def __init__(self):
        super().__init__(timeout=None)

    @discord.ui.button(
        label="Apply for Staff",
        emoji="📝",
        style=discord.ButtonStyle.green,
        custom_id="velocloud_staff_apply"
    )
    async def apply_button(
        self,
        interaction: discord.Interaction,
        button: discord.ui.Button
    ):
        user = interaction.user

        if user.id in active_users:
            await interaction.response.send_message(
                "You already have an active application!",
                ephemeral=True
            )
            return

        active_users.add(user.id)

        await interaction.response.send_message(
            "Check your DMs! Your staff application is starting.",
            ephemeral=True
        )

        answers = []

        try:
            await user.send(
                "**VELOCLOUD STAFF APPLICATION**\n"
                "Answer the following questions one by one.\n"
                "You have 5 minutes for each answer.\n"
                "Type `cancel` to stop."
            )

            for question in QUESTIONS:
                await user.send(f"**Question {len(answers)+1}:** {question}")

                def check(message):
                    return (
                        message.author.id == user.id
                        and isinstance(message.channel, discord.DMChannel)
                    )

                try:
                    response = await bot.wait_for(
                        "message",
                        check=check,
                        timeout=300
                    )
                except asyncio.TimeoutError:
                    await user.send(
                        "Application timed out. Please apply again later."
                    )
                    return

                if response.content.lower().strip() == "cancel":
                    await user.send("Your application was cancelled.")
                    return

                answers.append(response.content[:850])
                await user.send("Answer saved!")

            guild = interaction.guild

            if guild is None:
                await user.send("Server not found. Please try again.")
                return

            async with application_lock:
                data = load_data()
                data["count"] += 1
                number = data["count"]

                channel_name = f"staff-apply-{number:03d}"

                overwrites = {
                    guild.default_role: discord.PermissionOverwrite(
                        view_channel=False
                    ),
                    guild.me: discord.PermissionOverwrite(
                        view_channel=True,
                        send_messages=True,
                        read_message_history=True
                    )
                }

                overwrites[user] = discord.PermissionOverwrite(
                    view_channel=True,
                    send_messages=True,
                    read_message_history=True
                )

                try:
                    owner = guild.get_member(OWNER_ID)
                    if owner is None:
                        owner = await guild.fetch_member(OWNER_ID)

                    overwrites[owner] = discord.PermissionOverwrite(
                        view_channel=True,
                        send_messages=True,
                        read_message_history=True
                    )
                except discord.HTTPException:
                    pass

                channel = await guild.create_text_channel(
                    channel_name,
                    topic=f"Staff Apply {number:03d}",
                    overwrites=overwrites
                )

                embed = discord.Embed(
                    title=f"Staff Apply {number:03d}",
                    description=(
                        f"**Applicant:** {user.mention}\n"
                        f"**Username:** {user}\n"
                        f"**User ID:** {user.id}"
                    ),
                    color=discord.Color.green()
                )

                for i, (question, answer) in enumerate(
                    zip(QUESTIONS, answers), 1
                ):
                    embed.add_field(
                        name=f"Q{i}: {question}",
                        value=answer,
                        inline=False
                    )

                embed.set_footer(
                    text="VELOCLOUD Staff Application Review"
                )

                await channel.send(
                    content=f"<@{OWNER_ID}>",
                    embed=embed
                )

                data["applications"].append({
                    "number": number,
                    "user_id": user.id,
                    "username": str(user),
                    "channel_id": channel.id,
                    "answers": answers
                })

                save_data(data)

            await user.send(
                "Your application has been submitted successfully!"
            )

        except discord.Forbidden:
            try:
                await user.send(
                    "I cannot DM you. Please enable server DMs and try again."
                )
            except discord.HTTPException:
                pass

        except Exception as error:
            print("APPLICATION ERROR:", error)
            try:
                await user.send(
                    "Something went wrong. Please contact the server owner."
                )
            except discord.HTTPException:
                pass

        finally:
            active_users.discard(user.id)


@bot.event
async def on_ready():
    bot.add_view(StaffApplyView())
    print("================================")
    print("VELOCLOUD BOT IS ONLINE!")
    print("Bot:", bot.user)
    print("================================")


@bot.command()
@owner_or_admin()
async def setup(ctx):
    guild = ctx.guild

    if guild is None:
        return

    announcements = discord.utils.get(
        guild.text_channels,
        name="announcements"
    )

    if announcements is None:
        announcements = await guild.create_text_channel(
            "announcements"
        )

    staff_channel = discord.utils.get(
        guild.text_channels,
        name="staff-apply"
    )

    if staff_channel is None:
        staff_channel = await guild.create_text_channel(
            "staff-apply"
        )

    embed = discord.Embed(
        title="VELOCLOUD STAFF APPLICATION",
        description=(
            "Want to become a member of our staff team?\n\n"
            "Click the button below to apply.\n"
            "The bot will ask you questions in DMs."
        ),
        color=discord.Color.green()
    )

    embed.set_footer(text="VELOCLOUD Staff Team")

    await staff_channel.send(
        embed=embed,
        view=StaffApplyView()
    )

    await ctx.send(
        "Setup completed!\n"
        f"Staff Apply: {staff_channel.mention}\n"
        f"Announcements: {announcements.mention}\n"
        "Staff Apply button has been posted."
    )


@bot.command()
@owner_or_admin()
async def staffpanel(ctx):
    embed = discord.Embed(
        title="VELOCLOUD STAFF APPLICATION",
        description=(
            "Click the button below to apply for staff.\n"
            "Questions will be sent to your DMs."
        ),
        color=discord.Color.green()
    )

    await ctx.send(embed=embed, view=StaffApplyView())


@bot.command()
@owner_or_admin()
async def announce(ctx, *, message):
    channel = discord.utils.get(
        ctx.guild.text_channels,
        name="announcements"
    )

    if channel is None:
        channel = await ctx.guild.create_text_channel(
            "announcements"
        )

    embed = discord.Embed(
        title="📢 VELOCLOUD ANNOUNCEMENT",
        description=message,
        color=discord.Color.blue()
    )

    embed.set_footer(text=f"Announced by {ctx.author}")

    await channel.send(embed=embed)
    await ctx.reply("Announcement sent successfully!")


@bot.command()
@owner_or_admin()
async def applications(ctx):
    data = load_data()

    if not data["applications"]:
        await ctx.send("No applications found.")
        return

    lines = []
    for app in data["applications"][-20:]:
        lines.append(
            f"**Staff Apply {app['number']:03d}** "
            f"<@{app['user_id']}> "
            f"<#{app['channel_id']}>"
        )

    await ctx.send("\n".join(lines))


@bot.command()
@owner_or_admin()
async def ping(ctx):
    await ctx.send(f"Pong! {round(bot.latency * 1000)}ms")


@bot.command()
async def help(ctx):
    embed = discord.Embed(
        title="VELOCLOUD BOT COMMANDS",
        color=discord.Color.blue()
    )

    embed.add_field(
        name="Staff Application",
        value=(
            "`!setup` - Create channels and staff panel\n"
            "`!staffpanel` - Post staff application button\n"
            "`!applications` - View application list"
        ),
        inline=False
    )

    embed.add_field(
        name="Announcement",
        value="`!announce Your message` - Send announcement",
        inline=False
    )

    embed.add_field(
        name="Other",
        value="`!ping` - Check bot latency",
        inline=False
    )

    await ctx.send(embed=embed)


@bot.event
async def on_command_error(ctx, error):
    if isinstance(error, commands.CheckFailure):
        await ctx.send("You don't have permission to use this command.")
    elif isinstance(error, commands.MissingRequiredArgument):
        await ctx.send("Please provide the required command arguments.")
    elif isinstance(error, commands.CommandNotFound):
        return
    else:
        print("COMMAND ERROR:", error)
        await ctx.send("An error occurred while running the command.")


bot.run(TOKEN)
PY

echo "[5/5] Starting VELOCLOUD BOT..."
echo "=========================================="
echo "       BOT IS STARTING..."
echo "=========================================="

exec ./venv/bin/python -u bot.py
