#!/usr/bin/env bash

ops_user_help() {
  cat <<'EOF'
Usage:
  opsctl user create NAME [--shell SHELL] [--no-sudo] [--docker-data] [--yes] [--dry-run]
  opsctl user backup [NAME] [--backup-dir DIR] [--regenerate|--recreate]
                     [--keep-private] [--yes] [--dry-run]
  opsctl user cert [NAME] [--cert-dir DIR] [--regenerate|--recreate]
                   [--keep-private] [--cron] [--yes] [--dry-run]
  opsctl user authorized-key NAME [--key-file FILE] [--replace] [--yes] [--dry-run]
  opsctl user root-password
  opsctl user zsh NAME|--all|--skel [--yes] [--dry-run]
  opsctl user menu
EOF
}

ops_user_home() {
  getent passwd "$1" | cut -d: -f6
}

ops_user_group() {
  id -gn "$1"
}

ops_user_ensure_data_group() {
  if ! getent group "$OPS_DOCKER_GROUP" >/dev/null 2>&1; then
    case $OPS_OS_FAMILY in
      debian) ops_run groupadd --system "$OPS_DOCKER_GROUP" ;;
      alpine) ops_run addgroup -S "$OPS_DOCKER_GROUP" ;;
    esac
  fi
}

ops_user_add_to_group() {
  local user=$1 group=$2
  case $OPS_OS_FAMILY in
    debian) ops_run usermod -aG "$group" "$user" ;;
    alpine) ops_run addgroup "$user" "$group" ;;
  esac
}

ops_user_create() {
  local -a args
  local name='' shell=/bin/bash sudo_access=1 docker_data=0
  ops_parse_safety_flags args "$@"
  set -- "${args[@]}"
  while (($#)); do
    case $1 in
      --shell)
        shell=${2:?}
        shift 2
        ;;
      --no-sudo)
        sudo_access=0
        shift
        ;;
      --docker-data)
        docker_data=1
        shift
        ;;
      --*) ops_die "Unknown user option: $1" ;;
      *)
        [[ -z $name ]] || ops_die 'Only one user name is accepted.'
        name=$1
        shift
        ;;
    esac
  done
  [[ -n $name ]] || ops_die 'A user name is required.'
  ops_validate_user "$name" || ops_die 'Invalid user name.'
  [[ $shell == /* && $shell != *'..'* ]] || ops_die 'Shell must be an absolute path.'
  if getent passwd "$name" >/dev/null 2>&1; then
    ops_log "User already exists: $name"
    return 0
  fi
  ops_confirm "Create login user '$name'?"
  ops_require_root_unless_dry_run
  case $OPS_OS_FAMILY in
    debian)
      if [[ -t 0 && $OPS_DRY_RUN == 0 ]]; then
        adduser --shell "$shell" "$name"
      else
        ops_run useradd --create-home --shell "$shell" "$name"
      fi
      ((sudo_access == 0)) || ops_user_add_to_group "$name" sudo
      ;;
    alpine)
      ops_run adduser -D -s "$shell" "$name"
      ((sudo_access == 0)) || ops_user_add_to_group "$name" wheel
      ;;
    *) ops_die 'User creation is not supported on this platform.' ;;
  esac
  if ((docker_data)); then
    ops_user_ensure_data_group
    ops_user_add_to_group "$name" "$OPS_DOCKER_GROUP"
  fi
  ops_log "User created: $name"
}

ops_user_authorized_key() {
  local -a args
  local user=${1:-} key_file='' public_key home ssh_dir authorized_keys replace=0
  [[ -n $user ]] || ops_die 'A user name is required.'
  shift || true
  ops_parse_safety_flags args "$@"
  set -- "${args[@]}"
  while (($#)); do
    case $1 in
      --key-file)
        key_file=${2:?}
        shift 2
        ;;
      --replace)
        replace=1
        shift
        ;;
      *) ops_die "Unknown authorized-key option: $1" ;;
    esac
  done
  getent passwd "$user" >/dev/null 2>&1 || ops_die "User does not exist: $user"
  if [[ -n $key_file ]]; then
    [[ -f $key_file && ! -L $key_file ]] || ops_die 'Public key file must be a regular non-symlink file.'
    public_key=$(<"$key_file")
  else
    [[ -t 0 ]] || ops_die '--key-file is required outside an interactive terminal.'
    read -r -p 'Paste one SSH public key: ' public_key
  fi
  [[ $public_key == ssh-*' '* ]] || ops_die 'Input does not look like an SSH public key.'
  if ((replace)); then
    ops_confirm "Replace authorized_keys for '$user'?"
  else
    ops_confirm "Append this public key to authorized_keys for '$user'?"
  fi
  ops_require_root_unless_dry_run
  home=$(ops_user_home "$user")
  ssh_dir=$home/.ssh
  authorized_keys=$ssh_dir/authorized_keys
  if ((OPS_DRY_RUN)); then
    if ((replace)); then
      ops_log "Would replace $authorized_keys with one public key"
    else
      ops_log "Would append one non-duplicate public key to $authorized_keys"
    fi
    return 0
  fi
  install -d -m 0700 -o "$user" -g "$(ops_user_group "$user")" "$ssh_dir"
  [[ ! -L $authorized_keys ]] || ops_die 'authorized_keys may not be a symbolic link.'
  if ((replace)); then
    printf '%s\n' "$public_key" >"$authorized_keys"
  else
    touch "$authorized_keys"
    grep -qxF "$public_key" "$authorized_keys" || printf '%s\n' "$public_key" >>"$authorized_keys"
  fi
  chown "$user:$(ops_user_group "$user")" "$authorized_keys"
  chmod 0600 "$authorized_keys"
}

ops_user_print_private_key() {
  local key=$1 keep=$2
  printf '\n%s\n' '════════════════ SSH private key (copy now) ════════════════'
  cat "$key"
  printf '%s\n\n' '════════════════════════════════════════════════════════════'
  if ((keep)); then
    chmod 0600 "$key"
    ops_warn "Private key retained at $key"
  else
    rm -f "$key"
    ops_warn 'The server-side private key was deleted after printing.'
  fi
}

ops_user_zsh_add_plugin() {
  local zshrc=$1 plugin=$2
  [[ -f $zshrc ]] || return 0
  grep -qE "^plugins=\\([^)]*${plugin}[^)]*\\)" "$zshrc" 2>/dev/null && return 0
  if grep -qE '^plugins=\(' "$zshrc"; then
    sed -i "/^plugins=(/ s/)$/ ${plugin})/" "$zshrc"
  else
    printf '\nplugins=(%s)\n' "$plugin" >>"$zshrc"
  fi
}

ops_user_service_account() {
  local kind=$1
  shift
  local -a args
  local name='' target_dir='' keep=0 cron=0 recreate=0 regenerate=0
  local key_type key_name shell restrictions home ssh_dir key user_exists=0
  ops_parse_safety_flags args "$@"
  set -- "${args[@]}"
  while (($#)); do
    case $1 in
      --backup-dir | --cert-dir)
        target_dir=${2:?}
        shift 2
        ;;
      --keep-private)
        keep=1
        shift
        ;;
      --cron)
        cron=1
        shift
        ;;
      --recreate)
        recreate=1
        shift
        ;;
      --regenerate)
        regenerate=1
        shift
        ;;
      --*) ops_die "Unknown $kind account option: $1" ;;
      *)
        [[ -z $name ]] || ops_die 'Only one account name is accepted.'
        name=$1
        shift
        ;;
    esac
  done
  if [[ $kind == backup ]]; then
    name=${name:-nas-backup}
    target_dir=${target_dir:-$OPS_DATA_ROOT}
    key_type=ed25519
    key_name=backup_key
    shell=/bin/sh
    restrictions='no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding'
  else
    name=${name:-nginx-cert-bot}
    target_dir=${target_dir:-$OPS_DATA_ROOT/nginx/certs}
    key_type=rsa
    key_name=cert_deploy_key
    shell=/bin/false
    restrictions="restrict,command=\"internal-sftp -d $target_dir\""
  fi
  ops_validate_user "$name" || ops_die 'Invalid service-account name.'
  ops_validate_absolute_path "$target_dir" || ops_die 'Target directory must be an absolute safe path.'
  ((recreate == 0 || regenerate == 0)) || ops_die '--recreate and --regenerate are mutually exclusive.'
  getent passwd "$name" >/dev/null 2>&1 && user_exists=1
  if ((user_exists && recreate == 0 && regenerate == 0)); then
    ops_die "User already exists: $name (use --regenerate or --recreate)."
  fi
  ops_ensure_commands 'SSH service account creation' 'ssh-keygen|openssh-client|openssh-client'
  if ((recreate)); then
    ops_confirm "Delete and recreate $kind service account '$name'?"
  elif ((regenerate)); then
    ops_confirm "Regenerate the SSH identity for $kind account '$name'?"
  else
    ops_confirm "Create $kind service account '$name' for $target_dir?"
  fi
  ops_require_root_unless_dry_run
  ops_user_ensure_data_group
  if ((recreate && user_exists)); then
    ops_run userdel -r "$name"
    user_exists=0
  fi
  if ! getent passwd "$name" >/dev/null 2>&1; then
    case $OPS_OS_FAMILY in
      debian) ops_run useradd --system --shell "$shell" --home-dir "/home/$name" --create-home --groups "$OPS_DOCKER_GROUP" "$name" ;;
      alpine) ops_run adduser -S -s "$shell" -h "/home/$name" -G "$OPS_DOCKER_GROUP" "$name" ;;
    esac
  fi
  if ((OPS_DRY_RUN)); then
    ops_log "Would generate a $key_type key, configure restricted authorized_keys, and print the private key once."
    return 0
  fi
  install -d -m 2775 -o root -g "$OPS_DOCKER_GROUP" "$target_dir"
  home=$(ops_user_home "$name")
  ssh_dir=$home/.ssh
  install -d -m 0700 -o "$name" -g "$(ops_user_group "$name")" "$ssh_dir"
  key=$ssh_dir/$key_name
  rm -f "$key" "$key.pub"
  if [[ $key_type == rsa ]]; then
    ssh-keygen -q -t rsa -b 4096 -m PEM -N '' -C "$kind-$name@$(hostname)" -f "$key"
  else
    ssh-keygen -q -t ed25519 -N '' -C "$kind-$name@$(hostname)" -f "$key"
  fi
  if [[ -n $restrictions ]]; then
    printf '%s %s\n' "$restrictions" "$(<"$key.pub")" >"$ssh_dir/authorized_keys"
  else
    cp "$key.pub" "$ssh_dir/authorized_keys"
  fi
  chown -R "$name:$(ops_user_group "$name")" "$ssh_dir"
  chmod 0600 "$ssh_dir/authorized_keys" "$key"
  chmod 0644 "$key.pub"
  if [[ $kind == cert ]]; then
    install -d -m 0755 /etc/ssh/sshd_config.d
    printf '%s\n' \
      "Match User $name" \
      "    ForceCommand internal-sftp -d $target_dir" \
      '    PasswordAuthentication no' \
      '    AllowTcpForwarding no' \
      '    X11Forwarding no' \
      '    PermitTunnel no' \
      '    AllowAgentForwarding no' \
      '    PermitTTY no' >/etc/ssh/sshd_config.d/91-ops-toolkit-cert.conf
    sshd -t || ops_die 'sshd rejected the certificate-account configuration.'
    ops_ssh_reload
    if ((cron)) && ! crontab -l 2>/dev/null | grep -qF "docker exec $OPS_NGINX_CONTAINER nginx -s reload"; then
      (
        crontab -l 2>/dev/null
        printf '0 3 * * * docker exec %s nginx -s reload >/dev/null 2>&1\n' "$OPS_NGINX_CONTAINER"
      ) | crontab -
    fi
  fi
  ops_user_print_private_key "$key" "$keep"
}

ops_user_zsh() {
  local -a args users
  local target=${1:-} mode=user user home zsh_custom skel=/etc/skel
  [[ -n $target ]] || ops_die 'Specify a user, --all, or --skel.'
  shift || true
  ops_parse_safety_flags args "$@"
  ((${#args[@]} == 0)) || ops_die "Unknown zsh option: ${args[0]}"
  case $target in
    --all) mode=all ;;
    --skel) mode=skel ;;
    *) getent passwd "$target" >/dev/null 2>&1 || ops_die "User does not exist: $target" ;;
  esac
  ops_ensure_commands 'Zsh installation' 'zsh|zsh|zsh' 'git|git|git' 'curl|curl|curl'
  ops_confirm "Install Zsh, Oh My Zsh, Powerlevel10k and plugins ($target)?"
  ops_require_root_unless_dry_run
  if [[ $mode == all ]]; then
    mapfile -t users < <(awk -F: '$3 == 0 || ($3 >= 1000 && $7 !~ /(nologin|false)$/) {print $1}' /etc/passwd)
  elif [[ $mode == user ]]; then
    users=("$target")
  else
    users=()
  fi
  if ((OPS_DRY_RUN)); then
    ops_log "Would configure Zsh for: ${users[*]:-/etc/skel}"
    return 0
  fi
  for user in "${users[@]}"; do
    home=$(ops_user_home "$user")
    [[ -d $home ]] || ops_die "User home does not exist: $home"
    [[ -d $home/.oh-my-zsh ]] || git clone -q --depth 1 https://github.com/ohmyzsh/ohmyzsh.git "$home/.oh-my-zsh"
    zsh_custom=$home/.oh-my-zsh/custom
    [[ -d $zsh_custom/themes/powerlevel10k ]] || git clone -q --depth 1 https://github.com/romkatv/powerlevel10k.git "$zsh_custom/themes/powerlevel10k"
    [[ -d $zsh_custom/plugins/zsh-autosuggestions ]] || git clone -q --depth 1 https://github.com/zsh-users/zsh-autosuggestions "$zsh_custom/plugins/zsh-autosuggestions"
    [[ -d $zsh_custom/plugins/zsh-syntax-highlighting ]] || git clone -q --depth 1 https://github.com/zsh-users/zsh-syntax-highlighting "$zsh_custom/plugins/zsh-syntax-highlighting"
    [[ -f $home/.zshrc ]] || cp "$home/.oh-my-zsh/templates/zshrc.zsh-template" "$home/.zshrc"
    sed -i 's/^ZSH_THEME=.*/ZSH_THEME="powerlevel10k\/powerlevel10k"/' "$home/.zshrc"
    ops_user_zsh_add_plugin "$home/.zshrc" zsh-autosuggestions
    ops_user_zsh_add_plugin "$home/.zshrc" zsh-syntax-highlighting
    chown -R "$user:$(ops_user_group "$user")" "$home/.oh-my-zsh" "$home/.zshrc"
    chsh -s /bin/zsh "$user"
  done
  if [[ $mode == skel ]]; then
    [[ -d $skel/.oh-my-zsh ]] || git clone -q --depth 1 https://github.com/ohmyzsh/ohmyzsh.git "$skel/.oh-my-zsh"
    zsh_custom=$skel/.oh-my-zsh/custom
    [[ -d $zsh_custom/themes/powerlevel10k ]] || git clone -q --depth 1 https://github.com/romkatv/powerlevel10k.git "$zsh_custom/themes/powerlevel10k"
    [[ -d $zsh_custom/plugins/zsh-autosuggestions ]] || git clone -q --depth 1 https://github.com/zsh-users/zsh-autosuggestions "$zsh_custom/plugins/zsh-autosuggestions"
    [[ -d $zsh_custom/plugins/zsh-syntax-highlighting ]] || git clone -q --depth 1 https://github.com/zsh-users/zsh-syntax-highlighting "$zsh_custom/plugins/zsh-syntax-highlighting"
    [[ -f $skel/.zshrc ]] || cp "$skel/.oh-my-zsh/templates/zshrc.zsh-template" "$skel/.zshrc"
    sed -i 's/^ZSH_THEME=.*/ZSH_THEME="powerlevel10k\/powerlevel10k"/' "$skel/.zshrc"
    ops_user_zsh_add_plugin "$skel/.zshrc" zsh-autosuggestions
    ops_user_zsh_add_plugin "$skel/.zshrc" zsh-syntax-highlighting
    useradd -D -s /bin/zsh
  fi
}

ops_user_menu() {
  local choice name path action=() existing_action
  while true; do
    ops_ui_menu choice 'User management' -- \
      '1|Normal user' \
      '2|Backup user' \
      '3|Certificate user' \
      '4|Root password' \
      '5|Import SSH key' \
      '6|Zsh/P10k' \
      '0|Back'
    case $choice in
      1)
        ops_ui_prompt name 'User name' || continue
        if [[ -n $name ]]; then
          ops_user_create "$name"
          if ops_ui_confirm 'Import an SSH public key now?' default_y; then
            ops_user_authorized_key "$name"
          fi
          if ops_ui_confirm 'Install Zsh, P10k and plugins now?' default_y; then
            ops_user_zsh "$name"
          fi
          if getent group "$OPS_DOCKER_GROUP" >/dev/null 2>&1; then
            if ops_ui_confirm "Add $name to $OPS_DOCKER_GROUP?" default_y; then
              ops_user_add_to_group "$name" "$OPS_DOCKER_GROUP"
            fi
          fi
        fi
        ops_ui_pause
        ;;
      2)
        ops_ui_prompt name 'User name' 'nas-backup' || continue
        action=()
        if getent passwd "$name" >/dev/null 2>&1; then
          ops_ui_prompt existing_action 'Existing user: 1) regenerate key  2) delete and rebuild  0) cancel' || continue
          case $existing_action in
            1) action=(--regenerate) ;;
            2) action=(--recreate) ;;
            *) continue ;;
          esac
        fi
        ops_user_service_account backup "$name" "${action[@]}"
        ops_ui_pause
        ;;
      3)
        ops_ui_prompt name 'User name' 'nginx-cert-bot' || continue
        action=()
        if getent passwd "$name" >/dev/null 2>&1; then
          ops_ui_prompt existing_action 'Existing user: 1) regenerate key  2) delete and rebuild  0) cancel' || continue
          case $existing_action in
            1) action=(--regenerate) ;;
            2) action=(--recreate) ;;
            *) continue ;;
          esac
        fi
        ops_user_service_account cert "$name" "${action[@]}" --cron
        ops_ui_pause
        ;;
      4)
        passwd root
        ops_ui_pause
        ;;
      5)
        ops_ui_prompt name 'User name' || continue
        ops_ui_prompt path 'Public key file (blank to paste)' || continue
        if [[ -n $name ]]; then
          if [[ -n $path ]]; then ops_user_authorized_key "$name" --key-file "$path"; else ops_user_authorized_key "$name"; fi
        fi
        ops_ui_pause
        ;;
      6)
        ops_ui_prompt name 'User name, --all, or --skel' || continue
        [[ -z $name ]] || ops_user_zsh "$name"
        ops_ui_pause
        ;;
      0) return ;;
    esac
  done
}

ops_user_main() {
  case ${1:-help} in
    create)
      shift
      ops_user_create "$@"
      ;;
    backup)
      shift
      ops_user_service_account backup "$@"
      ;;
    cert)
      shift
      ops_user_service_account cert "$@"
      ;;
    authorized-key)
      shift
      ops_user_authorized_key "$@"
      ;;
    root-password)
      shift
      (($# == 0)) || ops_die 'root-password takes no arguments'
      ops_require_root
      passwd root
      ;;
    zsh)
      shift
      ops_user_zsh "$@"
      ;;
    menu)
      shift
      (($# == 0)) || ops_die 'user menu takes no arguments'
      ops_user_menu
      ;;
    help | --help | -h) ops_user_help ;;
    *) ops_die "Unknown user command: $1" ;;
  esac
}
