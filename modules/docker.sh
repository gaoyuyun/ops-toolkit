#!/usr/bin/env bash

ops_docker_help() {
  cat <<'EOF'
Usage:
  opsctl docker install [--source distro|official|aliyun] [--user USER]
                        [--mirrors|--no-mirrors] [--yes] [--dry-run]
  opsctl docker init-data [--user USER ...] [--yes] [--dry-run]
  opsctl docker group add|remove USER [--yes] [--dry-run]
  opsctl docker group list
  opsctl docker backup [--source DIR] [--output FILE] [--encrypt] [--yes] [--dry-run]
  opsctl docker restore ARCHIVE [--target DIR] [--clear] [--compose-dir DIR] [--start] [--yes] [--dry-run]
  opsctl docker compose up|down DIR [--yes] [--dry-run]
  opsctl docker migrate SOURCE [--target DIR] [--clear] [--delete-source]
                         [--compose-dir DIR] [--start|--no-start] [--yes] [--dry-run]
  opsctl docker menu
EOF
}

ops_docker_validate_data_path() {
  ops_validate_absolute_path "$1" && [[ $1 != / && $1 != /etc && $1 != /usr && $1 != /var ]]
}

ops_docker_install() {
  local -a args
  local source=distro target_user='' temp mirrors=-1
  ops_parse_safety_flags args "$@"
  set -- "${args[@]}"
  while (($#)); do
    case $1 in
      --source)
        source=${2:?}
        shift 2
        ;;
      --user)
        target_user=${2:?}
        shift 2
        ;;
      --mirrors)
        mirrors=1
        shift
        ;;
      --no-mirrors)
        mirrors=0
        shift
        ;;
      *) ops_die "Unknown docker install option: $1" ;;
    esac
  done
  [[ $source == distro || $source == official || $source == aliyun ]] || ops_die 'Docker source must be distro, official, or aliyun.'
  ((mirrors >= 0)) || { if [[ $source == aliyun ]]; then mirrors=1; else mirrors=0; fi; }
  if [[ -n $target_user ]]; then
    ops_validate_user "$target_user" || ops_die 'Invalid Docker user.'
    getent passwd "$target_user" >/dev/null 2>&1 || ops_die "User does not exist: $target_user"
  fi
  ops_confirm "Install Docker using source '$source'?"
  ops_require_root_unless_dry_run
  if [[ $source == distro ]]; then
    case $OPS_OS_FAMILY in
      debian)
        ops_run apt-get update
        ops_run env DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io
        if apt-cache show docker-compose-v2 >/dev/null 2>&1; then
          ops_run env DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-v2
        elif apt-cache show docker-compose-plugin >/dev/null 2>&1; then
          ops_run env DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin
        else
          ops_run env DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose
        fi
        ;;
      alpine) ops_run apk add --no-cache docker docker-cli-compose ;;
      *) ops_die 'Docker installation is unsupported on this platform.' ;;
    esac
  else
    [[ $OPS_OS_FAMILY == debian ]] || ops_die 'Official/Aliyun install scripts are supported only on Debian-family systems.'
    ops_ensure_commands 'Docker install script' 'curl|curl|curl'
    if ((OPS_DRY_RUN)); then
      ops_log 'Would download and execute https://get.docker.com after confirmation.'
    else
      temp=$(mktemp)
      ops_download https://get.docker.com "$temp"
      chmod 0700 "$temp"
      ops_warn 'Executing the current get.docker.com installer; its content is not version-pinned.'
      if [[ $source == aliyun ]]; then sh "$temp" --mirror Aliyun; else sh "$temp"; fi
      rm -f "$temp"
    fi
  fi
  if [[ -n $target_user ]]; then
    if ((OPS_DRY_RUN)); then ops_log "Would add $target_user to docker group."; else usermod -aG docker "$target_user"; fi
  fi
  if ((mirrors)); then
    if ((OPS_DRY_RUN)); then
      ops_log 'Would replace /etc/docker/daemon.json with the config-lab registry mirrors.'
    else
      install -d -m 0755 /etc/docker
      [[ ! -f /etc/docker/daemon.json ]] || cp -p /etc/docker/daemon.json /etc/docker/daemon.json.bak
      printf '%s\n' '{' '  "registry-mirrors": [' '    "https://docker.1ms.run",' '    "https://docker.xuanyuan.me"' '  ]' '}' >/etc/docker/daemon.json
      systemctl daemon-reload
      systemctl restart docker
    fi
  fi
}

ops_docker_ensure_group() {
  if ! getent group "$OPS_DOCKER_GROUP" >/dev/null 2>&1; then
    case $OPS_OS_FAMILY in
      debian) ops_run groupadd --system "$OPS_DOCKER_GROUP" ;;
      alpine) ops_run addgroup -S "$OPS_DOCKER_GROUP" ;;
    esac
  fi
}

ops_docker_group_change() {
  local action=$1 user=$2 prompt
  shift 2
  local -a args
  ops_parse_safety_flags args "$@"
  ((${#args[@]} == 0)) || ops_die "Unknown docker group option: ${args[0]}"
  ops_validate_user "$user" || ops_die 'Invalid user name.'
  getent passwd "$user" >/dev/null 2>&1 || ops_die "User does not exist: $user"
  if [[ $action == add ]]; then prompt="Add user '$user' to group '$OPS_DOCKER_GROUP'?"; else prompt="Remove user '$user' from group '$OPS_DOCKER_GROUP'?"; fi
  ops_confirm "$prompt"
  ops_require_root_unless_dry_run
  ops_docker_ensure_group
  case $action:$OPS_OS_FAMILY in
    add:debian) ops_run usermod -aG "$OPS_DOCKER_GROUP" "$user" ;;
    add:alpine) ops_run addgroup "$user" "$OPS_DOCKER_GROUP" ;;
    remove:debian) ops_run gpasswd -d "$user" "$OPS_DOCKER_GROUP" ;;
    remove:alpine) ops_run delgroup "$user" "$OPS_DOCKER_GROUP" ;;
  esac
}

ops_docker_group_main() {
  case ${1:-help} in
    add | remove)
      local action=$1
      shift
      (($# >= 1)) || ops_die "docker group $action requires USER"
      local user=$1
      shift
      ops_docker_group_change "$action" "$user" "$@"
      ;;
    list)
      shift
      (($# == 0)) || ops_die 'docker group list takes no arguments'
      getent group "$OPS_DOCKER_GROUP" || ops_die "Group does not exist: $OPS_DOCKER_GROUP"
      ;;
    *) ops_die 'Usage: opsctl docker group add|remove USER, or group list' ;;
  esac
}

ops_docker_init_data() {
  local -a args users=()
  ops_parse_safety_flags args "$@"
  set -- "${args[@]}"
  while (($#)); do
    case $1 in
      --user)
        users+=("${2:?}")
        shift 2
        ;;
      *) ops_die "Unknown init-data option: $1" ;;
    esac
  done
  ops_docker_validate_data_path "$OPS_DATA_ROOT" || ops_die 'Unsafe OPS_DATA_ROOT.'
  local user
  for user in "${users[@]}"; do
    ops_validate_user "$user" || ops_die "Invalid user: $user"
    getent passwd "$user" >/dev/null 2>&1 || ops_die "User does not exist: $user"
  done
  ops_confirm "Initialize $OPS_DATA_ROOT with group $OPS_DOCKER_GROUP?"
  ops_require_root_unless_dry_run
  ops_docker_ensure_group
  ops_run install -d -m 2775 -o root -g "$OPS_DOCKER_GROUP" "$OPS_DATA_ROOT"
  for user in "${users[@]}"; do
    if ((OPS_DRY_RUN)); then
      ops_docker_group_change add "$user" --yes --dry-run
    else
      ops_docker_group_change add "$user" --yes
    fi
  done
  if ((OPS_DRY_RUN == 0)); then
    find "$OPS_DATA_ROOT" -type d -exec chmod 2775 {} +
    find "$OPS_DATA_ROOT" -type f -exec chmod 0664 {} +
    find "$OPS_DATA_ROOT" -type f \( -name '*.sh' -o -name '*.py' \) -exec chmod 0775 {} +
  fi
}

ops_docker_compose() {
  local action=$1 directory=$2
  shift 2
  local -a args command compose_files
  ops_parse_safety_flags args "$@"
  ((${#args[@]} == 0)) || ops_die "Unknown compose option: ${args[0]}"
  ops_docker_validate_data_path "$directory" || ops_die 'Unsafe Compose directory.'
  mapfile -d '' compose_files < <(find "$directory" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) -print0 | sort -z)
  ((${#compose_files[@]} > 0)) || ops_die "No Compose file found in $directory"
  ops_ensure_commands 'Docker Compose operation' 'docker|docker.io|docker'
  if docker compose version >/dev/null 2>&1; then
    command=(docker compose)
  elif ops_has docker-compose; then
    command=(docker-compose)
  else
    ops_die 'Docker Compose is unavailable.'
  fi
  local compose_file
  for compose_file in "${compose_files[@]}"; do
    compose_file=${compose_file%$'\0'}
    command+=(--file "$compose_file")
  done
  ops_confirm "$action Docker Compose services in $directory?"
  case $action in
    down) ops_run "${command[@]}" --project-directory "$directory" down ;;
    up) ops_run "${command[@]}" --project-directory "$directory" up -d ;;
    *) ops_die 'Compose action must be up or down.' ;;
  esac
}

ops_docker_archive_safe() {
  local archive=$1
  if tar -tzf "$archive" | awk '$0 ~ /^\// || $0 ~ /(^|\/)\.\.($|\/)/ {bad=1} END {exit bad ? 0 : 1}'; then
    ops_die 'Archive contains an absolute or parent-traversal path.'
  fi
}

ops_docker_backup() {
  local -a args
  local source=$OPS_DATA_ROOT output='' encrypt=0 stamp
  ops_parse_safety_flags args "$@"
  set -- "${args[@]}"
  while (($#)); do
    case $1 in
      --source)
        source=${2:?}
        shift 2
        ;;
      --output)
        output=${2:?}
        shift 2
        ;;
      --encrypt)
        encrypt=1
        shift
        ;;
      *) ops_die "Unknown backup option: $1" ;;
    esac
  done
  ops_docker_validate_data_path "$source" || ops_die 'Unsafe backup source.'
  [[ -d $source && ! -L $source ]] || ops_die "Backup source is not a regular directory: $source"
  stamp=$(date +%Y%m%d_%H%M%S)
  [[ -n $output ]] || output=$PWD/docker_backup_$stamp.tar.gz
  [[ $output == /* && ! -L $output ]] || ops_die 'Backup output must be an absolute non-symlink path.'
  ops_confirm "Archive $source to $output?"
  if ((OPS_DRY_RUN)); then
    ops_log "Would create archive of $source at $output (encrypt=$encrypt)."
    return 0
  fi
  umask 077
  tar -czf "$output" -C "$(dirname "$source")" "$(basename "$source")"
  chmod 0600 "$output"
  if ((encrypt)); then
    ops_ensure_commands 'Encrypted Docker backup' 'gpg|gpg|gnupg'
    gpg --symmetric --cipher-algo AES256 --output "$output.gpg" "$output"
    chmod 0600 "$output.gpg"
    rm -f "$output"
    output=$output.gpg
  fi
  ops_log "Docker data backup created: $output"
}

ops_docker_restore() {
  local archive=${1:-}
  shift || true
  local -a args
  local target=$OPS_DATA_ROOT clear=0 compose_dir='' start=0 temp='' source_archive
  [[ -n $archive ]] || ops_die 'An archive path is required.'
  ops_parse_safety_flags args "$@"
  set -- "${args[@]}"
  while (($#)); do
    case $1 in
      --target)
        target=${2:?}
        shift 2
        ;;
      --clear)
        clear=1
        shift
        ;;
      --compose-dir)
        compose_dir=${2:?}
        shift 2
        ;;
      --start)
        start=1
        shift
        ;;
      *) ops_die "Unknown restore option: $1" ;;
    esac
  done
  [[ -f $archive && ! -L $archive ]] || ops_die 'Archive must be a regular non-symlink file.'
  ops_docker_validate_data_path "$target" || ops_die 'Unsafe restore target.'
  source_archive=$archive
  if [[ $archive == *.gpg ]]; then
    ops_ensure_commands 'Encrypted Docker restore' 'gpg|gpg|gnupg'
    temp=$(mktemp --suffix=.tar.gz)
    if ((OPS_DRY_RUN == 0)); then
      gpg --output "$temp" --decrypt "$archive"
      source_archive=$temp
    fi
  fi
  ((OPS_DRY_RUN)) || ops_docker_archive_safe "$source_archive"
  ops_confirm "Restore $archive into $target (clear=$clear)?"
  ops_require_root_unless_dry_run
  if ((OPS_DRY_RUN)); then
    ops_log "Would restore $archive into $target."
    [[ -z $temp ]] || rm -f "$temp"
    return 0
  fi
  install -d -m 2775 -o root -g "$OPS_DOCKER_GROUP" "$target"
  ((clear == 0)) || find "$target" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
  tar -xzf "$source_archive" -C "$target" --strip-components=1
  chgrp -R "$OPS_DOCKER_GROUP" "$target"
  find "$target" -type d -exec chmod 2775 {} +
  find "$target" -type f -exec chmod 0664 {} +
  find "$target" -type f \( -name '*.sh' -o -name '*.py' \) -exec chmod 0775 {} +
  [[ -z $temp ]] || rm -f "$temp"
  if ((start)); then
    [[ -n $compose_dir ]] || compose_dir=$target
    ops_docker_compose up "$compose_dir" --yes
  fi
}

ops_docker_migrate() {
  local source=${1:-}
  shift || true
  local -a args
  local target=$OPS_DATA_ROOT clear=0 delete_source=0 compose_dir='' start=1
  [[ -n $source ]] || ops_die 'A source directory is required.'
  ops_parse_safety_flags args "$@"
  set -- "${args[@]}"
  while (($#)); do
    case $1 in
      --target)
        target=${2:?}
        shift 2
        ;;
      --clear)
        clear=1
        shift
        ;;
      --delete-source)
        delete_source=1
        shift
        ;;
      --compose-dir)
        compose_dir=${2:?}
        shift 2
        ;;
      --start)
        start=1
        shift
        ;;
      --no-start)
        start=0
        shift
        ;;
      *) ops_die "Unknown migrate option: $1" ;;
    esac
  done
  if ! ops_docker_validate_data_path "$source" || ! ops_docker_validate_data_path "$target"; then
    ops_die 'Unsafe migration path.'
  fi
  [[ -d $source && ! -L $source ]] || ops_die 'Migration source must be a regular directory.'
  [[ $source != "$target" ]] || ops_die 'Source and target must differ.'
  ops_ensure_commands 'Docker data migration' 'rsync|rsync|rsync'
  if [[ -z $compose_dir ]] && find "$source" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) -print -quit | grep -q .; then
    compose_dir=$source
  fi
  ops_confirm "Stop Compose and migrate $source to $target?"
  ops_require_root_unless_dry_run
  if [[ -n $compose_dir ]]; then
    if ((OPS_DRY_RUN)); then ops_docker_compose down "$compose_dir" --yes --dry-run; else ops_docker_compose down "$compose_dir" --yes; fi
  fi
  ops_run install -d -m 2775 -o root -g "$OPS_DOCKER_GROUP" "$target"
  if ((clear)); then
    if ((OPS_DRY_RUN)); then ops_log "Would clear $target"; else find "$target" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +; fi
  fi
  ops_run rsync -aHAX --numeric-ids "$source/" "$target/"
  if ((delete_source)); then ops_run rm -rf -- "$source"; fi
  if ((OPS_DRY_RUN == 0)); then
    chgrp -R "$OPS_DOCKER_GROUP" "$target"
    find "$target" -type d -exec chmod 2775 {} +
    find "$target" -type f -exec chmod 0664 {} +
    find "$target" -type f \( -name '*.sh' -o -name '*.py' \) -exec chmod 0775 {} +
    chown -R root:"$OPS_DOCKER_GROUP" "$target"
  fi
  if ((start)) && [[ -n $compose_dir ]]; then
    if [[ $compose_dir == "$source" ]]; then compose_dir=$target; fi
    if ((OPS_DRY_RUN)); then
      ops_log "Would start Docker Compose services in $compose_dir"
    else
      ops_docker_compose up "$compose_dir" --yes
    fi
  fi
}

ops_docker_menu() {
  local choice value
  while true; do
    ops_ui_menu choice 'Docker management' -- \
      '1|Install' \
      '2|Initialize data' \
      '3|Add group user' \
      '4|Remove group user' \
      '5|List group' \
      '6|Backup' \
      '7|Restore' \
      '8|Migrate' \
      '9|Logrotate help' \
      '0|Back'
    case $choice in
      1)
        ops_ui_prompt value 'Source [distro/official/aliyun]' 'distro' || continue
        ops_docker_install --source "$value"
        ops_ui_pause
        ;;
      2)
        ops_ui_prompt value 'Optional user' || continue
        if [[ -n $value ]]; then ops_docker_init_data --user "$value"; else ops_docker_init_data; fi
        ops_ui_pause
        ;;
      3)
        ops_ui_prompt value 'User' || continue
        [[ -z $value ]] || ops_docker_group_change add "$value"
        ops_ui_pause
        ;;
      4)
        ops_ui_prompt value 'User' || continue
        [[ -z $value ]] || ops_docker_group_change remove "$value"
        ops_ui_pause
        ;;
      5)
        getent group "$OPS_DOCKER_GROUP" || true
        ops_ui_pause
        ;;
      6)
        ops_ui_prompt value 'Source' "$OPS_DATA_ROOT" || continue
        if ops_ui_confirm 'Encrypt with GPG?'; then
          ops_docker_backup --source "$value" --encrypt
        else
          ops_docker_backup --source "$value"
        fi
        ops_ui_pause
        ;;
      7)
        ops_ui_prompt value 'Archive' || continue
        [[ -z $value ]] || ops_docker_restore "$value"
        ops_ui_pause
        ;;
      8)
        ops_ui_prompt value 'Source directory' || continue
        [[ -z $value ]] || ops_docker_migrate "$value"
        ops_ui_pause
        ;;
      9)
        ops_logrotate_install
        ops_ui_pause
        ;;
      0) return ;;
    esac
  done
}

ops_docker_main() {
  case ${1:-help} in
    install)
      shift
      ops_docker_install "$@"
      ;;
    init-data)
      shift
      ops_docker_init_data "$@"
      ;;
    group)
      shift
      ops_docker_group_main "$@"
      ;;
    backup)
      shift
      ops_docker_backup "$@"
      ;;
    restore)
      shift
      ops_docker_restore "$@"
      ;;
    compose)
      shift
      local action=${1:-}
      local directory=${2:-}
      (($# >= 2)) || ops_die 'compose requires up|down and DIR'
      shift 2
      ops_docker_compose "$action" "$directory" "$@"
      ;;
    migrate)
      shift
      ops_docker_migrate "$@"
      ;;
    menu)
      shift
      (($# == 0)) || ops_die 'docker menu takes no arguments'
      ops_docker_menu
      ;;
    help | --help | -h) ops_docker_help ;;
    *) ops_die "Unknown docker command: $1" ;;
  esac
}
