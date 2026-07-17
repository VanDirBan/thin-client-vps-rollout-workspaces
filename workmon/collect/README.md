# workmon-collect 0.1.3 (admin laptop)

Pulls encrypted `.age` screenshots from remote workers over **SSH+rsync**, decrypts them **locally with a single private key**, and uploads the resulting PNGs to an SMB share. The private key exists only on this machine.

## What is new in 0.1.3

- **Live interactive progress.** TTY runs now show one-line counters for worker pull and SMB upload phases, throttled to about once per second.
- **Remote spool counts.** The initial SSH probe also counts remote `*.age` files, so progress can show a denominator when the worker is reachable.
- **Per-host final summary.** The end of each run now reports uploaded, failed, dropped, unreachable, and skipped hosts in one compact summary.
- **Streaming rsync output.** Real pulls use streamed rsync output and a watchdog that kills the whole rsync/SSH process group on overall timeout.

## What was new in 0.1.2

- **Fixed mount detection (critical).** The mount-point check used `findmnt --target`, which returns the parent mount (`/`) for a plain directory and produced a false "already mounted" result. That could leave the share unmounted and write plaintext PNGs to the laptop's local disk instead of the NAS. The collector now uses `--mountpoint` for an exact test and hard-fails if the mount point is not active after `mount`.

## What was new in 0.1.1

- **Manual execution only.** systemd units (service/timer) were removed, so operators control exactly when collection runs.
- **Folder name from the worker hostname.** If the second column in `hosts` is omitted, the receiving folder is named after the worker's `hostname -s`; those names are made unique during hardware provisioning. A single SSH connection checks reachability and fetches the name.
- **Protection against mixing.** Explicit duplicate assets in `hosts` are a startup error. If two workers resolve to the same name, the second one is skipped with an error instead of being merged into someone else's folder.
- **Single-instance lock.** Two real runs cannot overlap; two `rsync --remove-source-files` calls against the same spool could corrupt data.
- **PNG verification.** After decryption the PNG signature is checked; anything that decrypts into garbage is not uploaded. The file stays in staging and is reported on every run.
- **Warnings for config typos.** Unknown keys such as `REMOT_USER` are logged instead of silently falling back to defaults.

## Diagram

```
worker N:  /var/lib/workmon/spool/*.age   ──ssh+rsync──▶  admin: staging/<asset>/*.age
                                                                    │  age --decrypt (private.key, only here)
                                                                    ▼
                                            SMB //smb.example.local/workmon-screenshots/out/<YYYY-MM-DD>/<asset>/*.png
```

A single run goes through all hosts in `hosts`. Unreachable hosts are logged and skipped instead of failing the whole run. Each host is processed completely (pull → decrypt → upload → free staging) before moving to the next one, keeping memory and disk usage bounded.

## Cleanup on the worker

rsync runs with `--remove-source-files`: only **successfully transferred** files are removed on the worker. Screenshots that appear during transfer stay on the worker and are collected next time. There is no `rm -rf` against the spool directory. After transfer to admin, the only copy is in `staging`; it is deleted or archived only after confirmed SMB upload with size verification. If upload fails, the `.age` file stays in `staging` and is retried on the next run.

## Installation

```bash
cd workmon-collect
sudo ./install.sh          # or: sudo ./install.sh --dry-run
```

Installs dependencies (`openssh-client`, `rsync`, `cifs-utils`, `age`), places the code in `/opt/workmon-collect`, creates config/templates and the `workmon-collect` symlink, and generates the SSH collection key `/etc/workmon-collect/id_collect` if it does not already exist. Deploy the public half to the workers.

## Setup

1. **The private age key — goes only here:**
   ```bash
   sudo age-keygen -o /etc/workmon-collect/private.key
   sudo chmod 600 /etc/workmon-collect/private.key
   # the public recipient for all workers:
   sudo age-keygen -y /etc/workmon-collect/private.key | sudo tee public.key
   ```
   As a safety net, put a backup copy of `private.key` on SMB — but use a **separate access-restricted share**, not the share where screenshots are uploaded.
2. **Hosts:** `/etc/workmon-collect/hosts`, lines of `<host> [asset_id]`. The second column is optional: without it, the folder name is taken from the worker's `hostname -s` (make hostnames unique during provisioning). The second column is only for forcing an override. Names must be unique: duplicates are caught so screenshots from different machines cannot be mixed.
   ```
   10.10.0.11               # folder = worker hostname
   10.10.0.12
   10.10.0.20  special-kiosk # folder manually overridden
   ```
3. **SMB creds:** `/etc/workmon-collect/smb.credentials` (read/write account for the screenshot share). mount.cifs format: `username=`, `password=`, `domain=`. The password is read **verbatim to the end of the line, with no quotes** — write special characters (`# $ , "`) as-is. If the password used to live in a quoted shell script string (`"...#$3"`), those quotes were shell escaping; do **not** put them here or they become part of the password.
4. **SSH access:** deploy `/etc/workmon-collect/id_collect.pub` to the workers (root `authorized_keys`, or a sudo-capable user with `REMOTE_SUDO=true` in config).

## Running

```bash
sudo workmon-collect --dry-run     # reachability + file count/listing, no changes
sudo workmon-collect               # pull → decrypt → upload
sudo workmon-collect --host 10.10.0.11   # only one host
sudo workmon-collect --no-remove   # do not delete source files on workers (diagnostics)
```

Exit codes: `0` — all clean; `2` — some hosts were unreachable or file errors occurred (expected retry case); `1` — fatal local/config error such as missing key/credentials/programs, failed share mount, or another run already in progress.

Manual execution only — no schedule or background service is installed.

## Key configuration

`REMOTE_USER` / `REMOTE_SUDO` — how to connect to a worker (root or sudo user). `REMOTE_SPOOL` — worker spool path. `PRIVATE_KEY_FILE` — private age key (only here). `DELETE_STAGED_AFTER_UPLOAD` — delete `.age` from staging after upload (`false` archives it in `PROCESSED_DIR`). `SMB_VERSION=3.1.1` + `SMB_SEAL=true` — encrypted SMB channel.

## Security

- The private age key and SSH collection key live only on the admin laptop, root-only `0600`.
- Plaintext PNGs live only in `/run/workmon-collect/decrypted` (tmpfs) and are removed after each file.
- `staging` stores only `.age` files (encrypted), root-only.
- The SMB channel is encrypted (`seal`).
- `--purge` during uninstall removes the private key too — do not run it until you have a backup copy.
