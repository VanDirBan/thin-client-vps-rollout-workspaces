# vps-provision (Ansible)

Ansible release v2.3.2, based on `scripts/vps-provision.sh` v2.3 inside the larger department VPS/thin-client repository — initial provisioning of a work VPS:
XFCE + NoMachine + Firefox + Multilogin X + Telegram + Teams (teams-for-linux)
+ WireGuard (client) + audio tunnel to the paired thin client + node_exporter
(wg-only) + no-lock/no-blank session.
Users: `adams` (admin, sudo), `smm` (work, unprivileged).

Push model: the playbook runs from the admin laptop over SSH.

## One-time setup on the admin laptop

```bash
sudo apt install ansible sshpass          # sshpass is needed for password SSH
ansible-galaxy collection install -r requirements.yml
pip install passlib                       # only if password_hash complains (Python 3.13+)
```

1. Put `desktop-multiloginx-ubuntu-24.04-amd64.deb` into `roles/mlx/files/` locally. The `.deb` is intentionally ignored and not committed.
2. Create a real local Vault file from the committed template. Fill the
   per-host root passwords in `vault_root_pass` and the two user passwords.
   The real `vault.yml` is ignored by git:
   ```bash
   cp group_vars/vps/vault.yml.example group_vars/vps/vault.yml
   ansible-vault encrypt group_vars/vps/vault.yml
   ```
3. Add your VPS to `inventory/hosts.yml`: public IP, its unique
   `wg_address` from the 10.77.77.101-200 range, and `audio_laptop_ip` —
   the wg address of the PAIRED laptop (10.77.77.6-99). Leave
   `audio_laptop_ip` empty to skip the audio tunnel on that host.

## Running

Full run on a fresh VPS. The root password is selected from
`vault_root_pass` by inventory hostname, so no `-k` prompt is needed:

```bash
ansible-playbook site.yml --ask-vault-pass
```

Selected steps (after a failure / to finish one section — the analogue of
`sudo bash vps-provision.sh nomachine display`):

```bash
ansible-playbook site.yml --ask-vault-pass --tags nomachine,display
```

## Dry run (`--check`) against a live reference machine

A no-op audit of an already-provisioned VPS:

```bash
ansible-playbook site.yml --ask-vault-pass --check --diff --limit vps-199
```

Read-only probes run during check mode because later conditionals need their
results. Package/full-upgrade drift and the unconditional display restart can
still be reported as changes. Install blocks that need temporary files do not
run in check mode; they print an explicit `CHECK: would install ...` message.

On a real re-run, the `display` role restarts LightDM and NoMachine and ends
the active GUI session. Use `--skip-tags display` unless that restart is needed.

List all steps/tags:

```bash
ansible-playbook site.yml --list-tags
```

Steps run in the canonical order regardless of how tags are listed.
The `preflight` role is tagged `always` and runs every time.

## Behaviour notes (same semantics as the shell script)

* **Idempotent**: a re-run does not break what is already done.
* **Passwords** are set only on user creation (`update_password: on_create`);
  a re-run never rolls back manually changed passwords.
* **WireGuard**: the key pair is always generated; `wg0.conf` is written and
  the tunnel started only when `wg_server_pubkey` and `wg_server_endpoint`
  are filled in `group_vars/vps/vars.yml`. Public repository defaults keep
  them empty. The public key is printed by the `wireguard` and `summary` steps — add it as a peer on the pfSense WG server.
* **Best-effort packages** (goodies, sound, fallback themes, guest agent)
  use `ignore_errors` — one missing package on a given distro does not abort
  the run.
* **NoMachine restart** happens exactly once, at the end of the `display`
  step, after `node.cfg` and the display stack are in place. `node.cfg` gets
  `AudioInterface disabled`: the NX audio channel is muted on purpose — all
  sound goes through the separate PipeWire tunnel (`audio` role).
* **Audio tunnel** (`audio` role): a user-level `audio-tunnel.service` in the
  `smm` session keeps `module-tunnel-sink/source` pointed at the paired
  laptop's PipeWire (`audio_laptop_ip:4713`) and re-creates them on breaks.
  A "Restart sound" button lands on the desktop for manual recovery.
* **node_exporter** (`node_exporter` role): binds ONLY to the wg address
  from `wg_address`. Until wg0 is up the bind fails and systemd retries
  every 5s (drop-in) — the service comes up by itself after the tunnel.
* **nolock** (`nolock` role): purges screen lockers and disables
  blanking/DPMS for the work session — a remote desktop must never lock.
* **Network policy**: pfSense manages perimeter firewall rules and WireGuard
  server peers outside this playbook. NoMachine and SSH access is restricted
  to WireGuard or approved management networks.

## After the first run

Once WireGuard is up you can switch the inventory to the tunnel address
(`ansible_host: 10.77.77.x`) and/or key-based SSH as `adams` with
`become`. Override `ansible_user`/`ansible_password` for that host and remove
its no-longer-needed entry from `vault_root_pass`.
