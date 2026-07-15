#!/usr/bin/env bash

ops_download() {
  local url=$1 destination=$2
  if ops_has curl; then
    curl -fsSL --retry 3 --connect-timeout 10 --output "$destination" "$url"
  elif ops_has wget; then
    wget -q --https-only --tries=3 --timeout=10 --output-document="$destination" "$url"
  else
    ops_die 'curl or wget is required.'
  fi
}

ops_verify_sha256() {
  local file=$1 expected=$2 actual
  if ops_has sha256sum; then
    actual=$(sha256sum "$file" | awk '{print $1}')
  elif ops_has shasum; then
    actual=$(shasum -a 256 "$file" | awk '{print $1}')
  else
    ops_die 'sha256sum or shasum is required.'
  fi
  [[ $actual == "$expected" ]] || ops_die "Checksum mismatch for $file"
}
