#!/usr/bin/env bash

ops_maintenance_help() {
  cat <<'EOF'
Usage: opsctl maintenance analyze
       opsctl maintenance cleanup [--all] [--apt] [--journal DAYS] [--logs]
                                  [--docker] [--volumes] [--tmp DAYS]
                                  [--vscode] [--vscode-user USER]
                                  [--yes] [--dry-run]
       opsctl maintenance menu

Without category flags, cleanup behaves like --all but does not remove Docker
volumes. VS Code cleanup retains the newest and every running server version for
each user. --volumes is always explicit because volume data cannot be recovered.
EOF
}

ops_maintenance_format_bytes() {
  local bytes=${1:-0}
  if ((bytes >= 1073741824)); then
    printf '%d.%02d GB' $((bytes / 1073741824)) $(((bytes % 1073741824) * 100 / 1073741824))
  elif ((bytes >= 1048576)); then
    printf '%d.%02d MB' $((bytes / 1048576)) $(((bytes % 1048576) * 100 / 1048576))
  elif ((bytes >= 1024)); then
    printf '%d.%02d KB' $((bytes / 1024)) $(((bytes % 1024) * 100 / 1024))
  else printf '%d B' "$bytes"; fi
}

ops_maintenance_path_size() {
  local path=$1
  if [[ -e $path ]]; then
    du -sb -- "$path" 2>/dev/null | awk '{print $1}' || true
  else
    printf '0\n'
  fi
}

ops_maintenance_vscode_roots() {
  local selected_user=${1:-} account uid home shell root
  local -a homes=()
  local -A seen=()
  if [[ -n $selected_user ]]; then
    ops_validate_user "$selected_user" || ops_die 'Invalid VS Code user name.'
    account=$(getent passwd "$selected_user") || ops_die "User does not exist: $selected_user"
    IFS=: read -r _ _ uid _ _ home shell <<<"$account"
    homes+=("$home")
  else
    while IFS= read -r account; do
      IFS=: read -r _ _ uid _ _ home shell <<<"$account"
      if ((uid == 0 || (uid >= 1000 && uid < 65534))) && [[ $shell != */nologin && $shell != */false ]]; then
        homes+=("$home")
      fi
    done < <(getent passwd)
  fi
  for home in "${homes[@]}"; do
    [[ -d $home ]] || continue
    for root in \
      "$home/.vscode-server/bin" \
      "$home/.vscode-server/cli/servers" \
      "$home/.vscode-server-insiders/bin" \
      "$home/.vscode-server-insiders/cli/servers" \
      "$home/.vscode-remote/bin"; do
      [[ -d $root && -z ${seen[$root]+x} ]] || continue
      seen[$root]=1
      printf '%s\0' "$root"
    done
  done
}

ops_maintenance_vscode_server_active() {
  local server=$1 proc_exe target
  for proc_exe in /proc/[0-9]*/exe; do
    target=$(readlink -- "$proc_exe" 2>/dev/null) || continue
    target=${target%' (deleted)'}
    [[ $target == "$server/"* ]] && return 0
  done
  return 1
}

ops_maintenance_vscode_candidates_for_root() {
  local root=$1 server newest='' mtime newest_mtime=-1
  local -a servers=()
  [[ -d $root ]] || return 0
  for server in "$root"/*; do
    [[ -d $server && ! -L $server ]] || continue
    servers+=("$server")
    mtime=$(stat -c '%Y' -- "$server" 2>/dev/null || printf '0')
    [[ $mtime =~ ^[0-9]+$ ]] || mtime=0
    if ((mtime > newest_mtime)) || { ((mtime == newest_mtime)) && [[ $server > $newest ]]; }; then
      newest=$server
      newest_mtime=$mtime
    fi
  done
  for server in "${servers[@]}"; do
    [[ $server != "$newest" ]] || continue
    ops_maintenance_vscode_server_active "$server" && continue
    printf '%s\0' "$server"
  done
}

ops_maintenance_vscode_candidates() {
  local selected_user=${1:-} root
  while IFS= read -r -d '' root; do
    ops_maintenance_vscode_candidates_for_root "$root"
  done < <(ops_maintenance_vscode_roots "$selected_user")
}

ops_maintenance_vscode_stats() {
  local server size=0 server_size
  local -a servers=()
  mapfile -d '' -t servers < <(ops_maintenance_vscode_candidates)
  for server in "${servers[@]}"; do
    server_size=$(ops_maintenance_path_size "$server")
    [[ $server_size =~ ^[0-9]+$ ]] || server_size=0
    size=$((size + server_size))
  done
  printf '%s %s\n' "${#servers[@]}" "$size"
}

ops_maintenance_analyze() {
  local apt_size=0 old_count=0 old_size=0 tmp_count=0 tmp_size=0 docker_state='unavailable'
  local vscode_count=0 vscode_size=0
  if [[ -d /var/cache/apt ]]; then apt_size=$(ops_maintenance_path_size /var/cache/apt); fi
  old_count=$(find /var/log -xdev -type f \( -name '*.gz' -o -name '*.old' -o -name '*.xz' -o -regex '.*\.[0-9]+' \) 2>/dev/null | wc -l || true)
  if ((old_count > 0)); then
    old_size=$(find /var/log -xdev -type f \( -name '*.gz' -o -name '*.old' -o -name '*.xz' -o -regex '.*\.[0-9]+' \) -exec du -cb {} + 2>/dev/null | tail -1 | awk '{print $1}' || true)
  fi
  tmp_count=$(find /tmp -xdev -type f -atime +7 2>/dev/null | wc -l || true)
  if ((tmp_count > 0)); then
    tmp_size=$(find /tmp -xdev -type f -atime +7 -exec du -cb {} + 2>/dev/null | tail -1 | awk '{print $1}' || true)
  fi
  if ops_has docker && docker info >/dev/null 2>&1; then docker_state=$(docker system df 2>/dev/null || true); fi
  read -r vscode_count vscode_size < <(ops_maintenance_vscode_stats)
  printf 'System cleanup analysis\n'
  printf 'APT cache: %s\n' "$(ops_maintenance_format_bytes "$apt_size")"
  if ops_has journalctl; then printf 'Journal: %s\n' "$(journalctl --disk-usage 2>/dev/null | head -1)"; else printf 'Journal: unavailable\n'; fi
  printf 'Rotated logs: %s files, %s\n' "$old_count" "$(ops_maintenance_format_bytes "$old_size")"
  printf 'Old /tmp files (>7 days atime): %s files, %s\n' "$tmp_count" "$(ops_maintenance_format_bytes "$tmp_size")"
  printf 'Historical VS Code servers: %s versions, %s\n' "$vscode_count" "$(ops_maintenance_format_bytes "$vscode_size")"
  printf 'Docker: %s\n' "$docker_state"
}

ops_maintenance_cleanup() {
  local -a args
  local -a vscode_servers=()
  local do_apt=0 do_journal=0 do_logs=0 do_docker=0 do_volumes=0 do_tmp=0 do_vscode=0 categories=0
  local journal_days=3 tmp_days=7 vscode_user='' server
  ops_parse_safety_flags args "$@"
  set -- "${args[@]}"
  while (($#)); do
    case $1 in
      --all)
        do_apt=1
        do_journal=1
        do_logs=1
        do_docker=1
        do_tmp=1
        do_vscode=1
        categories=1
        shift
        ;;
      --apt)
        do_apt=1
        categories=1
        shift
        ;;
      --journal)
        do_journal=1
        journal_days=${2:?}
        categories=1
        shift 2
        ;;
      --logs)
        do_logs=1
        categories=1
        shift
        ;;
      --docker)
        do_docker=1
        categories=1
        shift
        ;;
      --volumes)
        do_docker=1
        do_volumes=1
        categories=1
        shift
        ;;
      --tmp)
        do_tmp=1
        tmp_days=${2:?}
        categories=1
        shift 2
        ;;
      --vscode)
        do_vscode=1
        categories=1
        shift
        ;;
      --vscode-user)
        do_vscode=1
        vscode_user=${2:?}
        categories=1
        shift 2
        ;;
      *) ops_die "Unknown cleanup option: $1" ;;
    esac
  done
  if ((categories == 0)); then
    do_apt=1
    do_journal=1
    do_logs=1
    do_docker=1
    do_tmp=1
    do_vscode=1
  fi
  [[ $journal_days =~ ^[1-9][0-9]*$ && $tmp_days =~ ^[1-9][0-9]*$ ]] || ops_die 'Retention days must be positive integers.'
  if [[ -n $vscode_user ]]; then
    ops_validate_user "$vscode_user" || ops_die 'Invalid VS Code user name.'
    getent passwd "$vscode_user" >/dev/null 2>&1 || ops_die "User does not exist: $vscode_user"
  fi
  ops_confirm "Run selected cleanup categories (Docker volumes=$do_volumes, VS Code user=${vscode_user:-all})?"
  ops_require_root_unless_dry_run
  if ((do_apt)); then
    case $OPS_OS_FAMILY in
      debian)
        ops_run apt-get autoremove --purge -y
        ops_run apt-get autoclean
        ops_run apt-get clean
        ;;
      alpine) ops_run rm -rf /var/cache/apk/* ;;
    esac
  fi
  if ((do_journal)); then
    if ops_has journalctl; then
      ops_run journalctl --vacuum-time="${journal_days}d"
    else
      ops_warn 'journalctl is unavailable; skipping journal cleanup.'
    fi
  fi
  if ((do_logs)); then
    if ((OPS_DRY_RUN)); then
      ops_log 'Would delete rotated *.gz, *.old, *.xz and numeric log files under /var/log.'
    else
      find /var/log -xdev -type f \( -name '*.gz' -o -name '*.old' -o -name '*.xz' -o -regex '.*\.[0-9]+' \) -delete
    fi
  fi
  if ((do_docker)); then
    if ops_has docker && docker info >/dev/null 2>&1; then
      ops_run docker system prune -af
      ((do_volumes == 0)) || ops_run docker volume prune -af
    else
      ops_warn 'Docker is unavailable or not running; skipping Docker cleanup.'
    fi
  fi
  if ((do_tmp)); then
    if ((OPS_DRY_RUN)); then
      ops_log "Would delete files under /tmp not accessed for more than $tmp_days days."
    else
      find /tmp -xdev -mindepth 1 -type f -atime "+$tmp_days" -delete
      find /tmp -xdev -mindepth 1 -depth -type d -empty -atime "+$tmp_days" -delete
    fi
  fi
  if ((do_vscode)); then
    mapfile -d '' -t vscode_servers < <(ops_maintenance_vscode_candidates "$vscode_user")
    if ((${#vscode_servers[@]} == 0)); then
      ops_log 'No historical VS Code server versions need cleanup.'
    else
      for server in "${vscode_servers[@]}"; do
        if ((OPS_DRY_RUN)); then
          ops_log "Would remove historical VS Code server: $server"
        elif ops_maintenance_vscode_server_active "$server"; then
          ops_warn "VS Code server became active; preserving it: $server"
        else
          rm -rf -- "$server"
          ops_log "Removed historical VS Code server: $server"
        fi
      done
    fi
  fi
  ops_log 'Selected cleanup operations completed.'
}

ops_maintenance_menu() {
  local choice days
  while true; do
    printf '\nSystem cleanup\n1) Analyze  2) All safe categories  3) APT/APK  4) Journal  5) Old logs\n6) Docker resources  7) Docker volumes  8) Old /tmp files  9) Historical VS Code servers  0) Back\n'
    read -r -p 'Select: ' choice
    case $choice in
      1) ops_maintenance_analyze ;;
      2) ops_maintenance_cleanup --all ;;
      3) ops_maintenance_cleanup --apt ;;
      4)
        read -r -p 'Keep journal days (3): ' days
        ops_maintenance_cleanup --journal "${days:-3}"
        ;;
      5) ops_maintenance_cleanup --logs ;;
      6) ops_maintenance_cleanup --docker ;;
      7) ops_maintenance_cleanup --volumes ;;
      8)
        read -r -p 'Delete /tmp older than days (7): ' days
        ops_maintenance_cleanup --tmp "${days:-7}"
        ;;
      9) ops_maintenance_cleanup --vscode ;;
      0) return ;;
      *) ops_warn 'Invalid selection.' ;;
    esac
  done
}

ops_maintenance_main() {
  case ${1:-help} in
    analyze)
      shift
      (($# == 0)) || ops_die 'analyze takes no arguments'
      ops_maintenance_analyze
      ;;
    cleanup)
      shift
      ops_maintenance_cleanup "$@"
      ;;
    menu)
      shift
      (($# == 0)) || ops_die 'maintenance menu takes no arguments'
      ops_maintenance_menu
      ;;
    help | --help | -h) ops_maintenance_help ;;
    *) ops_die "Unknown maintenance command: $1" ;;
  esac
}
