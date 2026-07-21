# vps-provision (Ansible)

Ansible port of `scripts/vps-provision.sh` v2.0 inside the larger department VPS/thin-client repository — initial provisioning of a work VPS:
XFCE + NoMachine + Firefox + Multilogin X + Telegram + WireGuard (client).
Users: `adams` (admin, sudo), `smm` (work, unprivileged).

Push model: the playbook runs from the admin laptop over SSH.

## One-time setup on the admin laptop

```bash
sudo apt install ansible sshpass          # sshpass is needed for -k (password SSH)
ansible-galaxy collection install -r requirements.yml
pip install passlib                       # only if password_hash complains (Python 3.13+)
```

1. Put `desktop-multiloginx-ubuntu-24.04-amd64.deb` into `roles/mlx/files/` locally. The `.deb` is intentionally ignored and not committed.
2. Create a real local Vault file from the committed template. The real `vault.yml` is ignored by git:
   ```bash
   cp group_vars/vps/vault.yml.example group_vars/vps/vault.yml
   ansible-vault encrypt group_vars/vps/vault.yml
   ```
3. Add your VPS to `inventory/hosts.yml` (real public IP + its unique
   `wg_address` from the selected tunnel range).

## Running

Full run on a fresh VPS (root + SSH password):

```bash
ansible-playbook site.yml -k --ask-vault-pass
```

Selected steps (after a failure / to finish one section — the analogue of
`sudo bash vps-provision.sh nomachine display`):

```bash
ansible-playbook site.yml -k --ask-vault-pass --tags nomachine,display
```

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
  are filled in `group_vars/vps/vars.yml`. Public repository defaults keep them empty. The public key is printed by the
  `wireguard` and `summary` steps — add it as a peer on the pfSense WG server.
* **Best-effort packages** (goodies, sound, fallback themes, guest agent)
  use `ignore_errors` — one missing package on a given distro does not abort
  the run.
* **NoMachine restart** happens exactly once, at the end of the `display`
  step, after `node.cfg` and the display stack are in place.
* **Not done by this playbook**: the firewall. NoMachine listens on port
  4000 on the public IP until you close it — connect via SSH tunnel or WG.

## After the first run

Once WireGuard is up you can switch the inventory to the tunnel address
(`ansible_host: 10.77.77.x`) and/or key-based SSH as `adams` with
`become`, and stop using `-k`.
