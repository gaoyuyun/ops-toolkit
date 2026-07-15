#!/usr/bin/env bash

ops_detect_platform() {
  OPS_OS_ID=unknown
  OPS_OS_VERSION=unknown
  OPS_OS_FAMILY=unknown
  OPS_ARCH=$(uname -m)
  OPS_IS_WSL=0

  if [[ -r /etc/os-release ]]; then
    OPS_OS_ID=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"' | head -n 1)
    OPS_OS_VERSION=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"' | head -n 1)
  fi
  case $OPS_OS_ID in
    debian | ubuntu) OPS_OS_FAMILY=debian ;;
    alpine) OPS_OS_FAMILY=alpine ;;
  esac
  if [[ -r /proc/version ]] && grep -qi microsoft /proc/version; then
    OPS_IS_WSL=1
  fi
  export OPS_OS_ID OPS_OS_VERSION OPS_OS_FAMILY OPS_ARCH OPS_IS_WSL
}

ops_platform_label() {
  local suffix=''
  ((OPS_IS_WSL)) && suffix=' (WSL)'
  printf '%s %s / %s%s' "$OPS_OS_ID" "$OPS_OS_VERSION" "$OPS_ARCH" "$suffix"
}

ops_require_supported_linux() {
  case $OPS_OS_FAMILY in
    debian | alpine) ;;
    *) ops_die "Unsupported platform: $(ops_platform_label)" ;;
  esac
}
