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

## Agent config sync

Bootstrap also installs Syncthing and shares `~/.claude` with the other machines,
filtered by [`claude.stignore`](claude.stignore) to `CLAUDE.md`, `skills/`, `agents/`
and each project's `memory/`. Credentials, `settings.json`, sessions and caches stay
per machine. Peers dial each other on their tailnet IP; relays and public discovery are
off. Old versions of changed or deleted files are kept in `~/.claude/.stversions`.

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
