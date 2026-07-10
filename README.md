# Department VPS Workflows

Work-in-progress infrastructure repository for moving one department's daily work from local physical laptops to managed VPS desktops.

The project has two connected parts:

1. **VPS/thin-client workplace migration** — a physical laptop becomes a managed thin client that connects to a working VPS desktop.
2. **WorkMon screenshot collection** — the worker laptop captures screenshots locally, encrypts them immediately, and the admin laptop later pulls, decrypts, and uploads them to an SMB share.

This repository is currently the baseline implementation. It is expected to evolve: firewall setup, WireGuard server configuration, operational polish, and extra automation are still planned.

## Current status

- Development-stage project, not a finished production distribution.
- Source scripts and packages are imported, organized, and sanitized.
- Real passwords, private keys, WireGuard keys, production SMB paths, screenshots, archives, and binary installers are intentionally not committed.
- Full firewall hardening is not implemented yet. Until it is added, treat externally reachable services, especially NoMachine, as requiring manual network restriction.

## Architecture overview

```text
                 ┌──────────────────────────────────────────────┐
                 │ VPS desktop                                  │
                 │ - XFCE + LightDM/Xorg                        │
                 │ - NoMachine server                           │
                 │ - Firefox / Telegram / Multilogin X          │
                 │ - WireGuard tools                            │
                 └───────────────────▲──────────────────────────┘
                                     │ NoMachine over LAN/WG
                                     │
┌────────────────────────────────────┴────────────────────────────────────┐
│ Physical worker laptop / thin client                                    │
│ - Debian 13 + XFCE                                                      │
│ - NoMachine client/server package                                       │
│ - WireGuard full tunnel                                                 │
│ - Windows-like XFCE user experience                                     │
│ - WorkMon worker agent                                                  │
│                                                                          │
│ WorkMon agent:                                                           │
│ X11 screenshot → local PNG in tmp → age encrypt → /var/lib/workmon/spool │
│ No networking, no private key, no SMB credentials                        │
└────────────────────────────────────▲────────────────────────────────────┘
                                     │ SSH + rsync pull, usually manually
                                     │
                 ┌───────────────────┴──────────────────────────┐
                 │ Admin laptop                                  │
                 │ - workmon-collect                             │
                 │ - SSH collection key                          │
                 │ - single age private key                      │
                 │ - SMB credentials                             │
                 └───────────────────▲──────────────────────────┘
                                     │ mount.cifs + encrypted SMB channel
                                     │
                 ┌───────────────────┴──────────────────────────┐
                 │ Office SMB share                              │
                 │ Plain PNG archive after successful decrypt     │
                 └──────────────────────────────────────────────┘
```

## Repository layout

```text
.
├── env/
│   ├── local-provision.env.example     # Example env for thin-client provisioning
│   └── vps-provision.env.example       # Example env for VPS provisioning
├── scripts/
│   ├── local-provision.sh              # Physical laptop/thin-client rollout
│   ├── vps-provision.sh                # VPS desktop rollout
│   ├── xfce-win10.sh                   # User-session XFCE Windows-like look
│   ├── admin/
│   │   └── copy_key.sh                 # Copy WorkMon age public key to a worker
│   └── workmon-agent-0.4.0/            # Worker-side screenshot capture agent
│       ├── capture.py
│       ├── common.py
│       ├── install.sh
│       ├── uninstall.sh
│       ├── systemd/workmon-capture.service
│       ├── README.md
│       └── ARCHITECTURE.md
└── workmon/
    └── collect/                        # Admin-laptop collector package
        ├── collect.py
        ├── collect_common.py
        ├── install.sh
        ├── uninstall.sh
        ├── hosts.sample
        └── README.md
```

## Components

### `scripts/vps-provision.sh`

Initial rollout script for the working VPS desktop.

It installs and configures:

- system updates and base packages;
- locales and timezone;
- XFCE, Xorg, LightDM, dummy display for headless/virtual desktop usage;
- NoMachine server;
- Firefox from Mozilla's APT repository;
- Telegram Desktop, with Flatpak fallback;
- Multilogin X Desktop from a local `.deb` placed next to the script;
- WireGuard tools;
- users: admin user with sudo and worker user without sudo;
- desktop shortcuts for the worker user.

Important notes:

- The script is idempotent where practical.
- It handles stuck NoMachine installer/subscription processes from a previous run.
- It verifies the downloaded NoMachine `.deb`, because the NoMachine download server may return an HTML page with HTTP 200 for a nonexistent version.
- It does **not** create the final WireGuard server tunnel config yet.
- It does **not** configure the firewall yet. After the first rollout, NoMachine may listen on port `4000` on the public interface until you close it manually.
- The Multilogin `.deb` is intentionally not committed. Put it next to `scripts/vps-provision.sh` before running:

```text
scripts/desktop-multiloginx-ubuntu-24.04-amd64.deb
```

### `scripts/local-provision.sh`

Fleet-aware provisioning script for the local physical laptop that acts as a thin client.

It prepares a Debian 13/XFCE machine with:

- unique hostname;
- SSH host keys restoration/generation;
- optional collector SSH public key in root's `authorized_keys`;
- admin and service users;
- GRUB/kernel boot options relevant to the target hardware;
- APT sources and package upgrade;
- XFCE desktop stack;
- audio stack;
- WireGuard full tunnel client config;
- WireGuard watchdog timer;
- NoMachine package;
- copied `xfce-win10.sh` helper;
- NoMachine desktop shortcut;
- WorkMon worker agent installation from `scripts/workmon-agent-0.4.0/`.

Required per-machine values:

- `NEW_HOSTNAME` — unique laptop hostname, for example `tc-05`.
- `WG_CLIENT_ADDR` — unique WireGuard client address, for example `10.8.0.5/24`.

Important WireGuard note:

If `WG_AUTOSTART=yes` is used before the corresponding peer is configured on the VPS, the laptop may boot into a full-tunnel route with no working connectivity. Either configure the VPS peer first or use `WG_AUTOSTART=no` during initial staging.

Debug mode:

```bash
sudo ONLY=wireguard,watchdog WG_CLIENT_ADDR=10.8.0.5/24 bash scripts/local-provision.sh
```

### `scripts/xfce-win10.sh`

User-session script for making XFCE feel closer to Windows 10.

It must be run as the desktop user inside an active XFCE session, not as root.

It configures:

- Windows-like GTK/window/icon theme if available;
- Super key as Start menu;
- Win+E / Win+D / Win+L / Win+R / Win+I hotkeys;
- keyboard Aero Snap shortcuts;
- mouse edge tiling;
- single workspace;
- double-click in Thunar;
- desktop icons;
- dark bottom panel/taskbar;
- clock layout;
- basic self-diagnostics.

Optional custom wallpaper:

```bash
WIN10_WALLPAPER=/path/to/wallpaper.jpg bash ~/xfce-win10.sh
```

### `scripts/workmon-agent-0.4.0/`

Worker-side WorkMon agent installed on each physical laptop.

Role: **capture and encrypt only**.

It does:

- finds the active local X11 session;
- captures screenshots with `scrot` by default;
- hashes frames and can skip byte-identical frames;
- encrypts each PNG immediately with a shared `age` public recipient;
- atomically drops `.age` files into `/var/lib/workmon/spool`;
- rotates the local encrypted spool by `LOCAL_SPOOL_MAX_MB`;
- runs as root via `workmon-capture.service`.

It does **not**:

- upload files;
- connect to the network;
- decrypt files;
- store the private age key;
- hold SMB credentials;
- hide, self-heal, or resist removal.

Systemd hardening highlights:

- `NoNewPrivileges=true`
- `ProtectSystem=full`
- `ProtectHome=read-only`
- `ReadWritePaths=/var/lib/workmon`
- `ReadOnlyPaths=/opt/workmon /etc/workmon`
- `IPAddressDeny=any`
- `UMask=0077`

### `workmon/collect/`

Admin-laptop collector package.

Role: **manual collection, local decrypt, SMB upload**.

It does:

- reads `/etc/workmon-collect/hosts`;
- connects to each worker over SSH;
- pulls only `*.age` files from `/var/lib/workmon/spool` via `rsync`;
- removes source files only after successful transfer with `--remove-source-files`;
- decrypts locally with the single admin-side age private key;
- checks that decrypted output is a valid PNG;
- uploads plaintext PNGs to the SMB share;
- writes via `*.partial` and verifies size before considering upload successful;
- keeps failed files in staging for retry;
- prevents overlapping real runs with a lock.

It is manual-only: no systemd timer is installed by the current version.

Exit codes:

- `0` — all clean;
- `1` — fatal local/config error;
- `2` — some hosts unreachable, rsync errors, or file-level failures; retry is expected.

### `scripts/admin/copy_key.sh`

Small admin-side helper for copying the shared WorkMon `age` public key from the admin laptop to a worker:

```bash
sudo scripts/admin/copy_key.sh <worker-ip-or-host>
```

It uses:

- SSH private key: `/etc/workmon-collect/id_collect`
- age public recipient: `/etc/workmon-collect/public.key`
- destination: `/etc/workmon/public.key` on the worker

Do not confuse the two key types:

- `id_collect` / `id_collect.pub` — SSH keypair for pulling encrypted files from workers.
- `private.key` / `public.key` — age identity and recipient for screenshot encryption/decryption.

## Rollout sequence

### 1. Prepare the VPS

Create an ignored local env file from the example:

```bash
cp env/vps-provision.env.example .env.vps-provision
chmod 600 .env.vps-provision
```

Edit `.env.vps-provision` and set real initial passwords and package pins.

Run the provisioner with environment preserved through sudo:

```bash
set -a
. ./.env.vps-provision
set +a
sudo -E bash scripts/vps-provision.sh
```

After the run:

- reboot if `/var/run/reboot-required` exists;
- verify LightDM/XFCE and NoMachine;
- manually restrict public access until firewall automation is added;
- configure WireGuard server peer(s) manually for now;
- place the Multilogin X `.deb` next to the script before reruns if needed.

### 2. Prepare the admin laptop collector

Install the collector:

```bash
cd workmon/collect
sudo ./install.sh
```

Generate the single age private identity on the admin laptop only:

```bash
sudo age-keygen -o /etc/workmon-collect/private.key
sudo chmod 600 /etc/workmon-collect/private.key
sudo age-keygen -y /etc/workmon-collect/private.key | sudo tee /etc/workmon-collect/public.key >/dev/null
sudo chmod 0644 /etc/workmon-collect/public.key
```

The installer creates the SSH collection key if it does not already exist:

```text
/etc/workmon-collect/id_collect
/etc/workmon-collect/id_collect.pub
```

Back up `/etc/workmon-collect/private.key` somewhere access-restricted. Without it, already encrypted screenshots cannot be decrypted.

Configure collector files:

```bash
sudo editor /etc/workmon-collect/collect.conf
sudo editor /etc/workmon-collect/hosts
sudo editor /etc/workmon-collect/smb.credentials
```

Minimal `hosts` format:

```text
<worker-host-or-wg-ip> [optional-asset-id]
```

If the second column is omitted, the collector asks the worker for `hostname -s` and uses that as the SMB folder name.

### 3. Prepare each physical worker laptop

Create an ignored local env file from the example:

```bash
cp env/local-provision.env.example .env.local-provision
chmod 600 .env.local-provision
```

Edit it per machine:

- unique `NEW_HOSTNAME`;
- unique `WG_CLIENT_ADDR`;
- real `WG_SERVER_PUBKEY`;
- real `WG_ENDPOINT`;
- collector SSH public key in `COLLECT_PUBKEY` if root SSH collection should be pre-authorized;
- temporary service user password if needed.

Run provisioning:

```bash
set -a
. ./.env.local-provision
set +a
sudo -E bash scripts/local-provision.sh
```

After provisioning, log into XFCE as the target desktop user and apply the Windows-like desktop profile:

```bash
bash ~/xfce-win10.sh
```

### 4. Deploy WorkMon age public key to workers

If SSH collection access has been set up, from the admin laptop run:

```bash
sudo scripts/admin/copy_key.sh <worker-ip-or-host>
```

Then on the worker, start or restart capture:

```bash
sudo systemctl restart workmon-capture.service
```

### 5. Verify worker capture

On a worker laptop:

```bash
systemctl status workmon-capture.service
journalctl -u workmon-capture.service -n 100 --no-pager
sudo find /var/lib/workmon/spool -maxdepth 1 -name '*.age' -printf '%TY-%Tm-%Td %TH:%TM %s %p\n'
sudo find /var/lib/workmon -name '*.png' -type f
```

Expected:

- `.age` files appear in `/var/lib/workmon/spool`;
- no persistent plaintext PNG remains under `/var/lib/workmon`;
- if public key is missing, the service stays enabled but capture is paused/not started depending on installation state.

### 6. Run collection from the admin laptop

Dry run first:

```bash
sudo workmon-collect --dry-run
```

Real run:

```bash
sudo workmon-collect
```

Single host:

```bash
sudo workmon-collect --host <worker-ip-or-asset-id>
```

Diagnostics without removing source files on workers:

```bash
sudo workmon-collect --no-remove
```

## Configuration files installed on target systems

VPS:

```text
/var/log/vps-provision.log
/etc/lightdm/lightdm.conf.d/50-xfce.conf
/etc/X11/xorg.conf.d/10-dummy.conf
/home/<work-user>/.xsession
/home/<work-user>/Desktop/*.desktop
```

Worker laptop:

```text
/var/log/local-provision.log
/etc/wireguard/wg0.conf
/etc/systemd/system/wg-watchdog.service
/etc/systemd/system/wg-watchdog.timer
/etc/workmon/workmon.conf
/etc/workmon/asset_id
/etc/workmon/public.key
/opt/workmon/
/var/lib/workmon/tmp/
/var/lib/workmon/spool/
```

Admin laptop collector:

```text
/etc/workmon-collect/collect.conf
/etc/workmon-collect/hosts
/etc/workmon-collect/smb.credentials
/etc/workmon-collect/id_collect
/etc/workmon-collect/id_collect.pub
/etc/workmon-collect/private.key
/etc/workmon-collect/public.key
/opt/workmon-collect/
/var/lib/workmon-collect/staging/
/var/lib/workmon-collect/processed/
/run/workmon-collect/decrypted/
/mnt/workmon-screenshots/
```

## Security model

### Secrets

Do not commit:

- `.env.*` files with real values;
- SSH private keys;
- age private keys;
- WireGuard private keys or real public keys if they identify the deployment;
- SMB credentials;
- screenshots or encrypted screenshot exports;
- local logs;
- binary installers such as `.deb` files.

The repository `.gitignore` already excludes the common dangerous file types: env files, keys, `.age`, screenshots, logs, source archives, and `.deb` packages.

### WorkMon encryption model

- Workers receive only `/etc/workmon/public.key`, the shared age recipient.
- The private age identity lives only on the admin laptop as `/etc/workmon-collect/private.key`.
- A compromised worker cannot decrypt existing screenshots because it never has the private key.
- The collector decrypts into `/run/workmon-collect/decrypted`, which should be tmpfs, and removes plaintext after each upload attempt.
- SMB upload uses CIFS options with `seal` enabled by default.

### Monitoring and compliance

This project is intended for company-owned equipment under an approved monitoring policy, legal basis, and employee notice. The WorkMon agent does not hide itself, resist removal, or self-heal. Screenshot interval defaults are dense and should be reviewed for proportionality, retention, and applicable law before production use.

### Network exposure

Current known gap:

- Firewall setup is not yet implemented in the provisioning scripts.
- NoMachine may listen on port `4000` publicly after VPS rollout.
- WireGuard server-side configuration is not finalized in this repository yet.

Before production use, add and verify firewall rules so that:

- NoMachine is reachable only through WireGuard or approved management networks;
- SSH is restricted to admin/VPN sources;
- SMB is reachable only where required;
- WireGuard UDP port is the only intended public service if that is the chosen design.

## Development and validation

Recommended checks after changing scripts:

```bash
# Shell syntax
bash -n scripts/local-provision.sh
bash -n scripts/vps-provision.sh
bash -n scripts/xfce-win10.sh
bash -n scripts/admin/copy_key.sh
bash -n scripts/workmon-agent-0.4.0/install.sh
bash -n scripts/workmon-agent-0.4.0/uninstall.sh
bash -n workmon/collect/install.sh
bash -n workmon/collect/uninstall.sh

# Python syntax
python3 -m py_compile \
  scripts/workmon-agent-0.4.0/capture.py \
  scripts/workmon-agent-0.4.0/common.py \
  workmon/collect/collect.py \
  workmon/collect/collect_common.py

# CLI smoke test
python3 workmon/collect/collect.py --help

# systemd unit validation, if available
systemd-analyze verify scripts/workmon-agent-0.4.0/systemd/workmon-capture.service
```

Before committing, also scan for accidental secrets or transport artifacts:

```bash
git diff --check
git status --short
```

## Current TODO / planned work

- Add VPS firewall setup.
- Add final WireGuard server configuration on the VPS side.
- Decide final NoMachine exposure policy and enforce it automatically.
- Add clearer operational runbooks after real deployment testing.
- Decide backup/retention policy for the admin-side age private key and SMB screenshot archive.
- Improve handling of local binary installers such as Multilogin X without committing them.
- Add optional health checks for worker capture and collector dry-runs.
- Revisit screenshot interval and retention with the approved monitoring policy.

## Operational cautions

- Do not run `xfce-win10.sh` as root. It needs the user's active XFCE D-Bus session.
- Do not run WorkMon collector `--purge` unless the age private key is already backed up.
- Do not reuse the same `WG_CLIENT_ADDR` on multiple workers.
- Do not enable full-tunnel WireGuard autostart until the VPS peer exists and routing is verified.
- Do not rely on NoMachine being private until firewall rules are applied and checked.
- Do not place real secrets into files tracked by git; use ignored `.env.*` files or target-system config files.

## License / ownership

Internal project repository. Add a formal license or internal-use notice before sharing outside the intended environment.
