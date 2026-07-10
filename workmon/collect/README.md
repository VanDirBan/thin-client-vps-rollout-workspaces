# workmon-collect 0.1.2 (admin laptop)

Pulls encrypted `.age` screenshots from remote workers over **SSH+rsync**, decrypts them **locally with a single private key**, and uploads the resulting PNGs to an SMB share. The private key exists only on this machine.

## What's new in 0.1.2

- **Fixed mount detection (critical).** The mount-point check used `findmnt --target`, which for a plain directory returns the parent mount (`/`) and produced a false "already mounted" → the share never got mounted, and plaintext PNGs were written to the laptop's local disk instead of the NAS. Now uses `--mountpoint` (an exact test) plus a hard check that the mount point actually came up after `mount`, otherwise the run fails.

## What's new in 0.1.1

- **Manual execution only.** systemd units (service/timer) have been removed — full control over when it runs.
- **Folder name from the worker's hostname.** If the second column of `hosts` doesn't specify a name, the receiving folder is named after the worker's `hostname -s` (names are made unique during hardware provisioning). A single SSH connection both checks reachability and pulls the name.
- **Protection against mixing.** Explicit duplicate assets in `hosts` are a startup error; if two workers resolve to the same name, the second one is skipped with an error instead of being merged into someone else's folder.
- **Single-instance lock.** Two real runs can't overlap (otherwise two `rsync --remove-source-files` calls against the same spool could corrupt data).
- **PNG verification.** After decryption the signature is checked; anything that "decrypted into garbage" won't be uploaded to the share — the file stays in staging and shows up in the log on every run.
- **Warning for config typos.** An unrecognized key (e.g. `REMOT_USER`) is logged instead of silently falling back to the default.

## Diagram

```
worker N:  /var/lib/workmon/spool/*.age   ──ssh+rsync──▶  admin: staging/<asset>/*.age
                                                                    │  age --decrypt (private.key, only here)
                                                                    ▼
                                            SMB //smb.example.local/workmon-screenshots/out/<asset>/<YYYY-MM-DD>/*.png
```

A single run goes through all hosts in `hosts`. Unreachable hosts are logged and skipped (they don't fail the run). Each host is processed completely (fetch → decrypt → upload → clear staging) before moving to the next, so memory/disk usage doesn't grow unbounded.

## Cleanup on the worker

rsync runs with `--remove-source-files`: only **successfully transferred** files are removed on the worker. Screenshots that appear during the transfer are left alone and picked up next time. There's no `rm -rf` on the folder at all. After the transfer to admin, the only copy lives in `staging`; it's deleted/archived only after a confirmed upload to the share (size verification). If the upload fails, the `.age` file stays in `staging` and is retried on the next run.

## Installation

```bash
cd workmon-collect
sudo ./install.sh          # or: sudo ./install.sh --dry-run
```

Installs dependencies (`openssh-client`, `rsync`, `cifs-utils`, `age`), places the code in `/opt/workmon-collect`, creates config/templates, a `workmon-collect` symlink, and (if it doesn't already exist) generates an SSH key `/etc/workmon-collect/id_collect` for collection — the public part needs to be distributed to the workers.

## Setup

1. **The private age key — goes only here:**
   ```bash
   sudo age-keygen -o /etc/workmon-collect/private.key
   sudo chmod 600 /etc/workmon-collect/private.key
   # the public recipient for all workers:
   sudo age-keygen -y /etc/workmon-collect/private.key | sudo tee public.key
   ```
   As a safety net, put a copy of `private.key` on SMB — but set up a **separate, access-restricted share** for it, not the one screenshots get uploaded to.
2. **Hosts:** `/etc/workmon-collect/hosts`, lines of `<host> [asset_id]`. The second column is optional: without it, the folder name is taken from the worker's `hostname -s` (make the hostname unique during provisioning). The second column is only for forcing an override. Names must be unique: duplicates are caught and prevent screenshots from different machines being mixed together.
   ```
   10.10.0.11               # folder = worker's hostname
   10.10.0.12
   10.10.0.20  special-kiosk # folder overridden manually
   ```
3. **SMB creds:** `/etc/workmon-collect/smb.credentials` (an rw account for the screenshot share). mount.cifs format: `username=`, `password=`, `domain=`. The password is read **verbatim to the end of the line, with no quotes** — write special characters (`# $ , "`) as-is. If the password previously lived in a shell script inside quotes (`"...#$3"`), that was shell escaping — you do **not** need to put quotes here, or they'll become part of the password.
4. **SSH access:** distribute `/etc/workmon-collect/id_collect.pub` to the workers (root's authorized_keys, or a sudo user + `REMOTE_SUDO=true` in the config).

## Running it

```bash
sudo workmon-collect --dry-run     # host reachability + how many files would be pulled, no changes
sudo workmon-collect               # fetch → decrypt → upload
sudo workmon-collect --host 10.10.0.11   # only one host
sudo workmon-collect --no-remove   # don't delete source files on the workers (diagnostics)
```

Exit codes: `0` — all clean; `2` — some hosts were unreachable or there were file errors (normal, will retry); `1` — fatal (missing key/credentials/programs, the share didn't mount, or another run is already in progress).

Execution is manual only — nothing is scheduled or running in the background.

## Config (the essentials)

`REMOTE_USER` / `REMOTE_SUDO` — how to log in to the worker (root or a sudo user). `REMOTE_SPOOL` — the spool path on the worker. `PRIVATE_KEY_FILE` — the private key (only here). `DELETE_STAGED_AFTER_UPLOAD` — delete `.age` from staging after upload (`false` → archive to `PROCESSED_DIR`). `SMB_VERSION=3.1.1` + `SMB_SEAL=true` — an encrypted SMB channel.

## Security

- The private key and the collection SSH key live only on the admin laptop, root-only 0600.
- The plaintext PNG only lives in `/run/workmon-collect/decrypted` (tmpfs) and is wiped after each file.
- `staging` only holds `.age` files (encrypted), root-only.
- The SMB channel is encrypted (`seal`).
- `--purge` on removal also wipes the private key — don't run with `--purge` until you've saved a copy.
