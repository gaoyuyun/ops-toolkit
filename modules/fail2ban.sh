#!/usr/bin/env bash

ops_fail2ban_help() {
  cat <<'EOF'
Usage: opsctl fail2ban install [--only default|sshd|nginx|vaultwarden] [--yes] [--dry-run]
       opsctl fail2ban status [JAIL]
       opsctl fail2ban menu

Installs packaged jail/filter templates using configured SSH port and log
paths. Existing files with the same ops-toolkit names are replaced.
EOF
}

ops_render_fail2ban_jail() {
  local source=$1 destination=$2
  sed \
    -e "s|@SSH_PORT@|$OPS_DEFAULT_SSH_PORT|g" \
    -e "s|@NGINX_LOG_PATH@|$OPS_NGINX_LOG_PATH|g" \
    -e "s|@VAULTWARDEN_LOG_PATH@|$OPS_VAULTWARDEN_LOG_PATH|g" \
    "$source" >"$destination"
}

ops_fail2ban_install() {
  local -a args
  local etc_root jail_dir filter_dir source temp only=all
  ops_parse_safety_flags args "$@"
  set -- "${args[@]}"
  while (($#)); do
    case $1 in
      --only)
        only=${2:?}
        shift 2
        ;;
      *) ops_die "Unknown fail2ban option: $1" ;;
    esac
  done
  [[ $only == all || $only == default || $only == sshd || $only == nginx || $only == vaultwarden ]] || ops_die 'Invalid Fail2ban rule selection.'
  ops_ensure_commands 'Fail2ban resource installation' 'fail2ban-client|fail2ban|fail2ban'
  ops_confirm 'Install ops-toolkit Fail2ban resources?'
  ops_require_root_unless_dry_run
  etc_root=${OPS_ETC_ROOT:-/etc}
  jail_dir=$etc_root/fail2ban/jail.d
  filter_dir=$etc_root/fail2ban/filter.d
  if ((OPS_DRY_RUN)); then
    ops_run install -d -m 0755 "$jail_dir" "$filter_dir"
    local -a jails=("$OPS_ROOT"/assets/fail2ban/jail.d/*.conf) filters=("$OPS_ROOT"/assets/fail2ban/filter.d/*.conf)
    local jail
    for source in "${jails[@]}"; do
      jail=${source##*/}
      case $only:$jail in
        all:* | default:00-ops-toolkit-defaults.conf | sshd:10-ops-toolkit-sshd.conf | nginx:20-ops-toolkit-nginx.conf | vaultwarden:30-ops-toolkit-vaultwarden.conf) ops_log "Would render: $source -> $jail_dir/$jail" ;;
      esac
    done
    for source in "${filters[@]}"; do
      case $only:${source##*/} in
        all:* | nginx:nginx-bad-request-custom.conf | vaultwarden:vaultwarden.conf) ops_run install -m 0644 "$source" "$filter_dir/${source##*/}" ;;
      esac
    done
    return 0
  fi
  install -d -m 0755 "$jail_dir" "$filter_dir"
  local -a jails=("$OPS_ROOT"/assets/fail2ban/jail.d/*.conf) filters=("$OPS_ROOT"/assets/fail2ban/filter.d/*.conf)
  local jail
  for source in "${jails[@]}"; do
    jail=${source##*/}
    case $only:$jail in
      all:* | default:00-ops-toolkit-defaults.conf | sshd:10-ops-toolkit-sshd.conf | nginx:20-ops-toolkit-nginx.conf | vaultwarden:30-ops-toolkit-vaultwarden.conf) ;;
      *) continue ;;
    esac
    temp=$(mktemp)
    ops_render_fail2ban_jail "$source" "$temp"
    install -m 0644 "$temp" "$jail_dir/$jail"
    rm -f "$temp"
  done
  for source in "${filters[@]}"; do
    case $only:${source##*/} in
      all:* | nginx:nginx-bad-request-custom.conf | vaultwarden:vaultwarden.conf) ;;
      *) continue ;;
    esac
    install -m 0644 "$source" "$filter_dir/${source##*/}"
  done
  fail2ban-client -t
  if ops_has systemctl; then
    systemctl enable --now fail2ban
    systemctl restart fail2ban
  elif ops_has rc-service; then
    rc-service fail2ban restart
  fi
  ops_log "Fail2ban resources installed under $etc_root/fail2ban"
}

ops_fail2ban_status() {
  local jail=${1:-}
  (($# <= 1)) || ops_die 'status accepts at most one jail name.'
  ops_ensure_commands 'Fail2ban status' 'fail2ban-client|fail2ban|fail2ban'
  if [[ -n $jail ]]; then
    fail2ban-client status "$jail"
  else
    fail2ban-client status
  fi
}

ops_fail2ban_menu() {
  local choice jail
  while true; do
    printf '\nFail2ban management\n1) Install all rules  2) Configure default  3) Configure sshd\n4) Configure nginx  5) Configure Vaultwarden  6) Overall status  7) Jail status  0) Back\n'
    read -r -p 'Select: ' choice
    case $choice in
      1) ops_fail2ban_install ;;
      2) ops_fail2ban_install --only default ;;
      3) ops_fail2ban_install --only sshd ;;
      4) ops_fail2ban_install --only nginx ;;
      5) ops_fail2ban_install --only vaultwarden ;;
      6) ops_fail2ban_status ;;
      7)
        read -r -p 'Jail name: ' jail
        [[ -z $jail ]] || ops_fail2ban_status "$jail"
        ;;
      0) return ;;
      *) ops_warn 'Invalid selection.' ;;
    esac
  done
}

ops_fail2ban_main() {
  case ${1:-help} in
    install)
      shift
      ops_fail2ban_install "$@"
      ;;
    status)
      shift
      ops_fail2ban_status "$@"
      ;;
    menu)
      shift
      (($# == 0)) || ops_die 'fail2ban menu takes no arguments'
      ops_fail2ban_menu
      ;;
    help | --help | -h) ops_fail2ban_help ;;
    *) ops_die "Unknown fail2ban command: $1" ;;
  esac
}
