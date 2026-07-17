#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
temp=$(mktemp -d)
vscode_test_pid=''
trap '[[ -z ${vscode_test_pid:-} ]] || kill "$vscode_test_pid" 2>/dev/null || true; rm -rf -- "$temp"' EXIT INT TERM
wsl_test_user=$(id -un)

"$root/bin/opsctl" --version | grep '^opsctl 0\.1\.0' >/dev/null
"$root/bin/opsctl" --help | grep 'fail2ban install' >/dev/null
if "$root/bin/opsctl" --help | grep -i 'proxy\|python' >/dev/null; then
  echo 'removed runtime is still advertised by opsctl' >&2
  exit 1
fi
"$root/bin/opsctl" </dev/null | grep '^Usage: opsctl' >/dev/null
"$root/bin/opsctl" platform | grep '^arch=' >/dev/null
"$root/bin/opsctl" user create valid-user --dry-run --yes 2>&1 | grep 'useradd\|adduser' >/dev/null
"$root/bin/opsctl" fail2ban install --dry-run --yes 2>&1 | grep 'Would render' >/dev/null

# The literal substitution verifies that config files are never evaluated.
# shellcheck disable=SC2016
printf '%s\n' 'OPS_DATA_ROOT=$(touch /tmp/ops-toolkit-injection)' >"$temp/bad.env"
if OPS_CONFIG_FILE="$temp/bad.env" "$root/bin/opsctl" platform >/dev/null 2>&1; then
  echo 'unsafe config was accepted' >&2
  exit 1
fi
[[ ! -e /tmp/ops-toolkit-injection ]]

OPS_ROOT="$root" bash -c '
  source "$OPS_ROOT/lib/common.sh"
  source "$OPS_ROOT/modules/fail2ban.sh"
  OPS_DEFAULT_SSH_PORT=2222
  OPS_NGINX_LOG_PATH=/var/log/nginx/*.log
  OPS_VAULTWARDEN_LOG_PATH=/var/log/vaultwarden/*.log
  ops_render_fail2ban_jail \
    "$OPS_ROOT/assets/fail2ban/jail.d/10-ops-toolkit-sshd.conf" \
    "$1"
' _ "$temp/rendered.conf"
grep 'port = 2222' "$temp/rendered.conf" >/dev/null
if grep '@[A-Z_]*@' "$temp/rendered.conf" >/dev/null; then
  echo 'rendered Fail2ban policy contains placeholders' >&2
  exit 1
fi

install -d -m 0700 "$temp/bin"
cat >"$temp/bin/xray" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case ${1:-} in
  version)
    echo 'Xray 99.0.0 test'
    ;;
  uuid)
    state=${XRAY_TEST_STATE:?}
    value=0
    [[ ! -f $state ]] || value=$(<"$state")
    value=$((value + 1))
    printf '%s' "$value" >"$state"
    printf '11111111-1111-4111-8111-%012d\n' "$value"
    ;;
  x25519)
    if [[ ${2:-} == -i ]]; then
      echo 'Password: BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
    else
      echo 'PrivateKey: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
      echo 'Password: BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
    fi
    ;;
  run)
    config=''
    while (($#)); do
      [[ $1 != -config ]] || config=$2
      shift
    done
    if [[ $config == stdin: ]]; then
      jq empty
    else
      jq empty "$config"
    fi
    ;;
  *) exit 1 ;;
esac
EOF
cat >"$temp/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case ${1:-} in
  inspect)
    [[ ${XRAY_CONTAINER_MISSING:-0} == 0 ]] || exit 1
    if [[ ${2:-} == *State.Running* ]]; then
      echo true
    elif [[ ${2:-} == --format=* ]]; then
      echo 'container=/xray status=running'
    fi
    ;;
  exec)
    shift
    [[ ${1:-} != -i ]] || shift
    shift
    [[ ${1:-} == xray ]] || exit 1
    shift
    XRAY_IN_CONTAINER=1 exec "$XRAY_FAKE_XRAY" "$@"
    ;;
  restart) printf '%s\n' "$2" ;;
  *) exit 1 ;;
esac
EOF
chmod 0700 "$temp/bin/xray" "$temp/bin/docker"
export XRAY_TEST_STATE="$temp/xray-state"
export XRAY_FAKE_XRAY="$temp/bin/xray"

cat >"$temp/xray.env" <<'EOF'
XRAY_UUID=11111111-1111-4111-8111-111111111111
XRAY_PRIVATE_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
XRAY_SERVER_NAME=example.org
XRAY_SHORT_ID=a1b2c3d4
XRAY_PORT=8443
EOF
chmod 0600 "$temp/xray.env"
generate_output=$(XRAY_CONTAINER_MISSING=1 PATH="$temp/bin:$PATH" "$root/bin/opsctl" xray generate reality --env-file "$temp/xray.env" --output "$temp/config.json")
[[ $generate_output == *'UUID:       11111111-1111-4111-8111-111111111111'* ]]
[[ $generate_output == *'Public Key: BBBBBBB'* ]]
[[ $generate_output == *'Short ID:   a1b2c3d4'* ]]
jq -e '.inbounds[0].port == 8443' "$temp/config.json" >/dev/null
[[ $(stat -c '%a' "$temp/config.json") == 664 ]]
ln -s "$temp/elsewhere" "$temp/link.json"
if PATH="$temp/bin:$PATH" "$root/bin/opsctl" xray generate reality --env-file "$temp/xray.env" --output "$temp/link.json" >/dev/null 2>&1; then
  echo 'symlink output was accepted' >&2
  exit 1
fi

cat >"$temp/bin/scanner" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
output=''
while (($#)); do
  [[ $1 != -out ]] || output=$2
  shift
done
printf 'address,server_name\n203.0.113.1,example.org\n' >"$output"
EOF
cat >"$temp/bin/checker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
echo 'example.org passed'
EOF
chmod 0700 "$temp/bin/scanner" "$temp/bin/checker"
auto_output=$(XRAY_CONTAINER_MISSING=1 PATH="$temp/bin:$PATH" "$root/bin/opsctl" xray generate reality \
  --server-name example.org --output "$temp/auto.json" --yes)
[[ $auto_output == *'UUID:       11111111-1111-4111-8111-000000000001'* ]]
jq -e '.inbounds[0].settings.clients[0].email == null' "$temp/auto.json" >/dev/null
jq -e '.inbounds[0].port == 44301' "$temp/auto.json" >/dev/null
[[ $(stat -c '%a' "$temp/auto.json") == 664 ]]
[[ ! -e $temp/auto.json.client.env ]]

view_output=$(PATH="$temp/bin:$PATH" "$root/bin/opsctl" xray view --config "$temp/auto.json")
[[ $view_output == *'uuid=11111111-1111-4111-8111-000000000001'* ]]
[[ $view_output != *'AAAAAAAA'* ]]

PATH="$temp/bin:$PATH" "$root/bin/opsctl" xray reverse add office \
  --config "$temp/auto.json" --yes
reverse_list=$(PATH="$temp/bin:$PATH" "$root/bin/opsctl" xray reverse list --config "$temp/auto.json")
[[ $reverse_list == *'name=office'* ]]
[[ $reverse_list == *'portal_uuid=11111111-1111-4111-8111-000000000003'* ]]
[[ $reverse_list == *'bridge_uuid=11111111-1111-4111-8111-000000000002'* ]]
reverse_stdout=$(PATH="$temp/bin:$PATH" "$root/bin/opsctl" xray reverse client office \
  --config "$temp/auto.json" --address edge.example.org)
[[ $reverse_stdout == *'Reverse client configuration'* ]]
[[ $reverse_stdout == *'"address": "edge.example.org"'* ]]
PATH="$temp/bin:$PATH" "$root/bin/opsctl" xray reverse client office \
  --config "$temp/auto.json" --address edge.example.org --output "$temp/reverse-client.json"
jq -e '.outbounds[] | select(.tag == "reality-out") | .settings.address == "edge.example.org"' \
  "$temp/reverse-client.json" >/dev/null
[[ $(stat -c '%a' "$temp/reverse-client.json") == 664 ]]

PATH="$temp/bin:$PATH" "$root/bin/opsctl" xray reverse delete office \
  --config "$temp/auto.json" --yes
if jq -e '.inbounds[0].settings.clients[] | select(.email == "office")' "$temp/auto.json" >/dev/null; then
  echo 'reverse connection was not deleted' >&2
  exit 1
fi

PATH="$temp/bin:$PATH" "$root/bin/opsctl" xray sni set new.example.org \
  --config "$temp/auto.json" --nginx-stream "$temp/missing-stream.conf" --yes
jq -e '.inbounds[0].streamSettings.realitySettings.target == "new.example.org:443"' "$temp/auto.json" >/dev/null
PATH="$temp/bin:$PATH" "$root/bin/opsctl" xray rollback --config "$temp/auto.json" --yes
jq -e '.inbounds[0].streamSettings.realitySettings.target == "example.org:443"' "$temp/auto.json" >/dev/null

XRAY_CONTAINER_MISSING=1 PATH="$temp/bin:$PATH" "$root/bin/opsctl" xray scan --target 203.0.113.10 \
  --scanner "$temp/bin/scanner" --checker "$temp/bin/checker" \
  --minutes 1 --output-dir "$temp/scan" --yes
[[ -s $temp/scan/203.0.113.10.csv ]]
[[ -s $temp/scan/scan_result.txt ]]
[[ $(stat -c '%a' "$temp/scan/203.0.113.10.csv") == 664 ]]

PATH="$temp/bin:$PATH" "$root/bin/opsctl" xray restart all --dry-run --yes 2>&1 | grep 'docker restart' >/dev/null
if XRAY_CONTAINER_MISSING=1 PATH="$temp/bin:$PATH" "$root/bin/opsctl" xray view --config "$temp/auto.json" >/dev/null 2>"$temp/missing.err"; then
  echo 'Xray command ran without the configured container' >&2
  exit 1
fi
grep 'Xray 不存在' "$temp/missing.err" >/dev/null
XRAY_CONTAINER_MISSING=1 PATH="$temp/bin:$PATH" "$root/bin/opsctl" xray </dev/null 2>"$temp/missing-bare.err" | grep '^Usage: opsctl xray' >/dev/null
if "$root/bin/opsctl" xray --help | grep 'xray install' >/dev/null; then
  echo 'host Xray installation is still advertised' >&2
  exit 1
fi
XRAY_CONTAINER_MISSING=1 OPS_XRAY_BIN="$temp/local-bin/xray" PATH="$temp/bin:$PATH" \
  "$root/bin/opsctl" xray deps --xray --dry-run --yes 2>&1 |
  grep 'Xray-linux-64.zip.dgst' >/dev/null

cat >"$temp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
echo '203.0.113.10'
EOF
chmod 0700 "$temp/bin/curl"
XRAY_CONTAINER_MISSING=1 PATH="$temp/bin:$PATH" "$root/bin/opsctl" xray scan \
  --scanner "$temp/bin/scanner" --checker "$temp/bin/checker" \
  --minutes 1 --output-dir "$temp/scan-auto" --yes >/dev/null
[[ -s $temp/scan-auto/203.0.113.10.csv ]]

mkdir -p "$temp/docker-source/data" "$temp/docker-target"
printf test >"$temp/docker-source/data/file"
tar -czf "$temp/docker-backup.tar.gz" -C "$temp/docker-source" .
"$root/bin/opsctl" user backup ops-test-backup --backup-dir "$temp/docker-source" --dry-run --yes >/dev/null
"$root/bin/opsctl" user cert ops-test-cert --cert-dir "$temp/docker-source/certs" --dry-run --yes >/dev/null
"$root/bin/opsctl" system hostname ops-test.example --dry-run --yes >/dev/null
"$root/bin/opsctl" system swap 512M --swappiness 10 --recreate --dry-run --yes >/dev/null
"$root/bin/opsctl" system bbr --dry-run --yes >/dev/null
firewall_output=$("$root/bin/opsctl" firewall install --dry-run --yes 2>&1)
[[ $firewall_output == *'ufw allow 22/tcp'* ]]
[[ $firewall_output == *'ufw allow http'* ]]
[[ $firewall_output == *'ufw allow https'* ]]
"$root/bin/opsctl" firewall allow --range 8000:8100 --proto tcp --dry-run --yes >/dev/null 2>&1
"$root/bin/opsctl" firewall allow --from 203.0.113.5 --port 443 --dry-run --yes >/dev/null 2>&1
"$root/bin/opsctl" firewall delete 1 --dry-run --yes >/dev/null 2>&1
"$root/bin/opsctl" docker backup --source "$temp/docker-source" --output "$temp/out.tar.gz" --dry-run --yes >/dev/null
"$root/bin/opsctl" docker restore "$temp/docker-backup.tar.gz" --target "$temp/docker-target" --clear --dry-run --yes >/dev/null
"$root/bin/opsctl" docker migrate "$temp/docker-source" --target "$temp/docker-target" --clear --delete-source --dry-run --yes >/dev/null
"$root/bin/opsctl" maintenance cleanup --all --volumes --dry-run --yes >/dev/null
"$root/bin/opsctl" maintenance cleanup --vscode-user "$wsl_test_user" --dry-run --yes >/dev/null
"$root/bin/opsctl" maintenance analyze >/dev/null
vscode_root="$temp/vscode-server/bin"
mkdir -p \
  "$vscode_root/1111111111111111111111111111111111111111" \
  "$vscode_root/2222222222222222222222222222222222222222" \
  "$vscode_root/3333333333333333333333333333333333333333" \
  "$vscode_root/4444444444444444444444444444444444444444"
cp "$(command -v sleep)" "$vscode_root/2222222222222222222222222222222222222222/node"
touch -d '2026-01-01 00:00:00' "$vscode_root/1111111111111111111111111111111111111111"
touch -d '2026-02-01 00:00:00' "$vscode_root/2222222222222222222222222222222222222222"
touch -d '2026-03-01 00:00:00' "$vscode_root/3333333333333333333333333333333333333333"
touch -d '2026-04-01 00:00:00' "$vscode_root/4444444444444444444444444444444444444444"
"$vscode_root/2222222222222222222222222222222222222222/node" 30 &
vscode_test_pid=$!
for _ in {1..20}; do
  [[ $(readlink "/proc/$vscode_test_pid/exe" 2>/dev/null) == "$vscode_root/2222222222222222222222222222222222222222/node" ]] && break
  sleep 0.05
done
vscode_candidates=$(OPS_ROOT="$root" bash -c '
  source "$OPS_ROOT/lib/common.sh"
  source "$OPS_ROOT/modules/maintenance.sh"
  while IFS= read -r -d "" candidate; do basename -- "$candidate"; done \
    < <(ops_maintenance_vscode_candidates_for_root "$1")
' _ "$vscode_root")
kill "$vscode_test_pid"
wait "$vscode_test_pid" 2>/dev/null || true
vscode_test_pid=''
[[ $vscode_candidates == $'1111111111111111111111111111111111111111\n3333333333333333333333333333333333333333' ]]
"$root/bin/opsctl" tools download-dd --source github --output "$temp/reinstall.sh" --dry-run --yes >/dev/null

# Interactive UI helpers: EOF must soft-cancel prompts (not apply defaults) and menus need a TTY.
ui_prompt_out=$(
  OPS_ROOT="$root" bash -c '
    set -Eeuo pipefail
    source "$OPS_ROOT/lib/common.sh"
    source "$OPS_ROOT/lib/platform.sh"
    source "$OPS_ROOT/lib/ui.sh"
    if ops_ui_prompt val "Port" "22" </dev/null; then
      echo prompt_accepted
      exit 0
    fi
    echo "val=${val-}"
    echo soft_cancelled
  ' 2>&1
)
[[ $ui_prompt_out == *Cancelled* ]]
[[ $ui_prompt_out == *soft_cancelled* ]]
[[ $ui_prompt_out != *prompt_accepted* ]]
[[ $ui_prompt_out == *'val='* && $ui_prompt_out != *'val=22'* ]]

ui_menu_out=$(
  OPS_ROOT="$root" bash -c '
    set -Eeuo pipefail
    source "$OPS_ROOT/lib/common.sh"
    source "$OPS_ROOT/lib/platform.sh"
    source "$OPS_ROOT/lib/ui.sh"
    ops_ui_menu choice "T" -- "1|A" "0|Back" </dev/null
  ' 2>&1
) && {
  echo 'ops_ui_menu accepted a non-interactive terminal' >&2
  exit 1
}
[[ $ui_menu_out == *'interactive terminal'* ]]

# --yes from a helper must not leak after the helper returns (menu safety).
OPS_ROOT="$root" bash -c '
  set -Eeuo pipefail
  source "$OPS_ROOT/lib/common.sh"
  OPS_ASSUME_YES=0
  OPS_DRY_RUN=0
  helper() {
    local -a args
    ops_parse_safety_flags args "$@"
    ((OPS_ASSUME_YES == 1)) || exit 10
  }
  helper --yes
  # Force the DEBUG hook to run after helper returns.
  true
  ((OPS_ASSUME_YES == 0)) || {
    echo "OPS_ASSUME_YES leaked: $OPS_ASSUME_YES" >&2
    exit 1
  }
  ((OPS_DRY_RUN == 0)) || {
    echo "OPS_DRY_RUN leaked: $OPS_DRY_RUN" >&2
    exit 1
  }
'

if grep -qi microsoft /proc/version 2>/dev/null; then
  "$root/bin/opsctl" wsl status >/dev/null
  "$root/bin/opsctl" wsl target-user "$wsl_test_user" >/dev/null
  "$root/bin/opsctl" wsl enable-systemd --dry-run --yes >/dev/null
  "$root/bin/opsctl" wsl clean-path --user "$wsl_test_user" --windows-user "$wsl_test_user" --dry-run --yes >/dev/null
  "$root/bin/opsctl" wsl startup init --user "$wsl_test_user" --dry-run --yes >/dev/null
fi
[[ -f $temp/docker-source/data/file ]]
[[ ! -e $temp/out.tar.gz ]]
[[ ! -e $temp/reinstall.sh ]]
