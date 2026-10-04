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
creates an SSH key if missing, and publishes it to GitHub. You approve two
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
