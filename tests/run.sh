#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
find "$root/bin" "$root/lib" "$root/modules" "$root/tools" "$root/scripts" "$root/tests" \
  -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
bash -n "$root/bin/opsctl"
"$root/tests/test_cli.sh"
"$root/tests/test_release.sh"
"$root/scripts/scan-secrets.sh"
