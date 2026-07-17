#!/usr/bin/env bash

ops_firewall_help() {
  cat <<'EOF'
Usage:
  opsctl firewall install [--ssh-port PORT] [--yes] [--dry-run]
  opsctl firewall status
  opsctl firewall allow PORT[/PROTO] [--yes] [--dry-run]
  opsctl firewall allow --range START:END [--proto tcp|udp] [--yes] [--dry-run]
  opsctl firewall allow --from IP [--port PORT] [--proto tcp|udp] [--yes] [--dry-run]
  opsctl firewall delete NUMBER [--yes] [--dry-run]
  opsctl firewall menu
EOF
}

ops_firewall_ensure() {
  ops_ensure_commands 'Firewall management' 'ufw|ufw|ufw'
}

ops_firewall_install() {
  local -a args
  local ssh_port=$OPS_DEFAULT_SSH_PORT detected
  ops_parse_safety_flags args "$@"
  set -- "${args[@]}"
  while (($#)); do
    case $1 in
      --ssh-port)
        ssh_port=${2:?}
        shift 2
        ;;
      *) ops_die "Unknown firewall install option: $1" ;;
    esac
  done
  if [[ $ssh_port == auto ]]; then
    detected=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}') || true
    ssh_port=${detected:-$OPS_DEFAULT_SSH_PORT}
  fi
  ops_validate_port "$ssh_port" || ops_die 'SSH port must be between 1 and 65535.'
  ops_firewall_ensure
  ops_confirm "Enable UFW after allowing SSH $ssh_port/tcp, HTTP and HTTPS?"
  ops_require_root_unless_dry_run
  ops_run ufw default deny incoming
  ops_run ufw default allow outgoing
  ops_run ufw allow "$ssh_port/tcp"
  ops_run ufw allow http
  ops_run ufw allow https
  ops_run ufw --force enable
  ops_run ufw status verbose
}

ops_firewall_status() {
  ops_firewall_ensure
  ufw status verbose
  ufw status numbered
}

ops_firewall_allow() {
  local -a args command
  local rule='' range='' source_ip='' port='' proto=tcp range_start range_end
  ops_parse_safety_flags args "$@"
  set -- "${args[@]}"
  while (($#)); do
    case $1 in
      --range)
        range=${2:?}
        shift 2
        ;;
      --from)
        source_ip=${2:?}
        shift 2
        ;;
      --port)
        port=${2:?}
        shift 2
        ;;
      --proto)
        proto=${2:?}
        shift 2
        ;;
      --*) ops_die "Unknown firewall allow option: $1" ;;
      *)
        [[ -z $rule ]] || ops_die 'Only one direct rule is accepted.'
        rule=$1
        shift
        ;;
    esac
  done
  [[ $proto == tcp || $proto == udp || $proto == both ]] || ops_die 'Protocol must be tcp, udp, or both.'
  if [[ -n $rule ]]; then
    [[ -z $range && -z $source_ip && -z $port ]] || ops_die 'Direct PORT[/PROTO] cannot be combined with structured options.'
    [[ $rule =~ ^[0-9]+(/(tcp|udp))?$ ]] || ops_die 'Rule must be PORT, PORT/tcp, or PORT/udp.'
    ops_validate_port "${rule%%/*}" || ops_die 'Invalid firewall port.'
    command=(ufw allow "$rule")
  elif [[ -n $range ]]; then
    [[ $range =~ ^([0-9]+):([0-9]+)$ ]] || ops_die 'Range must look like 8000:8100.'
    range_start=${BASH_REMATCH[1]}
    range_end=${BASH_REMATCH[2]}
    if ! ops_validate_port "$range_start" || ! ops_validate_port "$range_end"; then
      ops_die 'Invalid port range.'
    fi
    ((10#$range_start <= 10#$range_end)) || ops_die 'Port range start exceeds end.'
    [[ $proto != both ]] || ops_die 'Port ranges require tcp or udp.'
    command=(ufw allow "$range/$proto")
  elif [[ -n $source_ip ]]; then
    [[ $source_ip =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ ]] || ops_die 'Invalid source IP/CIDR.'
    command=(ufw allow from "$source_ip")
    if [[ -n $port ]]; then
      ops_validate_port "$port" || ops_die 'Invalid firewall port.'
      [[ $proto != both ]] || proto=tcp
      command+=(to any port "$port" proto "$proto")
    fi
  else
    ops_die 'Provide a port, --range, or --from.'
  fi
  ops_firewall_ensure
  ops_confirm "Add UFW rule: ${command[*]}?"
  ops_require_root_unless_dry_run
  if [[ $proto == both && -n $rule && $rule != */* ]]; then
    ops_run ufw allow "$rule/tcp"
    ops_run ufw allow "$rule/udp"
  else
    ops_run "${command[@]}"
  fi
}

ops_firewall_delete() {
  local -a args
  local number=${1:-}
  [[ $number =~ ^[1-9][0-9]*$ ]] || ops_die 'A numbered UFW rule is required.'
  shift || true
  ops_parse_safety_flags args "$@"
  ((${#args[@]} == 0)) || ops_die "Unknown firewall delete option: ${args[0]}"
  ops_firewall_ensure
  ops_confirm "Delete UFW rule number $number?"
  ops_require_root_unless_dry_run
  ops_run ufw --force delete "$number"
}

ops_firewall_menu() {
  local choice value extra
  while true; do
    ops_ui_menu choice 'UFW management' -- \
      '1|Install/enable' \
      '2|Status' \
      '3|Allow port' \
      '4|Allow range' \
      '5|Allow source IP' \
      '6|Delete numbered rule' \
      '0|Back'
    case $choice in
      1)
        ops_firewall_install
        ops_ui_pause
        ;;
      2)
        ops_firewall_status
        ops_ui_pause
        ;;
      3)
        ops_ui_prompt value 'Port[/proto]' || continue
        [[ -z $value ]] || ops_firewall_allow "$value"
        ops_ui_pause
        ;;
      4)
        ops_ui_prompt value 'Range (e.g. 8000:8100)' || continue
        ops_ui_prompt extra 'Protocol' 'tcp' || continue
        [[ -z $value ]] || ops_firewall_allow --range "$value" --proto "$extra"
        ops_ui_pause
        ;;
      5)
        ops_ui_prompt value 'Source IP/CIDR' || continue
        ops_ui_prompt extra 'Optional destination port' || continue
        if [[ -n $value ]]; then
          if [[ -n $extra ]]; then ops_firewall_allow --from "$value" --port "$extra"; else ops_firewall_allow --from "$value"; fi
        fi
        ops_ui_pause
        ;;
      6)
        ops_ui_prompt value 'Rule number' || continue
        [[ -z $value ]] || ops_firewall_delete "$value"
        ops_ui_pause
        ;;
      0) return ;;
    esac
  done
}

ops_firewall_main() {
  case ${1:-help} in
    install)
      shift
      ops_firewall_install "$@"
      ;;
    status)
      shift
      (($# == 0)) || ops_die 'status takes no arguments'
      ops_firewall_status
      ;;
    allow)
      shift
      ops_firewall_allow "$@"
      ;;
    delete)
      shift
      ops_firewall_delete "$@"
      ;;
    menu)
      shift
      (($# == 0)) || ops_die 'firewall menu takes no arguments'
      ops_firewall_menu
      ;;
    help | --help | -h) ops_firewall_help ;;
    *) ops_die "Unknown firewall command: $1" ;;
  esac
}
