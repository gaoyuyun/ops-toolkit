#!/usr/bin/env bash

ops_ssh_help() {
  cat <<'EOF'
Usage: opsctl ssh harden [--port PORT|auto] [--yes] [--dry-run]

Installs an OpenSSH drop-in that disables password and root login. Always
keeps public-key authentication enabled and validates sshd before reloading.
EOF
}

ops_ssh_reload() {
  if ops_has systemctl && systemctl is-active ssh >/dev/null 2>&1; then
    systemctl reload ssh
  elif ops_has systemctl && systemctl is-active sshd >/dev/null 2>&1; then
    systemctl reload sshd
  elif ops_has rc-service; then
    rc-service sshd reload
  else
    ops_warn 'Could not reload sshd automatically.'
  fi
}

ops_ssh_harden() {
  local -a args
  local port=$OPS_DEFAULT_SSH_PORT etc_root target_dir target backup='' temp
  ops_parse_safety_flags args "$@"
  set -- "${args[@]}"
  while (($#)); do
    case $1 in
      --port)
        (($# >= 2)) || ops_die '--port requires a value'
        port=$2
        shift 2
        ;;
      *) ops_die "Unknown ssh option: $1" ;;
    esac
  done
  if [[ $port == auto ]]; then
    while true; do
      if ops_has shuf; then port=$(shuf -i 30000-60000 -n 1); else port=$(((RANDOM % 30001) + 30000)); fi
      if ops_has ss; then ss -lntH | awk '{print $4}' | grep -qE "(:|\\])${port}$" || break; else break; fi
    done
  fi
  ops_validate_port "$port" || ops_die 'SSH port must be between 1 and 65535.'
  ops_confirm "Install SSH hardening on port $port? Keep an existing session open."
  ops_require_root_unless_dry_run
  etc_root=${OPS_ETC_ROOT:-/etc}
  target_dir=$etc_root/ssh/sshd_config.d
  target=$target_dir/90-ops-toolkit.conf
  if ((OPS_DRY_RUN)); then
    ops_run install -d -m 0755 "$target_dir"
    ops_run install -m 0644 /dev/null "$target"
    ops_log 'Would validate sshd and reload the service.'
    return 0
  fi
  ops_ensure_commands 'SSH hardening' 'sshd|openssh-server|openssh'
  if ! grep -Eq '^[[:space:]]*Include[[:space:]]+.*/?sshd_config\.d/\*\.conf' "$etc_root/ssh/sshd_config"; then
    ops_die 'sshd_config does not include sshd_config.d/*.conf; refusing an ineffective change.'
  fi
  temp=$(mktemp)
  printf '%s\n' \
    '# Managed by ops-toolkit.' \
    "Port $port" \
    'PermitRootLogin prohibit-password' \
    'PasswordAuthentication no' \
    'KbdInteractiveAuthentication no' \
    'PubkeyAuthentication yes' \
    'AuthorizedKeysFile .ssh/authorized_keys' >"$temp"
  install -d -m 0755 "$target_dir"
  if [[ -f $target ]]; then
    backup=$target.bak.$(date +%s)
    cp -p "$target" "$backup"
  fi
  install -m 0644 "$temp" "$target"
  rm -f "$temp"
  if ! sshd -t; then
    if [[ -n $backup ]]; then
      mv "$backup" "$target"
    else
      rm -f "$target"
    fi
    ops_die 'sshd validation failed; previous configuration restored.'
  fi
  ops_ssh_reload
  ops_log "SSH hardening installed: $target"
}

ops_ssh_main() {
  case ${1:-help} in
    harden)
      shift
      ops_ssh_harden "$@"
      ;;
    help | --help | -h) ops_ssh_help ;;
    *) ops_die "Unknown ssh command: $1" ;;
  esac
}
