# thin-client-ansible

Ansible implementation of `local-provision.sh` v2.4.1. Push model: the playbook runs from the admin laptop and configures thin clients over SSH. A single run can provision the whole fleet in parallel.

## How this maps to the bash script

| Bash script | Ansible |
|---|---|
| `STEPS=(...)` + dispatcher | `site.yml` with a list of roles |
| `step_hostname`, `step_grub`, `step_upgrade`... | role `base` |
| `step_users`, `step_collect_key` | role `users` |
| `step_desktop` + `install_win10_look` | role `desktop` |
| `step_audio`, `step_audioprio` | role `audio` |
| `step_wireguard`, `step_watchdog` | role `wireguard` |
| `step_nomachine` | role `nomachine` |
| `step_x11vnc` | role `x11vnc` |
| `step_node_exporter` | role `node_exporter` |
| `step_power`, `step_nm_shortcut`, `step_win10_script` | role `svc_desktop` |
| `step_workmon` | role `workmon` (agent bundled, runs its `install.sh`) |
| `step_summary` | `post_tasks` in `site.yml` |
| `NEW_HOSTNAME=tc-05` | the hostname in `inventory/hosts.yml` |
| `WG_CLIENT_ADDR=10.8.0.5/24` | `inventory/host_vars/tc-05.yml` |
| the CONFIG block | `inventory/group_vars/thin_clients/vars.yml` |
| passwords in the config | `.../thin_clients/vault.yml.example` template → ignored encrypted `vault.yml` |
| `ONLY=wireguard,watchdog` | `--tags wireguard` |
| `set -euo pipefail` + `trap ERR` | Ansible's default behavior: a failed task stops the host |
| manual idempotency (`[ -f ... ]`, grep) | built into the modules; where there's no module — `creates:` |
| "one restart for all edits" | handlers + notify |
| `warn` and continue | `ignore_errors: true` or `block/rescue` |
| heredoc files | `files/` (static) and `templates/*.j2` (with variables) |

The key mindset shift: bash describes **what to do**, Ansible describes **how it should be**. A module compares the current state to the desired one and changes only what differs. That's why in the output each task is marked `ok` (already so) or `changed` (I changed it).

## Setup (once, on the admin laptop)

```bash
sudo apt install ansible          # or: pipx install ansible
cd ansible/thin-client
ansible-galaxy collection install -r requirements.yml   # authorized_key module

# Copy the secrets template, replace placeholders, then encrypt ignored vault.yml:
cp inventory/group_vars/thin_clients/vault.yml.example inventory/group_vars/thin_clients/vault.yml
ansible-vault encrypt inventory/group_vars/thin_clients/vault.yml
```

Requirements on the target machine (fresh Debian 13): `openssh-server` installed, `python3` present (Debian has it out of the box), the `adams` user able to `sudo`. Copy your SSH key: `ssh-copy-id adams@<LAN-IP>`.

## Running

```bash
# Check connectivity to all machines:
ansible all -m ping -K

# Dry run: show WHAT will change, without changing anything:
ansible-playbook site.yml -K --ask-vault-pass --check --diff --limit tc-05

# Real run for one machine:
ansible-playbook site.yml -K --ask-vault-pass --limit tc-05

# The whole fleet:
ansible-playbook site.yml -K --ask-vault-pass

# Selected roles only (equivalent of ONLY=):
ansible-playbook site.yml -K --ask-vault-pass --tags wireguard,x11vnc --limit tc-05
```

`-K` prompts for the sudo password of the `adams` user. Do not commit the real `vault.yml` or Vault password file. To avoid typing the Vault password every time, keep it outside git and pass `--vault-password-file ~/.vault_pass` (permissions `600`).

## Adding a new fleet machine

1. A line in `inventory/hosts.yml`: name (= future hostname) + `ansible_host` (LAN IP).
2. A file `inventory/host_vars/<name>.yml` with a unique `wg_client_addr`.
3. `ansible-playbook site.yml -K --ask-vault-pass --limit <name>`.
4. Take the client public key from the summary at the end of the run, add a `[Peer]` on the VPS, then on the laptop: `sudo wg-quick up wg0`.

## What lives where

```
ansible.cfg                    project settings (inventory, become)
site.yml                       main playbook: pre-checks, roles, summary
requirements.yml               external collections (ansible.posix)
inventory/
  hosts.yml                    the list of machines and how to connect
  group_vars/thin_clients/
    vars.yml                   the common config (the former CONFIG block)
    vault.yml.example          secrets template; copy to ignored encrypted vault.yml
  host_vars/tc-05.yml          per-machine (wg_client_addr)
roles/<name>/
  tasks/main.yml               the role's tasks
  handlers/main.yml            restarts "once at the end, if something changed"
  files/                       static files (copied as-is)
  templates/*.j2               Jinja2 templates (variables substituted)
```

## Notes and differences from the bash version

All behavior is preserved: the tunnel is not brought up during the run, passwords are not overwritten on reruns, WG keys are generated on the machine itself and reused, x11vnc listens only on wg0, units are enabled on boot without starting in the current session.

New in v2.4/v2.4.1 (ported from the script): the audio tunnel is fully automated — role `audio` drops `module-native-protocol-tcp` into the service user's `pipewire-pulse` config (`audio_tcp_port` / `audio_allowed_ips` in `vars.yml`) and a WirePlumber rule that forces the onboard card into duplex; role `node_exporter` binds Prometheus metrics to the wg address only (`node_exporter_*` vars); the desktop shortcut can open a ready-made fullscreen session to the paired VPS — set `nx_vps_host` in `host_vars/<name>.yml` (feature toggle `nx_connect_enable`).

Minor differences: the base role now leaves APT source configuration to the target OS or your site baseline and handles upgrade/package installation only. Backups of edits are made by Ansible itself (`backup: true`, i.e. timestamped copies next to the file) instead of a single `.orig`. The NoMachine shortcut icon is set as `Icon=nxplayer` instead of a `find` lookup — if the icon doesn't resolve, put an explicit path in `roles/svc_desktop/templates/nomachine.desktop.j2`. There's no more `/var/log/local-provision.log`: the full report is printed by Ansible itself on the admin laptop (enable `log_path` in `ansible.cfg` if you want a file).

`xfce-win10.sh` ships in `roles/svc_desktop/files/` and is copied to the user's desktop. The `workmon` role bundles `workmon-agent-0.4.0` and runs its own `install.sh` on the host (rerun-safe); on an agent upgrade, replace the directory under `roles/workmon/files/` and bump the version in `roles/workmon/tasks/main.yml`.

Careful with full-tunnel: as before, if the peer isn't added on the VPS, after reboot the machine will bring the tunnel up "to nowhere" and go offline — Ansible won't be able to reach it either. The order in the summary (`post_tasks`) is mandatory.

## Useful things to study (what to look for in the code)

Idempotency without a module — `creates:` (WG key generation, `x11vnc -storepasswd`). Handlers — `roles/base/handlers` + `notify` (one `update-grub` for three GRUB edits). Templates — `wg0.conf.j2` + `slurp`/`b64decode` (the key is read from the target machine, not the admin laptop). Secrets — `no_log: true` on tasks with passwords/keys. Conditionals — `block`/`when` (x11vnc), `block`/`rescue` (best-effort theme), `assert` (pre-checks). "Don't overwrite what exists" — `update_password: on_create` (user password), `force: false` (user-dirs.dirs), `creates:` (VNC password).
