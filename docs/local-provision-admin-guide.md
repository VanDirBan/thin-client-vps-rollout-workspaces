# Local thin-client provisioning admin guide

This runbook covers the physical laptop / thin-client side of the department VPS workflow.

The source archives were flat installer bundles. In this repository the canonical files live under `scripts/`, with secrets and site-specific values moved to ignored environment files.

## 1. Files to keep together

When exporting a deployable USB/folder bundle for a laptop rollout, keep these files in one directory:

```text
local-provision.sh
local-provision-launcher.sh
local-provision-launcher.desktop
xfce-win10.sh
workmon-agent-0.4.0/
```

Optional local config/secrets file in the same directory or one level above when running from the repository layout:

```text
.env.local-provision
```

`.env.local-provision` is intentionally ignored by git. It may contain real WireGuard server details, initial rollout passwords, the collector SSH public key, paired-VPS addresses, and local address-plan defaults.

## 2. Required per-machine values

Before starting, allocate from your inventory:

- unique hostname, for example `tc-07`;
- unique WireGuard client address, for example `10.8.0.7/24`;
- server-side peer entry with `AllowedIPs = 10.8.0.7/32`;
- optional paired VPS WireGuard address, for example `10.8.0.101`;
- optional per-machine x11vnc password, exactly 8 characters.

Recommended sanitized address plan used by the launcher defaults:

- `10.8.0.6-99` — physical laptops / thin clients;
- `10.8.0.101-200` — VPS desktops.

Adjust these defaults in `.env.local-provision` or by environment variables if the real tunnel network differs.

## 3. Prepare local secrets/config

Create an ignored file next to the scripts:

```bash
cp env/local-provision.env.example .env.local-provision
chmod 600 .env.local-provision
```

Edit it and set real values for:

- `WG_SERVER_PUBKEY`;
- `WG_ENDPOINT`;
- `COLLECT_PUBKEY` if WorkMon collection over SSH should be installed automatically;
- `SVC_USER_PASSWORD` and optionally `X11VNC_PASSWORD` for the initial rollout;
- `AUDIO_ALLOWED_IPS` if the real WireGuard subnet differs from the sanitized example;
- `NX_VPS_HOST` only if you want to preconfigure the paired NoMachine session by environment instead of answering the launcher question.

Do not commit this file.

## 4. Run through the launcher

From a terminal:

```bash
cd scripts
bash local-provision-launcher.sh
```

Or double-click `local-provision-launcher.desktop` from a prepared desktop folder that contains the scripts next to it.

The launcher asks for:

1. laptop tunnel number or full CIDR address;
2. hostname;
3. optional x11vnc password;
4. paired VPS tunnel number from the VPS range.

If a paired VPS number is provided, the NoMachine desktop shortcut opens a fullscreen session to that VPS automatically. If you press Enter, the shortcut launches bare `nxplayer` and the connection is added manually later.

The launcher then asks whether to run all steps or only selected steps, shows a summary, and runs `local-provision.sh` with values passed through environment variables.

## 5. Manual run

If the launcher is unavailable:

```bash
set -a
. ./.env.local-provision
set +a
sudo -E NEW_HOSTNAME=tc-07 WG_CLIENT_ADDR=10.8.0.7/24 bash scripts/local-provision.sh
```

Optional variables normally handled by the launcher:

```bash
NX_VPS_HOST=10.8.0.101      # preconfigure fullscreen NoMachine session
NX_CONNECT_ENABLE=no        # disable preconfigured session and use bare nxplayer
X11VNC_PASSWORD=xxxxxxxx    # exactly 8 characters
```

Selective debug runs use `ONLY=`:

```bash
sudo -E ONLY=wireguard,watchdog NEW_HOSTNAME=tc-07 WG_CLIENT_ADDR=10.8.0.7/24 bash scripts/local-provision.sh
```

Step order:

```text
hostname -> ssh_hostkeys -> collect_key -> users -> grub -> apt_sources -> upgrade ->
desktop -> audio -> audioprio -> wireguard -> watchdog -> nomachine -> x11vnc ->
node_exporter -> win10_script -> nm_shortcut -> power -> workmon -> summary
```

## 6. What the provisioner configures

- `hostname` — unique host identity and `/etc/hosts` `127.0.1.1` entry.
- `ssh_hostkeys` — restores missing SSH host keys with `ssh-keygen -A`.
- `collect_key` — installs the WorkMon collector SSH public key into root's `authorized_keys` when provided.
- `users` — grants sudo to the admin user and creates the non-sudo service user.
- `grub` — hides boot menu delays.
- `apt_sources` / `upgrade` — enables firmware repositories, updates the system, installs firmware, kernel headers, and NetworkManager.
- `desktop` — installs XFCE, LightDM, fonts, Windows-like theme assets, desktop extras, and the XFCE pulseaudio tray plugin.
- `audio` — installs PipeWire/pulse utilities, grants the service user audio/video access, and writes a `module-native-protocol-tcp` config into the service user's `pipewire-pulse` config. The audio tunnel starts automatically with that user's session; no manual module load or watchdog is needed.
- `audioprio` — installs a WirePlumber rule that makes the built-in Realtek card start in duplex mode (output + input). This fixes the output-only profile where no audio source exists and the microphone is dead.
- `wireguard` — generates a client keypair and writes `/etc/wireguard/wg0.conf`; it does not bring the tunnel up immediately.
- `watchdog` — installs `wg-watchdog.timer` to recover stale WireGuard handshakes and boot races.
- `nomachine` — installs the pinned NoMachine package and configures XFCE for incoming sessions.
- `x11vnc` — installs a fallback VNC service bound only to the WireGuard interface address.
- `node_exporter` — installs Prometheus node_exporter, bound only to the machine's WireGuard IP and port `9100` by default.
- `win10_script` — copies `xfce-win10.sh` to the service user's desktop.
- `nm_shortcut` — creates a clean NoMachine launcher on the service user's desktop and marks it trusted on first login. If `NX_VPS_HOST` is set, it also writes `~smm/.local/share/nomachine/VPS.nxs` and the shortcut opens that session fullscreen.
- `power` — prevents screen blanking/locking for the service user and the LightDM greeter.
- `workmon` — installs the worker-side WorkMon screenshot agent from `workmon-agent-0.4.0/`.
- `summary` — prints the client public key and next manual steps.

## 7. Required post-run order

Because this is a full-tunnel WireGuard design, do the next steps while physically at the laptop or with console access:

1. Add the generated client public key as a peer on the WireGuard server/firewall.
2. Use server-side `AllowedIPs = <laptop-wg-ip>/32`.
3. On the laptop, bring up the tunnel:

   ```bash
   sudo wg-quick up wg0
   ```

4. Verify tunnel and external routing:

   ```bash
   ping 10.8.0.1
   curl ifconfig.me
   ```

5. Log in as the service user so the PipeWire audio tunnel starts. Verify from that session:

   ```bash
   pactl list short modules | grep native-protocol-tcp
   ```

6. Launch NoMachine from the service user's desktop shortcut:
   - if a paired VPS was configured, the shortcut opens it in fullscreen;
   - otherwise add a manual NX connection to the matching VPS WireGuard address.
7. Apply the XFCE Windows-like look from the service user's session:

   ```bash
   bash ~/Desktop/xfce-win10.sh
   ```

8. Change default rollout passwords immediately:

   ```bash
   sudo passwd smm
   sudo x11vnc -storepasswd /etc/x11vnc.pass
   sudo systemctl restart x11vnc
   ```

9. Reboot so firmware/microcode, LightDM, WireGuard autostart, x11vnc, node_exporter, and WorkMon settle cleanly:

   ```bash
   sudo reboot
   ```

10. From the admin node, verify Prometheus metrics and add the machine to targets:

   ```bash
   curl http://10.8.0.7:9100/metrics
   ```

## 8. Recovery notes

If internet disappears after boot, the full-tunnel peer probably was not configured server-side yet:

```bash
sudo systemctl disable --now wg-quick@wg0 wg-watchdog.timer
sudo wg-quick down wg0 || true
```

Then add the peer on the WireGuard server/firewall and re-enable autostart when ready.

x11vnc diagnostics:

```bash
systemctl status x11vnc --no-pager
ss -ltnp | grep :5900
journalctl -u x11vnc -n 100 --no-pager
```

Expected listener: the laptop's WireGuard IPv4 address only, not `0.0.0.0`.

node_exporter diagnostics:

```bash
systemctl status prometheus-node-exporter --no-pager
ss -ltnp | grep :9100
curl http://<laptop-wg-ip>:9100/metrics
```

Expected listener: the laptop's WireGuard IPv4 address only. If a killswitch default-drops input, allow:

```nft
iifname "wg0" tcp dport 9100 accept
```

WireGuard watchdog diagnostics:

```bash
journalctl -t wg-watchdog -n 30 --no-pager
systemctl list-timers wg-watchdog.timer
wg show wg0
```

Audio tunnel diagnostics, from the service user's XFCE session:

```bash
pactl list short modules | grep native-protocol-tcp
ss -ltnp | grep :4713
```

If a killswitch default-drops input, allow:

```nft
iifname "wg0" tcp dport 4713 accept
```

## 9. Typical problems

- No internet after reboot: WG autostart ran before the server-side peer existed. Disable `wg-quick@wg0` and `wg-watchdog.timer`, bring `wg0` down, add the peer, then re-enable.
- No audio on the VPS, or the VPS cannot reach the laptop audio server: the service user session is not running, WireGuard is down, or a killswitch blocks port `4713`.
- Microphone dead / no audio source in the session: the card started in output-only mode. Run `sudo ONLY=audioprio bash local-provision.sh`, then log the service user out and back in.
- Prometheus cannot reach the machine: tunnel is down, `prometheus-node-exporter` is retrying before `wg0` exists, or the killswitch blocks port `9100`.
- NoMachine shortcut opens bare `nxplayer`: no paired VPS was provided. Rerun `sudo ONLY=nm_shortcut NX_VPS_HOST=<vps-wg-ip> bash local-provision.sh`.
- Screen still blanks or locks for the service user: the `power` step ran while that user's session was live and `xfconfd` overwrote the XML on logout. Log the user out and rerun `sudo ONLY=power bash local-provision.sh`.
- XFCE asks to allow execution on the NoMachine shortcut: the one-shot trust autostart has not run yet; log in as the service user once.
- Incoming NoMachine connection shows a gray screen: NoMachine `node.cfg` was not set to XFCE; rerun `sudo ONLY=nomachine bash local-provision.sh`.

## 10. Security notes

- NoMachine server listens on port `4000`; do not expose it to the public internet.
- x11vnc listens only after `wg0` has an IPv4 address and binds to that address.
- node_exporter listens only on the WireGuard IP and port `9100`.
- The audio port `4713` listens on `0.0.0.0`, but PipeWire `auth-ip-acl` restricts clients to localhost and the WireGuard subnet. Do not widen the ACL or bind it publicly.
- The rollout log may mention temporary/default passwords. Keep `/var/log/local-provision.log` at `root:sudo 640` or stricter.
- `/etc/wireguard`, `/etc/x11vnc.pass`, `/etc/workmon`, and `/var/lib/workmon/spool` should remain root-owned with restricted permissions.
- The WorkMon worker agent has no private age key, no SMB credentials, and no outbound network access by design.

## 11. Golden image / clone cleanup

Before turning a provisioned laptop into a reusable image, remove machine-unique material:

```bash
sudo rm -f /etc/wireguard/client_private.key /etc/wireguard/client_public.key /etc/wireguard/wg0.conf
sudo rm -f /etc/x11vnc.pass
sudo rm -f /etc/machine-id
sudo truncate -s0 /etc/machine-id
sudo rm -f /var/lib/dbus/machine-id
sudo rm -f ~smm/.local/share/nomachine/VPS.nxs
```

`VPS.nxs` may contain the donor machine's paired VPS address and cached NoMachine trust/login data.

SSH host keys should be regenerated by the `ssh_hostkeys` step on the clone.

Then run provisioning on each clone with its own hostname, WireGuard address, paired VPS, and passwords.
