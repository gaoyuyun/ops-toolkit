#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
version=$(tr -d '[:space:]' <"$root/VERSION")
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  printf 'Invalid VERSION: %s\n' "$version" >&2
  exit 1
}
release_base_url=${RELEASE_BASE_URL:-"https://github.com/${GITHUB_REPOSITORY:-OWNER/ops-toolkit}/releases/download/v$version"}
[[ $release_base_url == https://* && $release_base_url != *' '* ]] || {
  printf 'RELEASE_BASE_URL must be an HTTPS URL without spaces.\n' >&2
  exit 1
}

dist=$root/dist
stage=$(mktemp -d "${TMPDIR:-/tmp}/ops-toolkit-release.XXXXXXXX")
trap 'rm -rf -- "$stage"' EXIT INT TERM
package=ops-toolkit-v$version
mkdir -p "$dist" "$stage/$package"
rm -f "$dist/$package.tar.gz" "$dist/$package.tar.gz.sha256" "$dist/bootstrap.sh"

for path in LICENSE README.md SECURITY.md VERSION config.env.example bin lib modules assets tools; do
  cp -R "$root/$path" "$stage/$package/"
done
if [[ -d $root/docs ]]; then
  cp -R "$root/docs" "$stage/$package/"
fi
find "$stage/$package" -type d -exec chmod 0755 {} +
find "$stage/$package" -type f -exec chmod 0644 {} +
chmod 0755 \
  "$stage/$package/bin/opsctl"

tar -czf "$dist/$package.tar.gz" -C "$stage" "$package"
if command -v sha256sum >/dev/null 2>&1; then
  (cd "$dist" && sha256sum "$package.tar.gz" >"$package.tar.gz.sha256")
else
  digest=$(shasum -a 256 "$dist/$package.tar.gz" | awk '{print $1}')
  printf '%s  %s\n' "$digest" "$package.tar.gz" >"$dist/$package.tar.gz.sha256"
fi
sed \
  -e "s|@VERSION@|$version|g" \
  -e "s|@RELEASE_BASE_URL@|$release_base_url|g" \
  "$root/bootstrap.sh.in" >"$dist/bootstrap.sh"
chmod 0755 "$dist/bootstrap.sh"
printf 'Built %s\n' "$dist/$package.tar.gz"
