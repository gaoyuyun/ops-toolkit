#!/usr/bin/env bash

ops_alpine_help() {
  cat <<'EOF'
Usage:
  opsctl alpine create-user NAME [--yes] [--dry-run]
  opsctl alpine authorized-key NAME [--key-file FILE] [--yes] [--dry-run]
  opsctl alpine ssh [--port PORT] [--yes] [--dry-run]
  opsctl alpine bash [USER] [--yes] [--dry-run]
  opsctl alpine download-dd [OPTIONS]
  opsctl alpine menu
EOF
}

ops_alpine_require() {
  [[ $OPS_OS_ID == alpine ]] || ops_die 'This command is available only on Alpine Linux.'
}

ops_alpine_create_user() {
  local -a args
  local name=${1:-}
  [[ -n $name ]] || ops_die 'A user name is required.'
  shift || true
  ops_parse_safety_flags args "$@"
  ((${#args[@]} == 0)) || ops_die "Unknown Alpine create-user option: ${args[0]}"
  if ((OPS_DRY_RUN)); then
    ops_log 'Would install sudo and enable the wheel sudoers policy.'
    ops_user_create "$name" --dry-run --yes
    return 0
  fi
  ops_ensure_commands 'Alpine sudo setup' 'sudo|sudo|sudo'
  ops_require_root
  install -d -m 0750 /etc/sudoers.d
  printf '%s\n' '%wheel ALL=(ALL:ALL) ALL' >/etc/sudoers.d/wheel
  chmod 0440 /etc/sudoers.d/wheel
  ops_user_create "$name" --yes
}

ops_alpine_bash() {
  local -a args
  local user=${1:-root}
  (($# == 0)) || shift
  ops_parse_safety_flags args "$@"
  ((${#args[@]} == 0)) || ops_die "Unknown alpine bash option: ${args[0]}"
  ops_alpine_require
  getent passwd "$user" >/dev/null 2>&1 || ops_die "User does not exist: $user"
  ops_confirm "Install Bash and set it as the shell for '$user'?"
  ops_require_root_unless_dry_run
  ops_run apk add --no-cache bash shadow
  ops_run chsh -s /bin/bash "$user"
}

ops_alpine_menu() {
  ops_alpine_require
  ops_require_root
  local choice user path port
  while true; do
    printf '\nAlpine Linux configuration\n1) Create wheel user  2) Import SSH key  3) Configure SSH\n4) Set Bash shell  5) Download reinstall/DD script  0) Exit\n'
    read -r -p 'Select: ' choice
    case $choice in
      1)
        read -r -p 'User name: ' user
        [[ -z $user ]] || ops_user_create "$user"
        ;;
      2)
        read -r -p 'User name: ' user
        read -r -p 'Public key file (blank to paste): ' path
        if [[ -n $path ]]; then ops_user_authorized_key "$user" --key-file "$path"; else ops_user_authorized_key "$user"; fi
        ;;
      3)
        read -r -p "SSH port ($OPS_DEFAULT_SSH_PORT): " port
        ops_ssh_harden --port "${port:-$OPS_DEFAULT_SSH_PORT}"
        ;;
      4)
        read -r -p 'User (root): ' user
        ops_alpine_bash "${user:-root}"
        ;;
      5) ops_tools_download_dd ;;
      0) return ;;
      *) ops_warn 'Invalid selection.' ;;
    esac
  done
}

ops_alpine_main() {
  case ${1:-help} in
    help | --help | -h)
      ops_alpine_help
      ;;
    create-user)
      ops_alpine_require
      shift
      ops_alpine_create_user "$@"
      ;;
    authorized-key)
      ops_alpine_require
      shift
      ops_user_authorized_key "$@"
      ;;
    ssh)
      ops_alpine_require
      shift
      ops_ssh_harden "$@"
      ;;
    bash)
      ops_alpine_require
      shift
      ops_alpine_bash "$@"
      ;;
    download-dd)
      ops_alpine_require
      shift
      ops_tools_download_dd "$@"
      ;;
    menu)
      ops_alpine_require
      shift
      (($# == 0)) || ops_die 'alpine menu takes no arguments'
      ops_alpine_menu
      ;;
    *) ops_die "Unknown alpine command: $1" ;;
  esac
}
