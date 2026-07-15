#!/usr/bin/env bash

if [[ -n "${OPS_COMMON_LOADED:-}" ]]; then
  return 0
fi
readonly OPS_COMMON_LOADED=1

OPS_ROOT="${OPS_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck disable=SC2034
OPS_VERSION="$(tr -d '[:space:]' <"$OPS_ROOT/VERSION")"
OPS_DRY_RUN=${OPS_DRY_RUN:-0}
OPS_ASSUME_YES=${OPS_ASSUME_YES:-0}

ops_log() {
  printf '[ops-toolkit] %s\n' "$*" >&2
}

ops_warn() {
  printf '[ops-toolkit] WARNING: %s\n' "$*" >&2
}

ops_die() {
  printf '[ops-toolkit] ERROR: %s\n' "$*" >&2
  exit 1
}

ops_has() {
  command -v "$1" >/dev/null 2>&1
}

ops_require_command() {
  ops_has "$1" || ops_die "Required command not found: $1"
}

ops_require_root() {
  if ((EUID != 0)); then
    ops_die 'This command must run as root.'
  fi
}

ops_require_root_unless_dry_run() {
  ((OPS_DRY_RUN)) || ops_require_root
}

# Each dependency spec is COMMAND|DEBIAN_PACKAGE|ALPINE_PACKAGE.
ops_ensure_commands() {
  local context=$1 spec command debian_package alpine_package package
  local -a missing=() packages=()
  shift
  for spec in "$@"; do
    IFS='|' read -r command debian_package alpine_package <<<"$spec"
    if ! ops_has "$command"; then
      missing+=("$command")
      case $OPS_OS_FAMILY in
        debian) package=$debian_package ;;
        alpine) package=$alpine_package ;;
        *) ops_die "Cannot install dependencies for unsupported platform: $OPS_OS_FAMILY" ;;
      esac
      [[ -n $package ]] || ops_die "No package mapping for missing command: $command"
      packages+=("$package")
    fi
  done
  ((${#missing[@]} > 0)) || return 0
  ops_warn "$context requires missing command(s): ${missing[*]}"
  ops_confirm "Install required package(s): ${packages[*]}?"
  ops_require_root_unless_dry_run
  case $OPS_OS_FAMILY in
    debian)
      ops_run apt-get update
      ops_run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
      ;;
    alpine) ops_run apk add --no-cache "${packages[@]}" ;;
  esac
  ((OPS_DRY_RUN)) && return 0
  for command in "${missing[@]}"; do
    ops_has "$command" || ops_die "Dependency installation completed but command is still missing: $command"
  done
}

ops_quote_command() {
  local arg
  printf '  '
  for arg in "$@"; do
    printf '%q ' "$arg"
  done
  printf '\n'
}

ops_run() {
  if ((OPS_DRY_RUN)); then
    ops_log 'Dry run:'
    ops_quote_command "$@" >&2
    return 0
  fi
  "$@"
}

ops_confirm() {
  local prompt=$1 answer
  if ((OPS_DRY_RUN || OPS_ASSUME_YES)); then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    ops_die "Confirmation required: $prompt (rerun with --yes)"
  fi
  read -r -p "$prompt [y/N] " answer
  [[ $answer == [yY] || $answer == [yY][eE][sS] ]] || ops_die 'Cancelled.'
}

ops_validate_port() {
  [[ $1 =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

ops_validate_user() {
  [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

ops_validate_container() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]]
}

ops_validate_absolute_path() {
  [[ $1 =~ ^/[A-Za-z0-9_./*?-]+$ ]] && [[ $1 != *'..'* ]]
}

ops_parse_safety_flags() {
  local -n destination=$1
  shift
  destination=()
  while (($#)); do
    case $1 in
      --dry-run) OPS_DRY_RUN=1 ;;
      --yes) OPS_ASSUME_YES=1 ;;
      *) destination+=("$1") ;;
    esac
    shift
  done
}

ops_config_set() {
  local key=$1 value=$2
  case $key in
    OPS_DATA_ROOT | OPS_NGINX_LOG_PATH | OPS_VAULTWARDEN_LOG_PATH | OPS_XRAY_CONFIG | OPS_NGINX_STREAM_CONFIG | OPS_XRAY_LOG_DIR | OPS_BIN_DIR | OPS_XRAY_BIN | OPS_SING_BOX_BIN | OPS_XRAY_SCANNER | OPS_XRAY_CHECKER)
      ops_validate_absolute_path "$value" || ops_die "Invalid path for $key"
      ;;
    OPS_DOCKER_GROUP)
      [[ $value =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || ops_die "Invalid group name for $key"
      ;;
    OPS_XRAY_CONTAINER | OPS_NGINX_CONTAINER)
      ops_validate_container "$value" || ops_die "Invalid name for $key"
      ;;
    OPS_DEFAULT_SSH_PORT)
      ops_validate_port "$value" || ops_die "Invalid port for $key"
      ;;
    '') ;;
    *) ops_die "Unknown configuration key: $key" ;;
  esac
  printf -v "$key" '%s' "$value"
  export "${key?}"
}

ops_load_config_file() {
  local file=$1 line key value
  [[ -f $file ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ -z $line || $line == '#'* ]] && continue
    [[ $line == *=* ]] || ops_die "Invalid config line in $file"
    key=${line%%=*}
    value=${line#*=}
    [[ $key =~ ^OPS_[A-Z0-9_]+$ ]] || ops_die "Invalid config key in $file"
    ops_config_set "$key" "$value"
  done <"$file"
}

ops_load_config() {
  : "${OPS_DATA_ROOT:=/srv/docker}"
  : "${OPS_DOCKER_GROUP:=docker-data}"
  : "${OPS_DEFAULT_SSH_PORT:=22}"
  : "${OPS_XRAY_CONTAINER:=xray}"
  : "${OPS_NGINX_CONTAINER:=nginx}"
  : "${OPS_NGINX_LOG_PATH:=/var/log/nginx/*.log}"
  : "${OPS_VAULTWARDEN_LOG_PATH:=/var/log/vaultwarden/*.log}"

  if [[ -n ${OPS_CONFIG_FILE:-} ]]; then
    ops_load_config_file "$OPS_CONFIG_FILE"
  elif [[ -f /etc/ops-toolkit/config.env ]]; then
    ops_load_config_file /etc/ops-toolkit/config.env
  elif [[ -f ${HOME:-}/.config/ops-toolkit/config.env ]]; then
    ops_load_config_file "$HOME/.config/ops-toolkit/config.env"
  fi

  : "${OPS_XRAY_CONFIG:=$OPS_DATA_ROOT/xray/config.json}"
  : "${OPS_NGINX_STREAM_CONFIG:=$OPS_DATA_ROOT/nginx/conf.d/default.stream}"
  : "${OPS_XRAY_LOG_DIR:=$OPS_DATA_ROOT/xray}"
  if [[ -z ${OPS_BIN_DIR:-} ]]; then
    if ((EUID == 0)); then
      OPS_BIN_DIR=/usr/local/bin
    else
      OPS_BIN_DIR=${HOME:?HOME is required}/.local/bin
    fi
  fi
  : "${OPS_XRAY_BIN:=$OPS_BIN_DIR/xray}"
  : "${OPS_SING_BOX_BIN:=$OPS_BIN_DIR/sing-box}"
  : "${OPS_XRAY_SCANNER:=$OPS_BIN_DIR/RealiTLScanner}"
  : "${OPS_XRAY_CHECKER:=$OPS_BIN_DIR/reality-checker}"

  ops_config_set OPS_DATA_ROOT "$OPS_DATA_ROOT"
  ops_config_set OPS_DOCKER_GROUP "$OPS_DOCKER_GROUP"
  ops_config_set OPS_DEFAULT_SSH_PORT "$OPS_DEFAULT_SSH_PORT"
  ops_config_set OPS_XRAY_CONTAINER "$OPS_XRAY_CONTAINER"
  ops_config_set OPS_NGINX_CONTAINER "$OPS_NGINX_CONTAINER"
  ops_config_set OPS_NGINX_LOG_PATH "$OPS_NGINX_LOG_PATH"
  ops_config_set OPS_VAULTWARDEN_LOG_PATH "$OPS_VAULTWARDEN_LOG_PATH"
  ops_config_set OPS_XRAY_CONFIG "$OPS_XRAY_CONFIG"
  ops_config_set OPS_NGINX_STREAM_CONFIG "$OPS_NGINX_STREAM_CONFIG"
  ops_config_set OPS_XRAY_LOG_DIR "$OPS_XRAY_LOG_DIR"
  ops_config_set OPS_BIN_DIR "$OPS_BIN_DIR"
  ops_config_set OPS_XRAY_BIN "$OPS_XRAY_BIN"
  ops_config_set OPS_SING_BOX_BIN "$OPS_SING_BOX_BIN"
  ops_config_set OPS_XRAY_SCANNER "$OPS_XRAY_SCANNER"
  ops_config_set OPS_XRAY_CHECKER "$OPS_XRAY_CHECKER"
}
