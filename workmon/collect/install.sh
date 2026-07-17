#!/usr/bin/env bash
set -euo pipefail

# workmon-collect 0.1.3 installer (admin laptop, Debian 13).
# Pulls encrypted screenshots from workers, decrypts locally, pushes to SMB.
# Manual run only (no systemd units installed).

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
fi

if [[ ${EUID} -ne 0 ]]; then
  echo "install.sh must be run as root" >&2
  exit 1
fi

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    printf '[dry-run]'; printf ' %q' "$@"; printf '\n'
  else
    "$@"
  fi
}

write_file() {
  local target="$1" mode="$2" owner="$3" group="$4" tmp
  tmp="$(mktemp)"; cat > "$tmp"
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[dry-run] create ${target} mode=${mode} owner=${owner}:${group}"; rm -f "$tmp"
  else
    install -o "$owner" -g "$group" -m "$mode" "$tmp" "$target"; rm -f "$tmp"
  fi
}

if ! command -v apt-get >/dev/null 2>&1; then
  echo "apt-get not found. This installer targets Debian 13." >&2
  exit 1
fi

[[ "${DRY_RUN}" == "true" ]] && echo "Dry-run mode: no changes will be made."

echo "Installing collector dependencies..."
run apt-get update
run env DEBIAN_FRONTEND=noninteractive apt-get install -y \
  python3 \
  openssh-client \
  rsync \
  cifs-utils \
  age \
  util-linux

echo "Creating directories..."
run install -d -o root -g root -m 0755 /opt/workmon-collect
run install -d -o root -g root -m 0700 /etc/workmon-collect
run install -d -o root -g root -m 0700 /var/lib/workmon-collect/staging
run install -d -o root -g root -m 0700 /var/lib/workmon-collect/processed
run install -d -o root -g root -m 0700 /mnt/workmon-screenshots
if [[ "${DRY_RUN}" != "true" ]] && [[ ! -f /var/lib/workmon-collect/known_hosts ]]; then
  install -o root -g root -m 0600 /dev/null /var/lib/workmon-collect/known_hosts
fi

echo "Installing project files..."
run install -o root -g root -m 0644 "${SRC_DIR}/collect_common.py" /opt/workmon-collect/collect_common.py
run install -o root -g root -m 0755 "${SRC_DIR}/collect.py" /opt/workmon-collect/collect.py
run install -o root -g root -m 0644 "${SRC_DIR}/README.md" /opt/workmon-collect/README.md
run install -o root -g root -m 0755 "${SRC_DIR}/install.sh" /opt/workmon-collect/install.sh
run install -o root -g root -m 0755 "${SRC_DIR}/uninstall.sh" /opt/workmon-collect/uninstall.sh

# Symlink for convenient invocation: workmon-collect ...
if [[ "${DRY_RUN}" != "true" ]]; then
  ln -sf /opt/workmon-collect/collect.py /usr/local/bin/workmon-collect
fi

if [[ ! -f /etc/workmon-collect/collect.conf ]]; then
  echo "Creating default /etc/workmon-collect/collect.conf"
  write_file /etc/workmon-collect/collect.conf 0600 root root <<'CONF'
# workmon-collect 0.1.3 configuration (admin laptop).

HOSTS_FILE=/etc/workmon-collect/hosts

# --- Collection over SSH ---
REMOTE_USER=root
# If you connect NOT as root but as a sudo user — enable this:
REMOTE_SUDO=false
REMOTE_SPOOL=/var/lib/workmon/spool
SSH_KEY=/etc/workmon-collect/id_collect
SSH_CONNECT_TIMEOUT=8
SSH_STRICT_HOST_KEY=accept-new
SSH_KNOWN_HOSTS=/var/lib/workmon-collect/known_hosts
SSH_EXTRA_OPTS=
RSYNC_IO_TIMEOUT_SECONDS=120
RSYNC_TIMEOUT_SECONDS=1800

# --- Local paths on the admin laptop ---
# The ONLY decryption private key. Keep it only here.
PRIVATE_KEY_FILE=/etc/workmon-collect/private.key
STAGING_DIR=/var/lib/workmon-collect/staging
PROCESSED_DIR=/var/lib/workmon-collect/processed
DECRYPT_TMP_DIR=/run/workmon-collect/decrypted
DELETE_STAGED_AFTER_UPLOAD=true

# --- SMB receiver (plaintext screenshots) ---
SHARE_HOST=smb.example.local
SCREENSHOT_SHARE=//smb.example.local/workmon-screenshots
MOUNT_POINT_SCREENSHOTS=/mnt/workmon-screenshots
SMB_CREDENTIALS=/etc/workmon-collect/smb.credentials
SMB_VERSION=3.1.1
SMB_SEAL=true
CIFS_EXTRA_OPTIONS=
REMOTE_OUTPUT_DIR=out

MOUNT_TIMEOUT_SECONDS=15
COMMAND_TIMEOUT_SECONDS=120
LOG_LEVEL=INFO
CONF
fi

if [[ ! -f /etc/workmon-collect/hosts ]]; then
  echo "Creating template /etc/workmon-collect/hosts"
  write_file /etc/workmon-collect/hosts 0600 root root <<'HOSTS'
# One worker per line: <host_or_wg_ip> [asset_id]
# asset_id is OPTIONAL. If not set — the receiving folder name is taken from the
# worker's own hostname (short name, `hostname -s`), which you make unique per
# user during hardware provisioning. The second column is only needed to
# force an override.
# Example (just WG addresses, names will come from the workers' hostnames):
# 10.10.0.11
# 10.10.0.12
# 10.10.0.13
# Example with an explicit override:
# 10.10.0.20   special-kiosk
HOSTS
fi

# SMB creds for mounting the screenshot share. mount.cifs file format:
#   username=<user>
#   password=<pass>
#   domain=<workgroup>      # optional; usually WORKGROUP for NAS/Samba
# IMPORTANT about the password:
#   * the value is read VERBATIM to the end of the line — WITH NO quotes;
#   * write special characters (# $ , " etc.) as-is, no escaping/wrapping needed
#     (the kernel reads this file, the shell never parses it);
#   * if the password used to be quoted in an old shell script (for example "example,...#$3"),
#     those quotes were shell escaping — do NOT put them in this file,
#     or the quotes will become part of the password and mounting will fail.
# Example credentials file:
#   username=CHANGE_ME
#   password=CHANGE_ME_WITH_SPECIAL_CHARS#$3
#   domain=WORKGROUP
# The file must be root:root 0600 (set automatically below).
if [[ ! -f /etc/workmon-collect/smb.credentials ]]; then
  echo "Creating template /etc/workmon-collect/smb.credentials (fill username/password, no quotes)"
  write_file /etc/workmon-collect/smb.credentials 0600 root root <<'CRED'
username=CHANGE_ME
password=CHANGE_ME
domain=WORKGROUP
CRED
fi

# SSH key for collection: generate it if it does not exist (private key stays only here).
if [[ ! -f /etc/workmon-collect/id_collect ]]; then
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[dry-run] ssh-keygen -t ed25519 -N '' -C workmon-collect -f /etc/workmon-collect/id_collect"
  else
    ssh-keygen -t ed25519 -N '' -C "workmon-collect" -f /etc/workmon-collect/id_collect >/dev/null
    chmod 600 /etc/workmon-collect/id_collect
    chmod 644 /etc/workmon-collect/id_collect.pub
    echo
    echo "Generated SSH key for collection. Deploy this PUBLIC key to each worker"
    echo "(root's authorized_keys, or a sudo-capable user):"
    echo "----------------------------------------------------------------------"
    cat /etc/workmon-collect/id_collect.pub
    echo "----------------------------------------------------------------------"
  fi
fi

if [[ ! -s /etc/workmon-collect/private.key ]]; then
  echo "WARNING: /etc/workmon-collect/private.key is missing." >&2
  echo "This is the single age identity that decrypts ALL workers. Install it here only:" >&2
  echo "  age-keygen -o /etc/workmon-collect/private.key && chmod 600 /etc/workmon-collect/private.key" >&2
  echo "Then derive the public recipient for the workers:" >&2
  echo "  age-keygen -y /etc/workmon-collect/private.key > public.key" >&2
fi

if [[ "${DRY_RUN}" != "true" ]]; then
  chown -R root:root /opt/workmon-collect /etc/workmon-collect /var/lib/workmon-collect
  chmod 0755 /opt/workmon-collect
  find /opt/workmon-collect -type f -exec chmod 0644 {} \;
  chmod 0755 /opt/workmon-collect/collect.py /opt/workmon-collect/install.sh /opt/workmon-collect/uninstall.sh
  chmod 0700 /etc/workmon-collect /var/lib/workmon-collect /var/lib/workmon-collect/staging /var/lib/workmon-collect/processed /mnt/workmon-screenshots
  chmod 0600 /etc/workmon-collect/collect.conf /etc/workmon-collect/hosts /etc/workmon-collect/smb.credentials
  [[ -f /etc/workmon-collect/private.key ]] && chmod 0600 /etc/workmon-collect/private.key || true
fi

cat <<'NOTE'

workmon-collect installed. Manual run only:
  sudo workmon-collect --dry-run     # check reachability, names, and what would be pulled
  sudo workmon-collect               # fetch, decrypt, upload to the share
  sudo workmon-collect --host 10.10.0.11   # only one host
  sudo workmon-collect --no-remove   # do not delete source files on workers (diagnostics)

Before first real run:
  1) put the age private key at /etc/workmon-collect/private.key (chmod 600),
  2) fill /etc/workmon-collect/hosts and /etc/workmon-collect/smb.credentials,
  3) deploy /etc/workmon-collect/id_collect.pub to every worker.
NOTE
