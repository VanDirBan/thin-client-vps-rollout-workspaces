# VPS rollout installer runbook

This document describes the admin-laptop workflow for rolling out a new working VPS with `scripts/vps-provision.sh`.

The current script slice is based on the v2.3 installer bundle, sanitized for a public repository and translated to English.

The provisioner installs and configures, from a clean VPS:

- XFCE with LightDM/Xorg and a dummy 1920×1080 display;
- NoMachine server for remote desktop access;
- Firefox, Telegram Desktop, Teams via teams-for-linux, and Multilogin X;
- WireGuard client tooling and a VPS keypair;
- optional PipeWire audio tunnel to a paired thin-client laptop;
- Prometheus `node_exporter` bound to the VPS WireGuard IP only;
- two users: an admin user with sudo and a worker user without sudo;
- worker-session lock/blanking disablement for remote-desktop use;
- Windows-like XFCE desktop polish via `xfce-win10.sh`.

There are two ways to run it:

- interactive launcher — easiest for a routine VPS rollout from an admin laptop;
- manual SSH run — useful for debugging, non-standard hosting setups, or partial reruns.

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
- WireGuard server keys/endpoints, SSH keys, private keys, screenshots, logs, and source archives.

## Before running

Prepare:

- clean VPS on Ubuntu 24 or Debian 13, amd64;
- root SSH access to the VPS;
- Internet access from the admin laptop and VPS;
- Multilogin X `.deb` file placed locally next to the launcher or in `scripts/`;
- free WireGuard address for this VPS;
- optional paired thin-client laptop number/address for the audio tunnel;
- local `.env.vps-provision` if you do not want the launcher to prompt for initial user passwords or if you already know the WireGuard server values.

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
- paired thin-client laptop last octet for the audio tunnel, or Enter to skip audio;
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

If a paired thin client is ready for audio, pass:

```bash
AUDIO_TUNNEL_ENABLE='yes' \
AUDIO_LAPTOP_IP='10.8.0.6' \
AUDIO_TCP_PORT='4713'
```

## Selective reruns

Without arguments, the provisioner runs all steps. With arguments, it runs only selected steps, still in canonical order. `preflight` always runs.

Useful commands:

```bash
sudo -E bash scripts/vps-provision.sh --list
sudo -E bash scripts/vps-provision.sh nomachine display
sudo -E bash scripts/vps-provision.sh wireguard
sudo -E bash scripts/vps-provision.sh audio
sudo -E bash scripts/vps-provision.sh node_exporter
sudo -E bash scripts/vps-provision.sh mlx
```

The canonical step list is:

```text
base desktop users firefox telegram teams wireguard nomachine audio mlx node_exporter display nolock shortcuts summary
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

Do not hand-edit `/etc/wireguard/wg0.conf` for durable changes. The file is generated from the script/env values and is overwritten on each `wireguard` step rerun.

## Audio tunnel

The audio tunnel is separate from NoMachine audio. The provisioner disables the NoMachine server-side audio interface in `node.cfg` and uses PipeWire TCP instead.

Architecture:

- the thin-client laptop runs PipeWire TCP on the WireGuard-side port, installed by `local-provision.sh`;
- the VPS creates a user-level `audio-tunnel.service` for the worker user;
- the keeper maintains `laptop_out` and `laptop_mic` using `module-tunnel-sink` and `module-tunnel-source`;
- a desktop shortcut named `Restart audio` restarts the tunnel and shows a notification.

Conditions for audio to work:

- the paired laptop has been provisioned by `local-provision.sh`;
- WireGuard is up on both VPS and laptop;
- the worker user is logged in on both machines;
- `AUDIO_TUNNEL_ENABLE=yes` and `AUDIO_LAPTOP_IP` points to the laptop's WireGuard address.

Checks from the VPS worker session:

```bash
pactl list short sinks | grep laptop_out
pactl list short sources | grep laptop_mic
systemctl --user status audio-tunnel
journalctl --user -u audio-tunnel
journalctl -t audio-tunnel
```

If audio disappears, first use the `Restart audio` desktop shortcut. If it does not recover, check whether the laptop is powered on and whether WireGuard is up on both sides.

## node_exporter

The `node_exporter` step installs `prometheus-node-exporter` and writes:

- `/etc/default/prometheus-node-exporter` with `--web.listen-address=<WG_IP>:9100`;
- `/etc/systemd/system/prometheus-node-exporter.service.d/override.conf` with retry-on-failure behavior.

It intentionally binds to the WireGuard address only, keeping metrics off the VPS public interface and inside the management network.

Expected check from the admin node:

```bash
curl http://<vps-wg-ip>:9100/metrics
```

If the service is restarting while wg0 is down, that is expected; it should start after the WireGuard address appears.

## NoMachine and display behavior

NoMachine free shares the physical Xorg display. The provisioner therefore installs LightDM/Xorg and forces a dummy 1920×1080 display for headless VPS use.

The current version enables LightDM autologin for the worker user so reconnects enter the XFCE desktop without a greeter password prompt.

After provisioning:

- connect with NoMachine as the worker user;
- run `bash ~/Desktop/xfce-win10.sh` inside the worker user's XFCE session if the launcher copied it there;
- check that the Windows-like theme, keyboard shortcuts, panel, and 1920×1080 resolution are applied.

The `nolock` step removes screen lockers and installs an autostart file that disables screen blanking/DPMS for the worker session.

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
- if audio is enabled, verify `laptop_out`/`laptop_mic` from the worker session;
- verify `node_exporter` from the admin node over the VPS WireGuard IP;
- reboot if `/var/run/reboot-required` exists;
- verify that pfSense policy restricts NoMachine and SSH to WireGuard or approved management networks.

## Network policy

Perimeter firewall rules and WireGuard server peers are managed on pfSense outside the VPS provisioner. NoMachine on port `4000` and SSH must be reachable only through WireGuard or approved management networks. Verify this policy after every rollout.
