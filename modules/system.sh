#!/usr/bin/env bash

ops_system_help() {
  cat <<'EOF'
Usage:
  opsctl system hostname NAME [--cloud-init] [--yes] [--dry-run]
  opsctl system swap SIZE [--swappiness N] [--recreate] [--yes] [--dry-run]
  opsctl system bbr [--yes] [--dry-run]
  opsctl system menu
EOF
}

ops_system_hostname() {
  local -a args
  local name=${1:-} cloud_init=0
  [[ -n $name ]] || ops_die 'A hostname is required.'
  shift || true
  ops_parse_safety_flags args "$@"
  set -- "${args[@]}"
  while (($#)); do
    case $1 in
      --cloud-init)
        cloud_init=1
        shift
        ;;
      *) ops_die "Unknown hostname option: $1" ;;
    esac
  done
  [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$ ]] || ops_die 'Invalid hostname.'
  ops_confirm "Set hostname to $name?"
  ops_require_root_unless_dry_run
  ops_run hostnamectl set-hostname "$name"
  if ((OPS_DRY_RUN)); then
    ops_log 'Would update /etc/hosts and optional cloud-init settings.'
    return 0
  fi
  if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
    sed -i -E "s/^127\.0\.1\.1.*/127.0.1.1 $name/" /etc/hosts
  else
    printf '127.0.1.1 %s\n' "$name" >>/etc/hosts
  fi
  if ((cloud_init)) && [[ -f /etc/cloud/cloud.cfg ]]; then
    sed -i 's/^preserve_hostname: false/preserve_hostname: true/' /etc/cloud/cloud.cfg
    sed -i '/update_etc_hosts/s/^/#/' /etc/cloud/cloud.cfg
  fi
  ops_log "Hostname changed to $name"
}

ops_system_swap() {
  local -a args
  local size=${1:-1G} swappiness=10 recreate=0 count sysctl_file=/etc/sysctl.d/local.conf
  (($# == 0)) || shift
  ops_parse_safety_flags args "$@"
  set -- "${args[@]}"
  while (($#)); do
    case $1 in
      --swappiness)
        swappiness=${2:?}
        shift 2
        ;;
      --recreate)
        recreate=1
        shift
        ;;
      *) ops_die "Unknown swap option: $1" ;;
    esac
  done
  if [[ $size =~ ^([0-9]+)[Gg]$ ]]; then
    count=$((10#${BASH_REMATCH[1]} * 1024))
  elif [[ $size =~ ^([0-9]+)[Mm]$ ]]; then
    count=$((10#${BASH_REMATCH[1]}))
  else
    ops_die 'Swap size must look like 512M or 1G.'
  fi
  if [[ ! $swappiness =~ ^[0-9]+$ ]] || ((10#$swappiness > 200)); then
    ops_die 'Swappiness must be between 0 and 200.'
  fi
  if [[ -f /swapfile ]] && ((recreate == 0)); then
    ops_die '/swapfile already exists; use --recreate to replace it.'
  fi
  ops_confirm "Create a $size /swapfile with swappiness $swappiness?"
  ops_require_root_unless_dry_run
  if [[ -f /swapfile ]]; then
    ops_run swapoff /swapfile
    ops_run rm -f /swapfile
  fi
  ops_run dd if=/dev/zero of=/swapfile bs=1M count="$count" status=progress
  ops_run chmod 0600 /swapfile
  ops_run mkswap /swapfile
  ops_run swapon /swapfile
  if ((OPS_DRY_RUN)); then
    ops_log 'Would persist /swapfile and vm.swappiness.'
    return 0
  fi
  grep -qF '/swapfile none swap sw 0 0' /etc/fstab || printf '%s\n' '/swapfile none swap sw 0 0' >>/etc/fstab
  install -d -m 0755 /etc/sysctl.d
  if grep -qE '^vm\.swappiness=' "$sysctl_file" 2>/dev/null; then
    sed -i "s/^vm\.swappiness=.*/vm.swappiness=$swappiness/" "$sysctl_file"
  else
    printf 'vm.swappiness=%s\n' "$swappiness" >>"$sysctl_file"
  fi
  sysctl -p "$sysctl_file"
}

ops_system_bbr() {
  local -a args
  local sysctl_file=/etc/sysctl.d/local.conf
  ops_parse_safety_flags args "$@"
  ((${#args[@]} == 0)) || ops_die "Unknown BBR option: ${args[0]}"
  ops_confirm 'Enable fq and BBR congestion control?'
  ops_require_root_unless_dry_run
  if ((OPS_DRY_RUN)); then
    ops_log 'Would update /etc/sysctl.d/local.conf and run sysctl --system.'
    return 0
  fi
  install -d -m 0755 /etc/sysctl.d
  if grep -qE '^net\.core\.default_qdisc=' "$sysctl_file" 2>/dev/null; then sed -i 's/^net\.core\.default_qdisc=.*/net.core.default_qdisc=fq/' "$sysctl_file"; else printf '%s\n' 'net.core.default_qdisc=fq' >>"$sysctl_file"; fi
  if grep -qE '^net\.ipv4\.tcp_congestion_control=' "$sysctl_file" 2>/dev/null; then sed -i 's/^net\.ipv4\.tcp_congestion_control=.*/net.ipv4.tcp_congestion_control=bbr/' "$sysctl_file"; else printf '%s\n' 'net.ipv4.tcp_congestion_control=bbr' >>"$sysctl_file"; fi
  sysctl --system
  sysctl net.ipv4.tcp_congestion_control
}

ops_system_menu() {
  local choice value extra recreate_answer
  while true; do
    printf '\nSystem configuration\n1) Hostname  2) Swap  3) BBR  0) Back\n'
    read -r -p 'Select: ' choice
    case $choice in
      1)
        read -r -p 'New hostname: ' value
        if [[ -n $value ]]; then
          if [[ -f /etc/cloud/cloud.cfg ]]; then
            read -r -p 'Modify cloud-init to preserve hostname? [y/N] ' extra
            if [[ $extra == [yY] ]]; then
              ops_system_hostname "$value" --cloud-init
            else
              ops_system_hostname "$value"
            fi
          else
            ops_system_hostname "$value"
          fi
        fi
        ;;
      2)
        read -r -p 'Swap size (1G): ' value
        read -r -p 'Swappiness (10): ' extra
        if [[ -f /swapfile ]]; then
          read -r -p 'Swapfile exists. Recreate it? [y/N] ' recreate_answer
          [[ $recreate_answer == [yY] ]] && ops_system_swap "${value:-1G}" --swappiness "${extra:-10}" --recreate
        else
          ops_system_swap "${value:-1G}" --swappiness "${extra:-10}"
        fi
        ;;
      3) ops_system_bbr ;;
      0) return ;;
      *) ops_warn 'Invalid selection.' ;;
    esac
  done
}

ops_system_main() {
  case ${1:-help} in
    hostname)
      shift
      ops_system_hostname "$@"
      ;;
    swap)
      shift
      ops_system_swap "$@"
      ;;
    bbr)
      shift
      ops_system_bbr "$@"
      ;;
    menu)
      shift
      (($# == 0)) || ops_die 'system menu takes no arguments'
      ops_system_menu
      ;;
    help | --help | -h) ops_system_help ;;
    *) ops_die "Unknown system command: $1" ;;
  esac
}
