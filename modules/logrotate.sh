#!/usr/bin/env bash

ops_logrotate_help() {
  cat <<'EOF'
Usage: opsctl logrotate install [--yes] [--dry-run]

Renders the packaged nginx-container logrotate template with configured log
path and container name.
EOF
}

ops_logrotate_install() {
  local -a args
  local destination temp
  ops_parse_safety_flags args "$@"
  ((${#args[@]} == 0)) || ops_die "Unknown logrotate option: ${args[0]}"
  ops_ensure_commands 'Logrotate policy installation' 'logrotate|logrotate|logrotate'
  ops_confirm 'Install the nginx-container logrotate policy?'
  ops_require_root_unless_dry_run
  destination=${OPS_ETC_ROOT:-/etc}/logrotate.d/nginx-docker
  if ((OPS_DRY_RUN)); then
    ops_log "Would render $destination"
    return 0
  fi
  temp=$(mktemp)
  sed \
    -e "s|@NGINX_LOG_PATH@|$OPS_NGINX_LOG_PATH|g" \
    -e "s|@NGINX_CONTAINER@|$OPS_NGINX_CONTAINER|g" \
    "$OPS_ROOT/assets/logrotate/nginx-container" >"$temp"
  install -d -m 0755 "$(dirname "$destination")"
  install -m 0644 "$temp" "$destination"
  rm -f "$temp"
  logrotate --debug "$destination" >/dev/null
  ops_log "Logrotate policy installed: $destination"
}

ops_logrotate_main() {
  case ${1:-help} in
    install)
      shift
      ops_logrotate_install "$@"
      ;;
    help | --help | -h) ops_logrotate_help ;;
    *) ops_die "Unknown logrotate command: $1" ;;
  esac
}
