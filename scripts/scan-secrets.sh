#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
status=0

scan() {
  local description=$1 pattern=$2
  shift 2
  if rg -n -i --glob '!GOAL.md' --glob '!tests/**' --glob '!scripts/scan-secrets.sh' "$pattern" "$@" >/dev/null; then
    printf 'Potential secret found: %s\n' "$description" >&2
    status=1
  fi
}

scan 'private key block' 'BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY' "$root"
scan 'credential in URL' 'https?://[^[:space:]/]+:[^[:space:]@]+@' "$root"
scan 'private IPv4 address' '(^|[^0-9])(10\.[0-9]{1,3}(\.[0-9]{1,3}){2}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3})([^0-9]|$)' "$root"
scan 'generated Xray identity' '"(privateKey|private_key|uuid|id)"[[:space:]]*:[[:space:]]*"[A-Za-z0-9_-]{16,}"' "$root/tools/xray/templates"

if command -v gitleaks >/dev/null 2>&1; then
  gitleaks detect --no-banner --no-git --source "$root"
fi
exit "$status"
