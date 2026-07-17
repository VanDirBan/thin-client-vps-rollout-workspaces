# VPS rollout installer runbook

This document describes the admin-laptop workflow for rolling out a new working VPS with `scripts/vps-provision.sh`.

The VPS provisioner installs and configures, from a clean VPS:

- XFCE with LightDM/Xorg and a dummy 1920×1080 display;
- NoMachine server for remote desktop access;
- Firefox, Telegram Desktop, and Multilogin X;
- WireGuard client tooling and a VPS keypair;
- two users: an admin user with sudo and a worker user without sudo;
- Windows-like XFCE desktop polish via `xfce-win10.sh`.

There are two ways to run it:

- **interactive launcher** — easiest for a routine VPS rollout from an admin laptop;
- **manual SSH run** — useful for debugging, non-standard hosting setups, or partial reruns.

## Files involved

In the repository:

- `scripts/vps-provision.sh` — main provisioner, executed on the VPS;
- `scripts/admin/vps-provision-launcher.sh` — interactive admin-laptop launcher;
- `scripts/admin/vps-provision-launcher.desktop` — desktop shortcut for the launcher;
- `scripts/xfce-win10.sh` — user-session XFCE polish script, copied to the VPS after rollout;
- `env/vps-provision.env.example` — sanitized example for local environment values;
- `scripts/admin/copy_key.sh` and `scripts/admin/copy_key_launcher.sh` — WorkMon helpers, unrelated to VPS provisioning itself;
- `scripts/admin/WorkMon-copy-public-key.desktop` — desktop shortcut for the WorkMon key helper;
- `scripts/admin/workmon-hosts.desktop` — desktop shortcut for editing `/etc/workmon-collect/hosts` on the admin laptop.

Not committed to git:

- `desktop-multiloginx-*.deb` — local Multilogin X installer; place it next to the launcher or next to `scripts/` before running;
- `.env.vps-provision` — local ignored environment file with real passwords and site values;
- WireGuard keys/endpoints, SSH keys, private keys, screenshots, logs, and source archives.

## Before running

Prepare:

- clean VPS on Ubuntu 24 or Debian 13, amd64;
- root SSH access to the VPS;
- Internet access from the admin laptop and VPS;
- Multilogin X `.deb` file placed locally next to the launcher or in `scripts/`;
- free WireGuard address for this VPS;
- local `.env.vps-provision` if you do not want the launcher to prompt for initial user passwords.

Create the local env file from the example if needed:

```bash
cp env/vps-provision.env.example .env.vps-provision
chmod 600 .env.vps-provision
```

Edit real values only in the ignored local file, not in tracked scripts.

## Interactive launcher flow

From the repo layout, run:

```bash
bash scripts/admin/vps-provision-launcher.sh
```

Or double-click `scripts/admin/vps-provision-launcher.desktop` from a prepared admin desktop folder.

The launcher asks for:

- public IP address of the new VPS;
- WireGuard last octet for the VPS address;
- timezone, or Enter to keep the provisioner default;
- initial admin and worker passwords if they are not already set through `.env.vps-provision`.

Then it:

- opens one SSH control connection to `root@<VPS_IP>`;
- copies `vps-provision.sh` to `/root/vps-provision.sh` on the VPS;
- copies `desktop-multiloginx-*.deb` to `/root/`;
- runs the provisioner remotely with selected values passed through environment variables;
- optionally copies `xfce-win10.sh` to the worker user's desktop.

If the rollout fails, scroll up to the first `[FAIL]` line. The VPS log is:

```text
/var/log/vps-provision.log
```

Most provisioning steps are idempotent, so a rerun is expected after transient package/network failures.

## Manual run

Copy files to the VPS:

```bash
scp scripts/vps-provision.sh desktop-multiloginx-ubuntu-24.04-amd64.deb root@<VPS_IP>:/root/
```

Run on the VPS with real values passed through the environment:

```bash
ssh root@<VPS_IP>
ADMIN_PASS='CHANGE_ME' \
WORK_PASS='CHANGE_ME' \
WG_ADDRESS='10.8.0.101/24' \
TIMEZONE='Europe/Berlin' \
bash /root/vps-provision.sh
```

If the WireGuard server details are already known, pass them too:

```bash
WG_SERVER_PUBKEY='REPLACE_WITH_WG_SERVER_PUBLIC_KEY' \
WG_SERVER_ENDPOINT='vpn.example.com:51820' \
WG_ALLOWED_IPS='10.8.0.0/24'
```

## Selective reruns

Without arguments, the provisioner runs all steps. With arguments, it runs only selected steps, still in canonical order. `preflight` always runs.

Useful commands:

```bash
sudo -E bash scripts/vps-provision.sh --list
sudo -E bash scripts/vps-provision.sh nomachine display
sudo -E bash scripts/vps-provision.sh wireguard
sudo -E bash scripts/vps-provision.sh mlx
```

The script is designed so repeated runs do not reset existing user passwords. Passwords are only applied when the users are first created.

## WireGuard two-phase setup

The VPS is a client of an existing WireGuard network.

The `wireguard` step always:

- installs WireGuard tooling;
- creates `/etc/wireguard/vps_private.key` if absent;
- creates `/etc/wireguard/vps_public.key` if absent;
- prints the VPS public key in the summary.

It writes and starts `wg0` only when both values are provided:

- `WG_SERVER_PUBKEY`;
- `WG_SERVER_ENDPOINT`.

If those are empty, add the VPS public key as a peer on the WG server first, then rerun:

```bash
sudo -E bash scripts/vps-provision.sh wireguard
```

For a split-tunnel deployment, `WG_ALLOWED_IPS` should usually be the tunnel subnet, not `0.0.0.0/0`.

## NoMachine and display behavior

NoMachine free shares the physical Xorg display. The provisioner therefore installs LightDM/Xorg and forces a dummy 1920×1080 display for headless VPS use.

The current version enables LightDM autologin for the worker user so reconnects enter the XFCE desktop without a greeter password prompt.

After provisioning:

- connect with NoMachine as the worker user;
- run `bash ~/Desktop/xfce-win10.sh` inside the worker user's XFCE session if the launcher copied it there;
- check that the Windows-like theme, keyboard shortcuts, panel, and 1920×1080 resolution are applied.

## WorkMon admin helpers

The WorkMon desktop helpers are separate from VPS rollout.

`copy_key.sh` copies the shared age public recipient from the admin laptop to a worker:

```bash
sudo scripts/admin/copy_key.sh <worker-ip>
```

It uses:

- SSH key: `/etc/workmon-collect/id_collect`;
- source public key: `/etc/workmon-collect/public.key`;
- worker destination: `/etc/workmon/`.

`copy_key_launcher.sh` is an interactive wrapper for admins. `workmon-hosts.desktop` opens `/etc/workmon-collect/hosts` with `sudo nano`.

## Post-rollout checklist

After the VPS rollout:

- add the VPS WireGuard public key as a peer on the WG server if not already done;
- rerun the `wireguard` step if the first rollout generated keys only;
- verify NoMachine connection as the worker user;
- apply `xfce-win10.sh` in the worker XFCE session;
- reboot if `/var/run/reboot-required` exists;
- restrict NoMachine and SSH exposure manually until firewall automation is implemented.

## Known gap

Firewall automation is not implemented yet. Until it is added and verified, NoMachine port `4000` may be reachable on the public VPS interface after rollout. Treat the VPS as exposed until access is restricted to WireGuard, SSH tunnel, or approved admin networks.
