# bootstrap

Joins a machine to my SSH mesh: every machine on the tailnet can SSH into every
other one, in both directions, without copying keys around by hand.

GitHub is the single list of trusted keys. Each machine publishes its own public
key to `github.com/peraltafederico.keys` once, and `keysync` mirrors that list
into `~/.ssh/authorized_keys` every 15 minutes. No secrets live in this repo.

## New or reinstalled machine

```sh
bash -c "$(curl -fsSL https://raw.githubusercontent.com/peraltafederico/bootstrap/main/bootstrap.sh)"
```

It installs Tailscale and an SSH server, installs and schedules `keysync`,
creates an SSH key if missing, publishes it to GitHub, and sets up agent config
sync (below). You approve two
things in a browser: the Tailscale login and a GitHub device code. The GitHub
login is temporary and removed when the script ends. Re-running is safe.

macOS: install and log into the Tailscale app first, and turn on
System Settings > General > Sharing > Remote Login.

## Don't want to wait 15 minutes

```sh
keysync          # sync this machine now
keysync --all    # sync this machine and every online tailnet peer
```

Run `keysync --all` from a machine that is already trusted. A freshly
reinstalled machine cannot do it, since the others don't accept its new key yet.

## Waking sleeping screens

```sh
wake                 # turn on the monitors of every computer on the tailnet
wake mini desktop    # only peers whose name contains one of these words
wake --for 30m       # keep them on this long (default 10m)
wake --ping          # report what answers and which displays are on, without waking
wake -l              # list devices with the short name that picks each one
```

Any part of a Tailscale machine name works (`wake air`). `wake -l` shows the shortest part
unique to each device; rename a machine in the Tailscale admin console for a custom name.

It runs over SSH, so it reaches every machine the mesh trusts. Locked screens stay
locked: you get the lock screen, not the desktop. Phones answer `--ping` but cannot be
woken remotely.

- macOS: external monitors stay dark until real input arrives, so `wake` builds a small
  `wake-nudge` helper on first use (needs Xcode Command Line Tools) and posts a 1 pixel
  mouse nudge with it. Allow `wake-nudge` once in System Settings > Privacy & Security >
  Accessibility on each Mac; `wake` reminds you until you do.
- A Mac in full system sleep is off the tailnet and cannot be reached. `wake` warns when a
  Mac is set to system-sleep; `sudo pmset -c sleep 0` keeps it awake on power while the
  display still sleeps.
- Linux: GNOME only (X11 or Wayland).

## Claude Code token usage

```sh
tokens                               # this machine, last 7 days, one row per day
tokens cami                          # any machine you can SSH into: macOS, Linux or Windows
tokens all                           # every machine in one table, with its share of the limits
tokens all --since cycle             # since the plan last renewed
tokens federicos-desktop federicos-mac-mini --since today --by session
tokens cami --watch 60               # refresh every minute
tokens --detail                      # every token type per row
tokens --json                        # machine-readable
tokens --no-limits                   # skip the plan limits (faster, reads only the named machines)
```

`--since` takes `today`, `12h`, `7d`, a date, or `cycle` (the current billing month: monthly
plans renew on the day and time the subscription started, which `tokens` reads from the account); `--by` takes `day`, `model`, `session`
or `project`. It reads the reply logs Claude Code keeps in `~/.claude/projects` (over
SSH for other machines, nothing is installed there) and counts each API reply once:
input, output, cache write and cache read tokens.

- **API $** is what those tokens would cost at Anthropic's API list prices, kept in
  `PRICES` at the top of the script. A plan bills a flat fee instead.
- **Limits**: the 5-hour and 7-day limits belong to the account, which every machine
  shares. `tokens` asks Anthropic for the account's percentages (the numbers Claude
  Code's `/usage` shows, fetched on the checked machine with its own login), reads every
  online tailnet machine, and estimates a machine's part as the account percentage times
  that machine's share of the API-priced Claude Code usage in the same window. Offline
  machines are listed as not counted, since their usage would otherwise be credited to
  the others.
- **`tokens all`** lists every tailnet machine with its share of each limit, plus a
  "Chats & other apps" row for account usage outside Claude Code; the rows add up to the
  account total (rounded with the largest-remainder method). Without `--since` it covers
  the current limit week, so every column describes the same period.

Colors turn off when the output is piped or `NO_COLOR` is set; `FORCE_COLOR=1` keeps them.
Needs `python3` on the machine running it and on macOS or Linux machines it reads limits from.

## Claude Code status line

`claude-statusline` is Claude Code's status line on every machine. It prints four lines:

1. Model, effort, context as a `███░░░░░░░` bar with tokens used, compactions in this session,
   the session's API-priced cost, and whether the prompt cache is still warm (with what a
   re-cache would cost against a cache hit).
2. The account's 5-hour (hidden when no window is open) and weekly limits as bars, with reset
   times; today's use of the weekly limit against today's even share of what was left at
   midnight (`today 6.2% of 9.5%`, yellow from 80 % of it, red when over), with
   today's cost at API prices and tokens across every machine; the same since the plan last
   renewed, and the next renewal date. Today's percentage splits the Claude Code part of the
   week by cost; chats leave no logs, so they count as spread over the week. The magenta part of the weekly bar is this machine's share.
3. Every machine's share of the weekly limit, this machine first, from `tokens all --json`.
4. Folder, git branch, worktree and the branch's PR (a link).

Bootstrap installs it with `claude-statusline --install`, which sets it as the status line,
keeps any status line that was there before (like Orca's) as a chained one in
`~/.claude/claude-statusline.json`, and removes the claude-hud plugin. Skills that ship an
executable `statusline.sh` are chained too. The scripts need Python 3.11+; under macOS's
Python 3.9 they re-run themselves with a newer one from Homebrew or `uv python install`.

A machine that cannot reach the others (the restricted Windows laptop) is installed with
`claude-statusline --install --devices-pushed`; the desktop copies every machine's usage to it
every 10 minutes with `claude-statusline --push cami` from cron.

Lines 1 and 2 come from what Claude Code sends the script, so they are always current. Reading
every machine takes several seconds, so line 3 shows a cache in `~/.cache/claude-statusline` that a
detached copy of the script refreshes at most every 5 minutes; the PR is cached for 2 minutes.

## Agent config sync

Bootstrap also installs Syncthing and shares `~/.claude` with the other machines,
filtered by [`claude.stignore`](claude.stignore) to `CLAUDE.md`, `skills/`, `agents/`
and each project's `memory/`. Credentials, `settings.json`, sessions and caches stay
per machine. Peers dial each other on their tailnet IP; relays and public discovery are
off. Old versions of changed or deleted files are kept in `~/.claude/.stversions`.

`settings.json` is not synced: apps like Orca write machine-specific hooks into it. Bootstrap
merges the portable preferences in [`claude-settings.json`](claude-settings.json) into it
instead (commit attribution off, bypass permissions, effort, retention); those keys win and
the rest of the file is kept. Edit that file and re-run bootstrap to change them everywhere.

Codex reads the same files through two relative links, so new skills need no extra step:

```
~/.codex/AGENTS.md -> ../.claude/CLAUDE.md
~/.codex/skills    -> ../.claude/skills
```

A new machine joins receive-only, so the copy already syncing wins:

1. Run bootstrap. It prints two commands: run them on a machine that already syncs,
   then the same two here with that machine's id (`syncthing device-id`), tailnet
   name and IP.
2. Once they connect, re-run bootstrap. After the first sync it reverts this machine's
   differing files to the synced copy (its own versions go to `~/.claude/.stversions`)
   and switches the folder to send-receive.

The very first machine of a fresh setup has nobody to sync from; start it with
`syncthing cli config folders claude type set sendreceive`. The Air MacBook stays out: the step skips tailnet names listed
in `AGENT_SYNC_SKIP_HOSTS` at the top of `bootstrap.sh`, and it is never paired.
`BOOTSTRAP_AGENT_SYNC=0` skips the step on any machine and `BOOTSTRAP_AGENT_SYNC=1`
forces it on a listed one.

Bootstrap never replaces a real `~/.codex/AGENTS.md` or a real skill inside
`~/.codex/skills`, and warns about absolute symlinks in `~/.claude/skills`, which
would sync as dead links. The `.stignore` is not synced itself, so ignore-list
changes reach a machine when bootstrap re-runs there.

## Removing a machine

Delete its key at <https://github.com/settings/keys>. Every machine drops it on
its next sync, or immediately after `keysync --all`.

## Notes

- Only the block between the `keysync` markers in `authorized_keys` is managed;
  keys added by hand are kept.
- A failed, empty, or malformed response from GitHub never changes the file, so
  an outage cannot lock you out.
- Your GitHub account is the root of trust here. Keep 2FA on.
- Reinstalled machines get new SSH host keys. On other machines, clear the old
  entry once with `ssh-keygen -R <name>`.
