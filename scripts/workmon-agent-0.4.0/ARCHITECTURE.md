# WorkMon worker agent 0.4.0 — architecture

## Role

Capture only. The root daemon `workmon-capture.service` loops: finds the active local X11 session → `scrot` → SHA256 of the frame (skips byte-identical frames when `SKIP_IDENTICAL_FRAMES` is set) → `age` encrypts it with the public recipient → atomically drops the `.age` file into `/var/lib/workmon/spool` → rotation by `LOCAL_SPOOL_MAX_MB`. No networking.

## Data

```text
/opt/workmon/          common.py capture.py install.sh uninstall.sh README.md ARCHITECTURE.md systemd/
/etc/workmon/          workmon.conf asset_id public.key
/var/lib/workmon/tmp/    temporary plaintext PNG during the cycle (deleted immediately)
/var/lib/workmon/spool/  only *.age, root-only 0700
```

File name: `<asset-id>_<YYYY-MM-DD_HH-MM-SS>_<hostname>_<user>.png.age`.

## Collection (external)

The admin laptop pulls `spool/*.age` to itself over SSH+rsync (`--remove-source-files`) and decrypts it there with the single private key, then uploads the plaintext to SMB. The worker takes no part in this and never sees the private key. Details are in the `workmon-collect` package.

## Security on the worker

- Only the public key is present; there's nothing here that can decrypt locally.
- A single public recipient across all workers → one admin identity decrypts everything.
- `spool`, `/etc/workmon` — root-only 0700; the plaintext PNG never lingers on persistent disk.
- Unit: `NoNewPrivileges`, `ProtectSystem=full`, `ProtectHome=read-only`, `IPAddressDeny=any` (the agent never touches the network), `UMask=0077`.
- No masking, anti-removal, or self-healing.

## Differences from 0.3.0

Removed upload/decrypt, key-share, the private key, SMB, the upload timer, and all related config keys. Capture, dedup, X11 discovery, rotation, and transient logging are unchanged from 0.3.0. Added `IPAddressDeny=any`. Added `openssh-server` and `rsync` to dependencies for external collection.
