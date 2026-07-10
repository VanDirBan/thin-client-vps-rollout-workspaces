# Department VPS Workflows

Work-in-progress repository for the department VPS/thin-client workflow migration project.

Full project documentation will be written after all source files and scripts are imported.

## Current contents

- `scripts/local-provision.sh` — fleet-aware local physical laptop provisioning script for the thin-client side. It prepares Debian 13/XFCE, NoMachine, WireGuard, audio support, desktop shortcuting, hostname setup, and WorkMon agent installation hooks.
- `scripts/vps-provision.sh` — initial VPS rollout script for the working desktop side: XFCE, NoMachine, Firefox, Multilogin X, Telegram, WireGuard tooling, users, display stack, and desktop shortcuts.
- `scripts/xfce-win10.sh` — user-session script applied after provisioning to make XFCE look and behave closer to Windows 10.
- `scripts/admin/copy_key.sh` — admin-side helper that copies the WorkMon collector `public.key` to a worker over SSH.
- `env/local-provision.env.example` — example environment variables for per-machine values, sensitive values, and site-specific infrastructure settings.
- `env/vps-provision.env.example` — example environment variables for VPS users, initial passwords, timezone, and NoMachine package pin.
