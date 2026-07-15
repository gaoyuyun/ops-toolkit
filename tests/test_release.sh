#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
temp=$(mktemp -d)
trap 'rm -rf -- "$temp"' EXIT INT TERM

RELEASE_BASE_URL=https://github.com/OWNER/ops-toolkit/releases/download/v0.1.0 \
  "$root/scripts/build-release.sh"
(
  cd "$root/dist"
  sha256sum -c ops-toolkit-v0.1.0.tar.gz.sha256
)
tar -xzf "$root/dist/ops-toolkit-v0.1.0.tar.gz" -C "$temp"
"$temp/ops-toolkit-v0.1.0/bin/opsctl" --version | grep '^opsctl 0\.1\.0' >/dev/null
if tar -tzf "$root/dist/ops-toolkit-v0.1.0.tar.gz" | grep -E '\.py$|requirements\.txt|proxy-test|MIGRATION\.md' >/dev/null; then
  echo 'release contains removed migration, Python, or proxy-tool files' >&2
  exit 1
fi
bash -n "$root/dist/bootstrap.sh"
