#!/usr/bin/env bash

ops_wsl_help() {
  cat <<'EOF'
Usage:
  opsctl wsl status
  opsctl wsl target-user USER
  opsctl wsl sync-ssh [--source PATH] [--user USER] [--yes] [--dry-run]
  opsctl wsl enable-systemd [--yes] [--dry-run]
  opsctl wsl clean-path [--user USER] [--windows-user USER] [--yes] [--dry-run]
  opsctl wsl startup init|list [--user USER] [--yes] [--dry-run]
  opsctl wsl startup enable|disable NAME [--user USER] [--yes] [--dry-run]
  opsctl wsl install-base [--yes] [--dry-run]
  opsctl wsl install-zsh [--user USER] [--yes] [--dry-run]
  opsctl wsl install-mihomo [--config-url HTTPS_URL] [--yes] [--dry-run]
  opsctl wsl install-dev [--user USER] [--yes] [--dry-run]
  opsctl wsl init [--user USER] [--windows-user USER] [--yes] [--dry-run]
  opsctl wsl menu

The WSL commands restore the config-lab systemd, clean PATH, startup loader,
Mihomo and nvm/uv/Node initialization flow. Downloaded Mihomo assets are
selected by architecture from the latest GitHub release and SHA-256 verified.
EOF
}

ops_wsl_require() {
  ((OPS_IS_WSL)) || ops_die 'This command is available only inside WSL.'
  [[ $OPS_OS_FAMILY == debian ]] || ops_die 'WSL initialization currently supports Debian and Ubuntu.'
}

ops_wsl_default_user() {
  local candidate=${OPS_WSL_USER:-${SUDO_USER:-${USER:-}}}
  if [[ -n $candidate && $candidate != root ]] && getent passwd "$candidate" >/dev/null 2>&1; then
    printf '%s\n' "$candidate"
  else
    id -un
  fi
}

ops_wsl_user_home() {
  getent passwd "$1" | cut -d: -f6
}

ops_wsl_validate_user() {
  ops_validate_user "$1" || ops_die "Invalid WSL user: $1"
  getent passwd "$1" >/dev/null 2>&1 || ops_die "WSL user does not exist: $1"
}

ops_wsl_run_as_user() {
  local user=$1 command=$2
  if [[ $(id -un) == "$user" ]]; then
    bash -lc "$command"
  elif ops_has runuser; then
    runuser -u "$user" -- bash -lc "$command"
  else
    su - "$user" -s /bin/bash -c "$command"
  fi
}

ops_wsl_ensure_line() {
  local file=$1 line=$2
  touch "$file"
  grep -qxF "$line" "$file" || printf '%s\n' "$line" >>"$file"
}

ops_wsl_ini_set() {
  local file=$1 section=$2 key=$3 value=$4 temp
  [[ -d $(dirname -- "$file") ]] || install -d -m 0755 "$(dirname -- "$file")"
  touch "$file"
  temp=$(mktemp)
  awk -v section="$section" -v key="$key" -v value="$value" '
    BEGIN { in_section=0; found_section=0; wrote=0 }
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      if (in_section && !wrote) { print key "=" value; wrote=1 }
      in_section=($0 ~ "^[[:space:]]*\\[" section "\\][[:space:]]*$")
      if (in_section) found_section=1
      print
      next
    }
    {
      if (in_section && $0 ~ "^[[:space:]]*" key "[[:space:]]*=") {
        if (!wrote) print key "=" value
        wrote=1
      } else print
    }
    END {
      if (!found_section) { print ""; print "[" section "]"; print key "=" value }
      else if (in_section && !wrote) print key "=" value
    }
  ' "$file" >"$temp"
  install -m 0644 "$temp" "$file"
  rm -f "$temp"
}

ops_wsl_status() {
  ops_wsl_require
  ops_log 'WSL detected.'
  if [[ -d /run/systemd/system ]] && ops_has systemctl; then printf 'systemd: enabled\n'; else printf 'systemd: unavailable\n'; fi
  printf 'target_user: %s\n' "$(ops_wsl_default_user)"
  if grep -qE '^[[:space:]]*systemd[[:space:]]*=[[:space:]]*true' /etc/wsl.conf 2>/dev/null; then
    printf 'wsl.conf systemd: configured\n'
  else
    printf 'wsl.conf systemd: not-configured\n'
  fi
}

ops_wsl_target_user() {
  local user=${1:-}
  [[ -n $user ]] || ops_die 'A WSL target user is required.'
  ops_wsl_require
  ops_wsl_validate_user "$user"
  OPS_WSL_USER=$user
  export OPS_WSL_USER
  printf 'target_user: %s\n' "$OPS_WSL_USER"
}

ops_wsl_sync_ssh() {
  local -a args
  local windows_user source='' user='' destination home
  ops_parse_safety_flags args "$@"
  set -- "${args[@]}"
  while (($#)); do
    case $1 in
      --source)
        source=${2:?}
        shift 2
        ;;
      --user)
        user=${2:?}
        shift 2
        ;;
      *) ops_die "Unknown sync-ssh option: $1" ;;
    esac
  done
  ops_wsl_require
  user=${user:-$(ops_wsl_default_user)}
  ops_wsl_validate_user "$user"
  home=$(ops_wsl_user_home "$user")
  destination=$home/.ssh
  windows_user=${WIN_USER:-$user}
  [[ -n $source ]] || source=/mnt/c/Users/$windows_user/.ssh
  [[ $source == /mnt/?/Users/*/.ssh ]] || ops_die 'Source must be a Windows user .ssh directory under /mnt.'
  [[ -d $source ]] || ops_die 'Windows SSH directory was not found.'
  ops_ensure_commands 'WSL SSH synchronization' 'rsync|rsync|rsync' 'dos2unix|dos2unix|dos2unix'
  ops_confirm "Synchronize Windows SSH files into $destination?"
  ops_require_root_unless_dry_run
  ops_run install -d -m 0700 -o "$user" -g "$(id -gn "$user")" "$destination"
  ops_run rsync -rL --checksum --exclude 'agent.*' --chmod=Du=rwx,Dgo=,Fu=rw,Fgo= "$source/" "$destination/"
  if ((OPS_DRY_RUN == 0)); then
    find "$destination" -type f -exec dos2unix -q {} +
    chown -R "$user:$(id -gn "$user")" "$destination"
    find "$destination" -type d -exec chmod 0700 {} +
    find "$destination" -type f -exec chmod 0600 {} +
    find "$destination" -type f -name '*.pub' -exec chmod 0644 {} +
    [[ ! -f $destination/known_hosts ]] || chmod 0644 "$destination/known_hosts"
    [[ ! -f $destination/config ]] || chmod 0600 "$destination/config"
  fi
  ops_log 'SSH files synchronized and converted to Unix line endings.'
}

ops_wsl_enable_systemd() {
  local -a args
  ops_parse_safety_flags args "$@"
  ((${#args[@]} == 0)) || ops_die "Unknown enable-systemd option: ${args[0]}"
  ops_wsl_require
  ops_confirm 'Enable systemd in /etc/wsl.conf?'
  ops_require_root_unless_dry_run
  if ((OPS_DRY_RUN)); then
    ops_log 'Would set [boot] systemd=true in /etc/wsl.conf.'
    return 0
  fi
  ops_wsl_ini_set /etc/wsl.conf boot systemd true
  ops_warn 'Run "wsl.exe --shutdown" in Windows, then reopen WSL.'
}

ops_wsl_clean_path() {
  local -a args
  local user='' windows_user='' home cfg vsc_path
  ops_parse_safety_flags args "$@"
  set -- "${args[@]}"
  while (($#)); do
    case $1 in
      --user)
        user=${2:?}
        shift 2
        ;;
      --windows-user)
        windows_user=${2:?}
        shift 2
        ;;
      *) ops_die "Unknown clean-path option: $1" ;;
    esac
  done
  ops_wsl_require
  user=${user:-$(ops_wsl_default_user)}
  windows_user=${windows_user:-$user}
  ops_wsl_validate_user "$user"
  ops_validate_user "$windows_user" || ops_die 'Invalid Windows user name.'
  home=$(ops_wsl_user_home "$user")
  cfg=$home/.config/wsl
  vsc_path="/mnt/c/Users/$windows_user/AppData/Local/Programs/Microsoft VS Code/bin"
  ops_confirm "Disable Windows PATH injection and configure curated PATH entries for $user?"
  ops_require_root_unless_dry_run
  if ((OPS_DRY_RUN)); then
    ops_log "Would configure /etc/wsl.conf and $cfg."
    return 0
  fi
  ops_wsl_ini_set /etc/wsl.conf interop appendWindowsPath false
  install -d -m 0755 -o "$user" -g "$(id -gn "$user")" "$cfg"
  {
    # shellcheck disable=SC2016 # Keep variables literal in the generated profile.
    printf '%s\n' '# Managed by ops-toolkit (WSL).' 'path_prepend() { case ":$PATH:" in *":$1:"*) ;; *) export PATH="$1:$PATH" ;; esac; }' 'path_append() { case ":$PATH:" in *":$1:"*) ;; *) export PATH="$PATH:$1" ;; esac; }' 'path_prepend "$HOME/.local/bin"'
    printf '[[ -d %q ]] && path_append %q\n' "$vsc_path" "$vsc_path"
    printf '%s\n' "alias explorer='/mnt/c/Windows/explorer.exe'" "alias clip='/mnt/c/Windows/System32/clip.exe'"
  } >"$cfg/windows-env.zsh"
  {
    # shellcheck disable=SC2016 # Keep variables literal in the generated profile.
    printf '%s\n' '# Managed by ops-toolkit (WSL).' 'path_prepend() { case ":$PATH:" in *":$1:"*) ;; *) PATH="$1:$PATH"; export PATH ;; esac; }' 'path_append() { case ":$PATH:" in *":$1:"*) ;; *) PATH="$PATH:$1"; export PATH ;; esac; }' 'path_prepend "$HOME/.local/bin"'
    printf '[ -d %q ] && path_append %q\n' "$vsc_path" "$vsc_path"
    printf '%s\n' "alias explorer='/mnt/c/Windows/explorer.exe'" "alias clip='/mnt/c/Windows/System32/clip.exe'"
  } >"$cfg/windows-env.sh"
  touch "$home/.zshrc" "$home/.bashrc"
  # shellcheck disable=SC2016 # Keep variables literal in the generated profile.
  ops_wsl_ensure_line "$home/.zshrc" '[[ -f "$HOME/.config/wsl/windows-env.zsh" ]] && source "$HOME/.config/wsl/windows-env.zsh"'
  # shellcheck disable=SC2016 # Keep variables literal in the generated profile.
  ops_wsl_ensure_line "$home/.bashrc" '[ -f "$HOME/.config/wsl/windows-env.sh" ] && . "$HOME/.config/wsl/windows-env.sh"'
  chown -R "$user:$(id -gn "$user")" "$cfg" "$home/.zshrc" "$home/.bashrc"
  ops_warn 'The PATH change takes effect after "wsl.exe --shutdown" and reopening WSL.'
}

ops_wsl_startup_init() {
  local user=$1 home cfg startup enabled
  ops_wsl_validate_user "$user"
  home=$(ops_wsl_user_home "$user")
  cfg=$home/.config/wsl
  startup=$home/scripts/start_up
  enabled=$startup/enabled
  if ((OPS_DRY_RUN)); then
    ops_log "Would configure the startup loader under $startup."
    return 0
  fi
  install -d -m 0755 -o "$user" -g "$(id -gn "$user")" "$cfg" "$enabled"
  cat >"$cfg/startup-loader.zsh" <<'EOF'
# Managed by ops-toolkit (WSL).
STARTUP_DIR="$HOME/scripts/start_up/enabled"
LOG_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/wsl-startup.log"
mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}" 2>/dev/null || true
if [[ -d "$STARTUP_DIR" ]]; then
  for script in "$STARTUP_DIR"/*; do
    [[ -x "$script" ]] || continue
    { echo "[$(date '+%F %T')] run: $script"; "$script"; } >>"$LOG_FILE" 2>&1
  done
fi
EOF
  cat >"$cfg/startup-loader.sh" <<'EOF'
# Managed by ops-toolkit (WSL).
STARTUP_DIR="$HOME/scripts/start_up/enabled"
LOG_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/wsl-startup.log"
mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}" 2>/dev/null || true
if [ -d "$STARTUP_DIR" ]; then
  for script in "$STARTUP_DIR"/*; do
    [ -x "$script" ] || continue
    { echo "[$(date '+%F %T')] run: $script"; "$script"; } >>"$LOG_FILE" 2>&1
  done
fi
EOF
  touch "$home/.zshrc" "$home/.bashrc"
  # shellcheck disable=SC2016 # Keep variables literal in the generated profile.
  ops_wsl_ensure_line "$home/.zshrc" '[[ -f "$HOME/.config/wsl/startup-loader.zsh" ]] && source "$HOME/.config/wsl/startup-loader.zsh"'
  # shellcheck disable=SC2016 # Keep variables literal in the generated profile.
  ops_wsl_ensure_line "$home/.bashrc" '[ -f "$HOME/.config/wsl/startup-loader.sh" ] && . "$HOME/.config/wsl/startup-loader.sh"'
  chown -R "$user:$(id -gn "$user")" "$cfg" "$startup" "$home/.zshrc" "$home/.bashrc"
}

ops_wsl_startup_main() {
  local action=${1:-} name='' user='' home startup enabled link
  [[ -n $action ]] || ops_die 'Usage: opsctl wsl startup init|list|enable|disable'
  shift || true
  if [[ $action == enable || $action == disable ]]; then
    name=${1:-}
    [[ -n $name ]] || ops_die "$action requires a script name"
    shift || true
  fi
  local -a args
  ops_parse_safety_flags args "$@"
  set -- "${args[@]}"
  while (($#)); do case $1 in --user)
    user=${2:?}
    shift 2
    ;;
  *) ops_die "Unknown startup option: $1" ;; esac done
  ops_wsl_require
  user=${user:-$(ops_wsl_default_user)}
  ops_wsl_validate_user "$user"
  [[ $name != */* && $name != . && $name != .. && $name != enabled ]] || ops_die 'Invalid startup script name.'
  home=$(ops_wsl_user_home "$user")
  startup=$home/scripts/start_up
  enabled=$startup/enabled
  ops_confirm "$action WSL startup configuration for $user?"
  ops_require_root_unless_dry_run
  ops_wsl_startup_init "$user"
  case $action in
    init) ;;
    list)
      printf 'Enabled scripts:\n'
      find "$enabled" -mindepth 1 -maxdepth 1 -printf '%f -> %l\n' 2>/dev/null | sort
      printf 'Available scripts:\n'
      find "$startup" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort
      ;;
    enable)
      [[ -f $startup/$name && ! -L $startup/$name ]] || ops_die "Startup script not found: $startup/$name"
      if ((OPS_DRY_RUN)); then ops_log "Would enable $name."; else
        chmod 0755 "$startup/$name"
        ln -sfn "../$name" "$enabled/$name"
        chown -h "$user:$(id -gn "$user")" "$enabled/$name"
      fi
      ;;
    disable)
      link=$enabled/$name
      if ((OPS_DRY_RUN)); then
        ops_log "Would remove $link."
      elif [[ -L $link ]]; then
        rm -f "$link"
      else
        ops_warn "Startup item is not enabled: $name"
      fi
      ;;
    *) ops_die "Unknown startup action: $action" ;;
  esac
}

ops_wsl_install_base() {
  local -a args
  ops_parse_safety_flags args "$@"
  ((${#args[@]} == 0)) || ops_die "Unknown install-base option: ${args[0]}"
  ops_wsl_require
  ops_confirm 'Install the config-lab WSL base packages?'
  ops_require_root_unless_dry_run
  ops_run apt-get update
  ops_run env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl wget git sudo unzip zip jq build-essential rsync dos2unix
}

ops_wsl_install_zsh() {
  local -a args
  local user=''
  ops_parse_safety_flags args "$@"
  set -- "${args[@]}"
  while (($#)); do case $1 in --user)
    user=${2:?}
    shift 2
    ;;
  *) ops_die "Unknown install-zsh option: $1" ;; esac done
  ops_wsl_require
  user=${user:-$(ops_wsl_default_user)}
  ops_wsl_validate_user "$user"
  if ((OPS_DRY_RUN)); then ops_user_zsh "$user" --yes --dry-run; else ops_user_zsh "$user" --yes; fi
}

ops_wsl_mihomo_asset() {
  local arch=$1 json name
  json=$(curl -fsSL --connect-timeout 10 https://api.github.com/repos/MetaCubeX/mihomo/releases/latest) || ops_die 'Unable to query the latest Mihomo release.'
  MIHOMO_TAG=$(jq -r '.tag_name' <<<"$json")
  name="mihomo-linux-$arch-$MIHOMO_TAG.gz"
  jq -e --arg name "$name" '.assets[] | select(.name == $name)' <<<"$json" >/dev/null || name=''
  [[ -n $name ]] || ops_die "No Mihomo Linux asset found for $arch."
  MIHOMO_URL=$(jq -r --arg name "$name" '.assets[] | select(.name == $name) | .browser_download_url' <<<"$json")
  MIHOMO_DIGEST=$(jq -r --arg name "$name" '.assets[] | select(.name == $name) | (.digest // "")' <<<"$json")
  MIHOMO_DIGEST=${MIHOMO_DIGEST#sha256:}
  [[ $MIHOMO_URL == https://* && $MIHOMO_DIGEST =~ ^[0-9a-fA-F]{64}$ ]] || ops_die 'Mihomo release is missing a verifiable SHA-256 digest.'
}

ops_wsl_install_mihomo() {
  local -a args
  local config_url='' arch temp
  ops_parse_safety_flags args "$@"
  set -- "${args[@]}"
  while (($#)); do case $1 in --config-url)
    config_url=${2:?}
    shift 2
    ;;
  *) ops_die "Unknown install-mihomo option: $1" ;; esac done
  ops_wsl_require
  [[ -z $config_url || $config_url == https://* ]] || ops_die '--config-url must use HTTPS.'
  ops_ensure_commands 'Mihomo installation' 'curl|curl|curl' 'jq|jq|jq' 'gzip|gzip|gzip' 'sha256sum|coreutils|coreutils'
  case $OPS_ARCH in x86_64 | amd64) arch=amd64 ;; aarch64 | arm64) arch=arm64 ;; *) ops_die "Unsupported Mihomo architecture: $OPS_ARCH" ;; esac
  ops_wsl_mihomo_asset "$arch"
  ops_confirm "Install Mihomo $MIHOMO_TAG and its systemd service?"
  ops_require_root_unless_dry_run
  if ((OPS_DRY_RUN)); then
    ops_log "Would download $MIHOMO_URL, verify SHA-256, and install /usr/local/bin/mihomo."
    return 0
  fi
  temp=$(mktemp -d)
  ops_download "$MIHOMO_URL" "$temp/mihomo.gz"
  ops_verify_sha256 "$temp/mihomo.gz" "${MIHOMO_DIGEST,,}"
  gzip -dc "$temp/mihomo.gz" >"$temp/mihomo"
  install -m 0755 "$temp/mihomo" /usr/local/bin/mihomo
  install -d -m 0750 /etc/mihomo
  if [[ -n $config_url ]]; then
    ops_download "$config_url" /etc/mihomo/config.yaml
    chmod 0640 /etc/mihomo/config.yaml
  fi
  cat >/etc/systemd/system/mihomo.service <<'EOF'
[Unit]
Description=mihomo Daemon, Another Clash Kernel
After=network.target NetworkManager.service systemd-networkd.service

[Service]
Type=simple
LimitNPROC=500
LimitNOFILE=1000000
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_DAC_READ_SEARCH CAP_DAC_OVERRIDE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_DAC_READ_SEARCH CAP_DAC_OVERRIDE
Restart=always
ExecStart=/usr/local/bin/mihomo -d /etc/mihomo
ExecReload=/bin/kill -HUP $MAINPID

[Install]
WantedBy=multi-user.target
EOF
  rm -rf "$temp"
  if [[ -d /run/systemd/system ]] && ops_has systemctl; then
    systemctl daemon-reload
    systemctl enable mihomo
    if [[ -s /etc/mihomo/config.yaml ]]; then systemctl restart mihomo; else ops_warn 'Mihomo was installed but not started because config.yaml is missing.'; fi
  else
    ops_warn 'systemd is not active. Enable it, restart WSL, then enable/start mihomo.'
  fi
}

ops_wsl_install_dev() {
  local -a args
  local user='' home
  ops_parse_safety_flags args "$@"
  set -- "${args[@]}"
  while (($#)); do case $1 in --user)
    user=${2:?}
    shift 2
    ;;
  *) ops_die "Unknown install-dev option: $1" ;; esac done
  ops_wsl_require
  user=${user:-$(ops_wsl_default_user)}
  ops_wsl_validate_user "$user"
  home=$(ops_wsl_user_home "$user")
  ops_warn 'This compatibility command executes the current official nvm and uv installer scripts.'
  ops_confirm "Install nvm, uv and Node LTS for $user?"
  ops_require_root_unless_dry_run
  if ((OPS_DRY_RUN)); then
    ops_log "Would install nvm, uv and Node LTS for $user."
    return 0
  fi
  apt-get update
  env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl git build-essential
  ops_wsl_run_as_user "$user" 'export PROFILE=/dev/null; curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | bash'
  ops_wsl_run_as_user "$user" 'curl -LsSf https://astral.sh/uv/install.sh | sh'
  touch "$home/.zshrc" "$home/.bashrc"
  for file in "$home/.zshrc" "$home/.bashrc"; do
    # shellcheck disable=SC2016 # Keep variables literal in the generated profile.
    ops_wsl_ensure_line "$file" 'export NVM_DIR="$HOME/.nvm"'
    # shellcheck disable=SC2016 # Keep variables literal in the generated profile.
    ops_wsl_ensure_line "$file" '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"'
    # shellcheck disable=SC2016 # Keep variables literal in the generated profile.
    ops_wsl_ensure_line "$file" '[ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"'
    # shellcheck disable=SC2016 # Keep variables literal in the generated profile.
    ops_wsl_ensure_line "$file" 'export PATH="$HOME/.local/bin:$PATH"'
  done
  chown "$user:$(id -gn "$user")" "$home/.zshrc" "$home/.bashrc"
  # shellcheck disable=SC2016 # Expand these variables in the target user's shell.
  ops_wsl_run_as_user "$user" 'export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"; nvm install --lts; nvm alias default "lts/*"'
}

ops_wsl_init_all() {
  local -a args common
  local user='' windows_user=''
  ops_parse_safety_flags args "$@"
  set -- "${args[@]}"
  while (($#)); do
    case $1 in --user)
      user=${2:?}
      shift 2
      ;;
    --windows-user)
      windows_user=${2:?}
      shift 2
      ;;
    *) ops_die "Unknown WSL init option: $1" ;; esac
  done
  user=${user:-$(ops_wsl_default_user)}
  windows_user=${windows_user:-$user}
  common=(--yes)
  ((OPS_DRY_RUN == 0)) || common+=(--dry-run)
  ops_wsl_install_base "${common[@]}"
  ops_wsl_install_zsh --user "$user" "${common[@]}"
  ops_wsl_clean_path --user "$user" --windows-user "$windows_user" "${common[@]}"
  ops_wsl_install_mihomo "${common[@]}"
  ops_wsl_install_dev --user "$user" "${common[@]}"
}

ops_wsl_menu() {
  ops_wsl_require
  local choice user windows_user name config_url
  while true; do
    printf '\nWSL initialization\n1) Select/status target  2) Install base packages  3) Install Zsh/P10k\n4) Configure clean PATH  5) Startup scripts  6) Install Mihomo\n7) Install nvm/uv/Node  8) Run steps 2-4 and 6-7  9) Enable systemd\n10) Sync Windows SSH  0) Back\n'
    read -r -p 'Select: ' choice
    case $choice in
      1)
        ops_wsl_status
        read -r -p "Target user ($(ops_wsl_default_user)): " user
        [[ -z $user ]] || ops_wsl_target_user "$user"
        ;;
      2) ops_wsl_install_base ;;
      3)
        read -r -p "User ($(ops_wsl_default_user)): " user
        ops_wsl_install_zsh --user "${user:-$(ops_wsl_default_user)}"
        ;;
      4)
        read -r -p "Linux user ($(ops_wsl_default_user)): " user
        read -r -p "Windows user (${user:-$(ops_wsl_default_user)}): " windows_user
        ops_wsl_clean_path --user "${user:-$(ops_wsl_default_user)}" --windows-user "${windows_user:-${user:-$(ops_wsl_default_user)}}"
        ;;
      5)
        read -r -p 'Startup action [init/list/enable/disable]: ' choice
        if [[ $choice == enable || $choice == disable ]]; then
          read -r -p 'Script name: ' name
          ops_wsl_startup_main "$choice" "$name"
        else ops_wsl_startup_main "$choice"; fi
        ;;
      6)
        read -r -p 'Optional HTTPS subscription URL: ' config_url
        if [[ -n $config_url ]]; then ops_wsl_install_mihomo --config-url "$config_url"; else ops_wsl_install_mihomo; fi
        ;;
      7)
        read -r -p "User ($(ops_wsl_default_user)): " user
        ops_wsl_install_dev --user "${user:-$(ops_wsl_default_user)}"
        ;;
      8) ops_wsl_init_all ;;
      9) ops_wsl_enable_systemd ;;
      10) ops_wsl_sync_ssh ;;
      0) return ;;
      *) ops_warn 'Invalid selection.' ;;
    esac
  done
}

ops_wsl_main() {
  case ${1:-help} in
    status)
      shift
      (($# == 0)) || ops_die 'status takes no arguments'
      ops_wsl_status
      ;;
    target-user)
      shift
      (($# == 1)) || ops_die 'target-user requires USER'
      ops_wsl_target_user "$1"
      ;;
    sync-ssh)
      shift
      ops_wsl_sync_ssh "$@"
      ;;
    enable-systemd)
      shift
      ops_wsl_enable_systemd "$@"
      ;;
    clean-path)
      shift
      ops_wsl_clean_path "$@"
      ;;
    startup)
      shift
      ops_wsl_startup_main "$@"
      ;;
    install-base)
      shift
      ops_wsl_install_base "$@"
      ;;
    install-zsh)
      shift
      ops_wsl_install_zsh "$@"
      ;;
    install-mihomo)
      shift
      ops_wsl_install_mihomo "$@"
      ;;
    install-dev)
      shift
      ops_wsl_install_dev "$@"
      ;;
    init)
      shift
      ops_wsl_init_all "$@"
      ;;
    menu)
      shift
      (($# == 0)) || ops_die 'wsl menu takes no arguments'
      ops_wsl_menu
      ;;
    help | --help | -h) ops_wsl_help ;;
    *) ops_die "Unknown WSL command: $1" ;;
  esac
}
