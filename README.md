# Department VPS Workflows

Work-in-progress repository for the department VPS/thin-client workflow migration project.

Full project documentation will be written after all source files and scripts are imported.

## Current contents

- `scripts/local-provision.sh` — fleet-aware local physical laptop provisioning script for the thin-client side. It prepares Debian 13/XFCE, NoMachine, WireGuard, audio support, desktop shortcuting, hostname setup, and WorkMon agent installation hooks.
- `env/local-provision.env.example` — example environment variables for per-machine values, sensitive values, and site-specific infrastructure settings.
