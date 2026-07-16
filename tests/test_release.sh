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
bash -n "$root/dist/install.sh"
"$root/dist/install.sh" --help | grep 'Install or upgrade ops-toolkit 0.1.0' >/dev/null
if grep -E '@VERSION@|@RELEASE_BASE_URL@' "$root/dist/bootstrap.sh" "$root/dist/install.sh" >/dev/null; then
  echo 'generated release scripts contain unresolved placeholders' >&2
  exit 1
fi

mkdir -p "$temp/fake-bin" "$temp/install-bin"
cat >"$temp/fake-bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
output=''
url=''
while (($#)); do
  case $1 in
    --output)
      output=$2
      shift 2
      ;;
    --retry | --connect-timeout)
      shift 2
      ;;
    -* ) shift ;;
    *)
      url=$1
      shift
      ;;
  esac
done
[[ -n $output && -n $url ]]
cp "$INSTALL_TEST_DIST/${url##*/}" "$output"
EOF
chmod 0755 "$temp/fake-bin/curl"
INSTALL_TEST_DIST="$root/dist" PATH="$temp/fake-bin:$PATH" \
  "$root/dist/install.sh" --prefix "$temp/install" --bin-dir "$temp/install-bin" >/dev/null
"$temp/install-bin/opsctl" --version | grep '^opsctl 0\.1\.0' >/dev/null
[[ $(readlink "$temp/install/current") == "$temp/install/ops-toolkit-v0.1.0" ]]
[[ $(readlink "$temp/install-bin/opsctl") == "$temp/install/current/bin/opsctl" ]]

# Re-running the same release exercises the upgrade/reinstall path.
INSTALL_TEST_DIST="$root/dist" PATH="$temp/fake-bin:$PATH" \
  "$root/dist/install.sh" --prefix "$temp/install" --bin-dir "$temp/install-bin" >/dev/null
