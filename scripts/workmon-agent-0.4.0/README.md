# WorkMon worker agent 0.4.0 (Debian 13 + Xfce/X11)

A slim agent for **remote work laptops**. Takes screenshots of the X11 session, immediately encrypts them with a single shared `age` public key, and drops the `.age` files into a root-only spool at `/var/lib/workmon/spool`. Nothing else: **no networking, no decryption, no private key, no SMB**.

Collection and decryption happen separately, from the admin laptop (the `workmon-collect` package), where the single private key lives.

## 1. Compliance

Company-owned equipment only, under an approved monitoring policy, a legal basis, and employee notice. The agent doesn't mask itself, resist removal, self-heal, or send data anywhere — it doesn't touch the network at all (`IPAddressDeny=any` is set in the unit). Screenshots every 5 seconds is dense monitoring; align the proportionality, retention period, and notice with your legal team (for UA — the Law "On Personal Data Protection"; under an EU nexus — GDPR). This is not legal advice.

## 2. Key model (important)

The private key exists **in a single copy — on the admin laptop**. **The same public recipient** is rolled out to every worker, so a single identity of yours decrypts screenshots from all machines. Compromising any worker (even with escalation to root) doesn't expose a single screenshot — there's nothing on the worker that can decrypt them.

```bash
# Once, on the admin laptop:
age-keygen -o private.key                 # private key — stays only here
age-keygen -y private.key > public.key    # public recipient — goes to every worker
```

## 3. Installation (on each worker)

```bash
cd workmon-agent
sudo ./install.sh            # or: sudo ./install.sh --dry-run
```

Then deploy the shared public key and (re)start capture:

```bash
sudo install -o root -g root -m 0600 public.key /etc/workmon/public.key
sudo systemctl restart workmon-capture.service
```

The installer installs dependencies (including `openssh-server` and `rsync` for collection), creates the directories, installs the unit, and enables `workmon-capture.service`.

## 4. Access for the admin laptop (SSH collection)

The collector reads a root-only spool, so it connects either as `root` or as a sudo user.

```bash
# Option A: key-based root access (in sshd_config: PermitRootLogin prohibit-password)
sudo mkdir -p /root/.ssh && sudo chmod 700 /root/.ssh
echo 'ssh-ed25519 AAAA... admin-collector' | sudo tee -a /root/.ssh/authorized_keys
sudo chmod 600 /root/.ssh/authorized_keys
```

A dedicated key used only for collection is recommended. You can optionally restrict it in `authorized_keys` via `rrsync` (read-only on `/var/lib/workmon/spool`), but then cleaning up the source files has to be left to rsync itself (`--remove-source-files`), which is what the collector does.

## 5. Asset ID and hostname

```bash
sudo hostnamectl set-hostname work-laptop-014
echo "work-laptop-014" | sudo tee /etc/workmon/asset_id
```

File names: `<asset-id>_<YYYY-MM-DD_HH-MM-SS>_<hostname>_<user>.png.age`.

## 6. Configuration

`/etc/workmon/workmon.conf` — capture settings only: `SCREENSHOT_INTERVAL_SECONDS`, `LOCAL_SPOOL_MAX_MB`, `PUBLIC_KEY_FILE`, `SKIP_IDENTICAL_FRAMES`, `GUI_USER`, `CAPTURE_BACKEND`.

`LOCAL_SPOOL_MAX_MB` — a safeguard against filling up the disk between collection runs: once exceeded, the oldest `.age` files are deleted (the earliest frames are lost). Set it with headroom for the longest expected offline period between your connections.

## 7. Verification

```bash
systemctl status workmon-capture.service
journalctl -u workmon-capture.service -f
sudo find /var/lib/workmon/spool -maxdepth 1 -name '*.age' -printf '%TY-%Tm-%Td %TH:%TM %s %p\n'
# no plain PNGs should remain on disk:
sudo find /var/lib/workmon -name '*.png' -type f
```

## 8. Removal

```bash
sudo /opt/workmon/uninstall.sh            # keep config and spool
sudo /opt/workmon/uninstall.sh --purge    # remove everything
```
