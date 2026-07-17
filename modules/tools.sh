#!/usr/bin/env bash

ops_tools_help() {
  cat <<'EOF'
Usage: opsctl tools download-dd [--source github|cnb] [--output FILE] [--yes] [--dry-run]

Downloads (but never executes) the reinstall.sh helper used by config-lab.
Review the downloaded third-party script before running it.
EOF
}

ops_tools_download_dd() {
  local -a args
  local source=github output=$PWD/reinstall.sh url
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
      *) ops_die "Unknown download-dd option: $1" ;;
    esac
  done
  case $source in
    github) url=https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh ;;
    cnb) url=https://cnb.cool/bin456789/reinstall/-/git/raw/main/reinstall.sh ;;
    *) ops_die '--source must be github or cnb.' ;;
  esac
  [[ ! -L $output ]] || ops_die 'Output may not be a symbolic link.'
  ops_confirm "Download the unverified third-party reinstall script from $source?"
  if ((OPS_DRY_RUN)); then
    ops_log "Would download $url to $output"
    return 0
  fi
  ops_download "$url" "$output"
  chmod 0755 "$output"
  ops_warn "Downloaded but not executed: $output. Review it before use."
}

ops_tools_menu() {
  local choice source
  while true; do
    ops_ui_menu choice 'Other tools' -- \
      '1|Download reinstall/DD script' \
      '0|Back'
    case $choice in
      1)
        ops_ui_prompt source 'Source [github/cnb]' 'github' || continue
        ops_tools_download_dd --source "$source"
        ops_ui_pause
        ;;
      0) return ;;
    esac
  done
}

ops_tools_main() {
  case ${1:-help} in
    download-dd)
      shift
      ops_tools_download_dd "$@"
      ;;
    menu)
      shift
      (($# == 0)) || ops_die 'tools menu takes no arguments'
      ops_tools_menu
      ;;
    help | --help | -h) ops_tools_help ;;
    *) ops_die "Unknown tools command: $1" ;;
  esac
}
