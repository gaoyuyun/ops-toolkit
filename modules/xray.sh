#!/usr/bin/env bash

ops_xray_help() {
  cat <<'EOF'
Usage: opsctl xray COMMAND [OPTIONS]

Lifecycle:
  deps [--xray] [--sing-box] [--scan-tools] [--yes] [--dry-run]
                                        Install host-side helper dependencies
  status [--config FILE]                Show local binary, config and container status
  validate [--config FILE]              Validate JSON and run the engine check
  restart [xray|all] [--yes] [--dry-run]
  rollback [--config FILE] [--restart] [--yes] [--dry-run]

Configuration:
  generate TYPE [--env-file FILE | --server-name DOMAIN] [OPTIONS]
  view [--config FILE] [--full --yes]
  sni set DOMAIN [--config FILE] [--nginx-stream FILE] [--restart]

Reality scan:
  scan [--target HOST] [--scanner FILE] [--checker FILE]
       [--minutes N] [--output-dir DIR]

Reverse connections:
  reverse list [--config FILE] [--yes] [--dry-run]
  reverse add NAME [--config FILE] [--restart] [--yes] [--dry-run]
  reverse delete NAME [--config FILE] [--restart] [--yes] [--dry-run]
  reverse client NAME --address HOST [--output FILE] [--config FILE] [--yes] [--dry-run]

TYPE is reality, xhttp, or sing-reality. Generate and scan use local binaries
under OPS_BIN_DIR and can install missing latest dependencies after prompting.
Runtime management commands use the configured Docker Xray container.
Generated Xray files use config-lab-compatible mode 0664 and stay outside the
toolkit tree. UUID/Public Key/Short ID are printed for immediate client setup.
EOF
}

ops_xray_container_running() {
  ops_has docker || return 1
  [[ $(docker inspect --format='{{.State.Running}}' "$OPS_XRAY_CONTAINER" 2>/dev/null) == true ]]
}

ops_xray_require_container_exists() {
  if ! ops_has docker; then
    ops_die 'Xray 不存在：未安装 Docker；请先安装 Docker Xray 容器。'
  fi
  if ! docker inspect "$OPS_XRAY_CONTAINER" >/dev/null 2>&1; then
    ops_die "Xray 不存在：未找到容器 '$OPS_XRAY_CONTAINER'；请先安装 Xray。"
  fi
}

ops_xray_require_container() {
  ops_xray_require_container_exists
  if ! ops_xray_container_running; then
    ops_die "Xray 容器 '$OPS_XRAY_CONTAINER' 未运行；请先启动。"
  fi
  if ! docker exec "$OPS_XRAY_CONTAINER" xray version >/dev/null 2>&1; then
    ops_die "Xray 不可用：容器 '$OPS_XRAY_CONTAINER' 内没有可用的 xray 命令。"
  fi
}

ops_xray_exec() {
  docker exec "$OPS_XRAY_CONTAINER" xray "$@"
}

ops_xray_host_binary() {
  if [[ -x $OPS_XRAY_BIN && ! -L $OPS_XRAY_BIN ]]; then
    printf '%s\n' "$OPS_XRAY_BIN"
  elif ops_has xray; then
    command -v xray
  else
    return 1
  fi
}

ops_xray_host_exec() {
  local binary
  binary=$(ops_xray_host_binary) || ops_die 'Local Xray binary is unavailable.'
  "$binary" "$@"
}

ops_xray_singbox_binary() {
  if [[ -x $OPS_SING_BOX_BIN && ! -L $OPS_SING_BOX_BIN ]]; then
    printf '%s\n' "$OPS_SING_BOX_BIN"
  elif ops_has sing-box; then
    command -v sing-box
  else
    return 1
  fi
}

ops_xray_singbox_exec() {
  local binary
  binary=$(ops_xray_singbox_binary) || ops_die 'Local sing-box binary is unavailable.'
  "$binary" "$@"
}

ops_xray_assert_binary_target() {
  local path=$1
  [[ $path == /* ]] || ops_die 'Dependency binary paths must be absolute.'
  [[ ! -L $path ]] || ops_die "Refusing to replace dependency symlink: $path"
  case $path in
    "$OPS_ROOT" | "$OPS_ROOT"/*) ops_die 'Dependency binaries cannot be installed inside the toolkit tree.' ;;
  esac
}

ops_xray_install_host_binary() {
  local arch asset base temp expected parent probe
  ops_ensure_commands 'Local Xray installation' 'curl|curl|curl' 'unzip|unzip|unzip' 'sha256sum|coreutils|coreutils'
  case $OPS_ARCH in
    x86_64 | amd64) arch=64 ;;
    aarch64 | arm64) arch=arm64-v8a ;;
    *) ops_die "Xray does not publish a Linux asset for architecture: $OPS_ARCH" ;;
  esac
  asset=Xray-linux-$arch.zip
  base=https://github.com/XTLS/Xray-core/releases/latest/download
  ops_xray_assert_binary_target "$OPS_XRAY_BIN"
  ops_confirm "Download and install the latest official Xray binary to $OPS_XRAY_BIN?"
  parent=$(dirname -- "$OPS_XRAY_BIN")
  if ((OPS_DRY_RUN)); then
    ops_log "Would download $base/$asset and verify $base/$asset.dgst"
    ops_log "Would install Xray to $OPS_XRAY_BIN"
    return 0
  fi
  if ((EUID != 0)); then
    probe=$parent
    while [[ ! -d $probe && $probe != / ]]; do probe=$(dirname -- "$probe"); done
    [[ -w $probe ]] || ops_die "Cannot write $parent; configure OPS_XRAY_BIN under a writable bin directory or run as root."
  fi
  temp=$(mktemp -d)
  ops_download "$base/$asset" "$temp/$asset"
  ops_download "$base/$asset.dgst" "$temp/$asset.dgst"
  expected=$(awk '{for (i=1;i<=NF;i++) if ($i ~ /^[0-9a-fA-F]{64}$/) {print tolower($i); exit}}' "$temp/$asset.dgst")
  [[ $expected =~ ^[0-9a-f]{64}$ ]] || {
    rm -rf "$temp"
    ops_die 'Official Xray digest did not contain SHA-256.'
  }
  ops_verify_sha256 "$temp/$asset" "$expected"
  unzip -q "$temp/$asset" xray -d "$temp/unpacked"
  "$temp/unpacked/xray" version >/dev/null || {
    rm -rf "$temp"
    ops_die 'Downloaded Xray binary failed its version check.'
  }
  install -d -m 0755 "$parent"
  if [[ -f $OPS_XRAY_BIN && ! -L $OPS_XRAY_BIN ]]; then
    cp -p "$OPS_XRAY_BIN" "$OPS_XRAY_BIN.bak"
  fi
  install -m 0755 "$temp/unpacked/xray" "$OPS_XRAY_BIN"
  rm -rf "$temp"
  ops_log "Installed $(ops_xray_host_exec version | sed -n '1p') at $OPS_XRAY_BIN"
}

ops_xray_install_singbox_binary() {
  local arch json tag version asset url digest temp binary
  ops_ensure_commands 'Local sing-box installation' 'curl|curl|curl' 'jq|jq|jq' 'tar|tar|tar' 'sha256sum|coreutils|coreutils'
  case $OPS_ARCH in
    x86_64 | amd64) arch=amd64 ;;
    aarch64 | arm64) arch=arm64 ;;
    *) ops_die "sing-box does not publish a supported Linux asset for architecture: $OPS_ARCH" ;;
  esac
  ops_xray_assert_binary_target "$OPS_SING_BOX_BIN"
  json=$(curl -fsSL --connect-timeout 10 https://api.github.com/repos/SagerNet/sing-box/releases/latest) || ops_die 'Unable to query the latest sing-box release.'
  tag=$(jq -r '.tag_name // empty' <<<"$json")
  version=${tag#v}
  asset=sing-box-$version-linux-$arch.tar.gz
  url=$(jq -r --arg name "$asset" '.assets[] | select(.name == $name) | .browser_download_url' <<<"$json")
  digest=$(jq -r --arg name "$asset" '.assets[] | select(.name == $name) | (.digest // "")' <<<"$json")
  digest=${digest#sha256:}
  [[ $url == https://* && $digest =~ ^[0-9a-fA-F]{64}$ ]] || ops_die "Unable to find a verifiable sing-box asset: $asset"
  ops_confirm "Download and install sing-box $tag to $OPS_SING_BOX_BIN?"
  if ((OPS_DRY_RUN)); then
    ops_log "Would download $url, verify SHA-256, and install $OPS_SING_BOX_BIN."
    return 0
  fi
  temp=$(mktemp -d)
  ops_download "$url" "$temp/$asset"
  ops_verify_sha256 "$temp/$asset" "${digest,,}"
  tar -xzf "$temp/$asset" -C "$temp"
  binary=$(find "$temp" -type f -name sing-box -perm -u+x -print -quit)
  [[ -n $binary ]] || {
    rm -rf "$temp"
    ops_die 'The sing-box archive did not contain an executable.'
  }
  install -d -m 0755 "$(dirname -- "$OPS_SING_BOX_BIN")"
  [[ ! -f $OPS_SING_BOX_BIN ]] || cp -p "$OPS_SING_BOX_BIN" "$OPS_SING_BOX_BIN.bak"
  install -m 0755 "$binary" "$OPS_SING_BOX_BIN"
  rm -rf "$temp"
  ops_log "Installed $(ops_xray_singbox_exec version | sed -n '1p') at $OPS_SING_BOX_BIN"
}

ops_xray_ensure_host_binary() {
  if ops_xray_host_binary >/dev/null 2>&1; then
    return 0
  fi
  ops_warn 'Local Xray binary is missing; configuration generation requires it.'
  ops_xray_install_host_binary
  ((OPS_DRY_RUN)) || ops_xray_host_binary >/dev/null 2>&1 || ops_die 'Xray installation completed but the local binary is still unavailable.'
}

ops_xray_ensure_singbox_binary() {
  if ops_xray_singbox_binary >/dev/null 2>&1; then return 0; fi
  ops_warn 'Local sing-box binary is missing; sing-reality generation requires it.'
  ops_xray_install_singbox_binary
  ((OPS_DRY_RUN)) || ops_xray_singbox_binary >/dev/null 2>&1 || ops_die 'sing-box installation completed but the local binary is still unavailable.'
}

ops_xray_ensure_jq() {
  ops_ensure_commands 'Xray management' 'jq|jq|jq'
}

ops_xray_release_asset() {
  local repository=$1 asset_name=$2 json
  local -n url_result=$3 digest_result=$4 tag_result=$5
  json=$(curl -fsSL --connect-timeout 10 "https://api.github.com/repos/$repository/releases/latest") || ops_die "Unable to query latest release for $repository"
  tag_result=$(jq -r '.tag_name // empty' <<<"$json")
  url_result=$(jq -r --arg name "$asset_name" '.assets[] | select(.name == $name) | .browser_download_url' <<<"$json")
  digest_result=$(jq -r --arg name "$asset_name" '.assets[] | select(.name == $name) | (.digest // "")' <<<"$json")
  digest_result=${digest_result#sha256:}
  [[ -n $tag_result && $url_result == https://* ]] || ops_die "Latest release asset not found: $repository/$asset_name"
  [[ $digest_result =~ ^[0-9a-fA-F]{64}$ ]] || ops_die "GitHub did not provide a SHA-256 digest for $asset_name"
}

ops_xray_install_scan_tools() {
  local arch scanner_asset checker_asset scanner_url scanner_digest scanner_tag
  local checker_url checker_digest checker_tag temp
  ops_ensure_commands 'Reality scanner installation' 'curl|curl|curl' 'jq|jq|jq' 'unzip|unzip|unzip'
  case $OPS_ARCH in
    x86_64 | amd64) arch=amd64 ;;
    aarch64 | arm64) arch=arm64 ;;
    *) ops_die "Reality scanner does not publish an asset for architecture: $OPS_ARCH" ;;
  esac
  scanner_asset=RealiTLScanner-linux-$arch
  checker_asset=reality-checker-linux-$arch.zip
  ops_xray_assert_binary_target "$OPS_XRAY_SCANNER"
  ops_xray_assert_binary_target "$OPS_XRAY_CHECKER"
  ops_xray_release_asset XTLS/RealiTLScanner "$scanner_asset" scanner_url scanner_digest scanner_tag
  ops_xray_release_asset V2RaySSR/RealityChecker "$checker_asset" checker_url checker_digest checker_tag
  ops_confirm "Install Reality scanner $scanner_tag and checker $checker_tag for $arch?"
  if ((OPS_DRY_RUN == 0 && EUID != 0)); then
    local scanner_parent checker_parent
    scanner_parent=$(dirname -- "$OPS_XRAY_SCANNER")
    checker_parent=$(dirname -- "$OPS_XRAY_CHECKER")
    while [[ ! -d $scanner_parent && $scanner_parent != / ]]; do scanner_parent=$(dirname -- "$scanner_parent"); done
    while [[ ! -d $checker_parent && $checker_parent != / ]]; do checker_parent=$(dirname -- "$checker_parent"); done
    if [[ ! -w $scanner_parent || ! -w $checker_parent ]]; then
      ops_die 'Root permission is required to install Reality scanner dependencies at the configured paths.'
    fi
  fi
  if ((OPS_DRY_RUN)); then
    ops_log "Would verify and install $scanner_url to $OPS_XRAY_SCANNER"
    ops_log "Would verify and install $checker_url to $OPS_XRAY_CHECKER"
    return 0
  fi
  temp=$(mktemp -d)
  ops_download "$scanner_url" "$temp/$scanner_asset"
  ops_verify_sha256 "$temp/$scanner_asset" "${scanner_digest,,}"
  ops_download "$checker_url" "$temp/$checker_asset"
  ops_verify_sha256 "$temp/$checker_asset" "${checker_digest,,}"
  unzip -q "$temp/$checker_asset" reality-checker -d "$temp/checker"
  install -d -m 0755 "$(dirname -- "$OPS_XRAY_SCANNER")" "$(dirname -- "$OPS_XRAY_CHECKER")"
  install -m 0755 "$temp/$scanner_asset" "$OPS_XRAY_SCANNER"
  install -m 0755 "$temp/checker/reality-checker" "$OPS_XRAY_CHECKER"
  rm -rf "$temp"
  ops_log "Installed Reality scanner $scanner_tag: $OPS_XRAY_SCANNER"
  ops_log "Installed Reality checker $checker_tag: $OPS_XRAY_CHECKER"
}

ops_xray_assert_external_path() {
  local path=$1
  [[ $path == /* ]] || ops_die 'Identity-bearing output paths must be absolute.'
  [[ ! -L $path ]] || ops_die 'Output may not be a symbolic link.'
  case $path in
    "$OPS_ROOT" | "$OPS_ROOT"/*) ops_die 'Identity-bearing output cannot be written inside the toolkit tree.' ;;
  esac
}

ops_xray_apply_shared_permissions() {
  local file=$1 parent managed_root='' xray_root
  [[ -f $file && ! -L $file ]] || return 0
  parent=$(dirname -- "$file")
  xray_root=$(dirname -- "$OPS_XRAY_CONFIG")
  case $file in
    "$xray_root" | "$xray_root"/*) managed_root=$xray_root ;;
    "$OPS_XRAY_LOG_DIR" | "$OPS_XRAY_LOG_DIR"/*) managed_root=$OPS_XRAY_LOG_DIR ;;
  esac
  if getent group "$OPS_DOCKER_GROUP" >/dev/null 2>&1; then
    if [[ -n $managed_root ]]; then
      chgrp -R "$OPS_DOCKER_GROUP" "$managed_root" 2>/dev/null || ops_warn "Could not assign group $OPS_DOCKER_GROUP to $managed_root"
    else
      chgrp "$OPS_DOCKER_GROUP" "$file" "$parent" 2>/dev/null || ops_warn "Could not assign group $OPS_DOCKER_GROUP to $file"
    fi
  elif ((EUID == 0)); then
    case $OPS_OS_FAMILY in
      debian) groupadd --system "$OPS_DOCKER_GROUP" ;;
      alpine) addgroup -S "$OPS_DOCKER_GROUP" ;;
    esac
    if [[ -n $managed_root ]]; then chgrp -R "$OPS_DOCKER_GROUP" "$managed_root"; else chgrp "$OPS_DOCKER_GROUP" "$file" "$parent"; fi
  else
    ops_warn "Group $OPS_DOCKER_GROUP does not exist; preserving the current group."
  fi
  if [[ -n $managed_root ]]; then
    find "$managed_root" -type d -exec chmod 2775 {} +
    find "$managed_root" -type f -exec chmod 0664 {} +
  else
    chmod 2775 "$parent"
    chmod 0664 "$file"
  fi
}

ops_xray_set_value() {
  local key=$1 value=$2
  case $key in
    XRAY_UUID | XRAY_PRIVATE_KEY | XRAY_PUBLIC_KEY | XRAY_SERVER_NAME | XRAY_SHORT_ID | XRAY_PORT | XRAY_TARGET)
      printf -v "$key" '%s' "$value"
      ;;
    *) ops_die "Unknown Xray configuration key: $key" ;;
  esac
}

ops_xray_load_env() {
  local file=$1 mode owner line key value
  [[ -f $file && ! -L $file ]] || ops_die 'Xray env file must be a regular, non-symlink file.'
  mode=$(stat -c '%a' "$file")
  owner=$(stat -c '%u' "$file")
  (((8#$mode & 8#077) == 0)) || ops_die 'Xray env file must not be accessible by group or others.'
  [[ $owner == "$EUID" ]] || ops_die 'Xray env file must be owned by the current user.'
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ -z $line || $line == '#'* ]] && continue
    [[ $line == *=* ]] || ops_die 'Invalid Xray env line.'
    key=${line%%=*}
    value=${line#*=}
    [[ $key =~ ^XRAY_[A-Z_]+$ ]] || ops_die 'Invalid Xray env key.'
    ops_xray_set_value "$key" "$value"
  done <"$file"
}

ops_xray_validate_identity() {
  [[ -n ${XRAY_UUID:-} ]] || ops_die 'XRAY_UUID is required.'
  [[ -n ${XRAY_PRIVATE_KEY:-} ]] || ops_die 'XRAY_PRIVATE_KEY is required.'
  [[ -n ${XRAY_SERVER_NAME:-} ]] || ops_die 'XRAY_SERVER_NAME is required.'
  [[ -n ${XRAY_SHORT_ID:-} ]] || ops_die 'XRAY_SHORT_ID is required.'
  : "${XRAY_PORT:=44301}"
  : "${XRAY_TARGET:=$XRAY_SERVER_NAME:443}"
  [[ $XRAY_UUID =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]] || ops_die 'XRAY_UUID is invalid.'
  [[ $XRAY_PRIVATE_KEY =~ ^[A-Za-z0-9_-]{20,128}$ ]] || ops_die 'XRAY_PRIVATE_KEY is invalid.'
  [[ -z ${XRAY_PUBLIC_KEY:-} || $XRAY_PUBLIC_KEY =~ ^[A-Za-z0-9_-]{20,128}$ ]] || ops_die 'XRAY_PUBLIC_KEY is invalid.'
  [[ $XRAY_SERVER_NAME =~ ^[A-Za-z0-9.-]+$ ]] || ops_die 'XRAY_SERVER_NAME is invalid.'
  [[ $XRAY_SHORT_ID =~ ^[0-9a-fA-F]{2,16}$ ]] || ops_die 'XRAY_SHORT_ID must be 2-16 hexadecimal characters.'
  ops_validate_port "$XRAY_PORT" || ops_die 'XRAY_PORT is invalid.'
  [[ $XRAY_TARGET =~ ^[A-Za-z0-9.-]+:[0-9]+$ ]] || ops_die 'XRAY_TARGET must be HOST:PORT.'
  ops_validate_port "${XRAY_TARGET##*:}" || ops_die 'XRAY_TARGET port is invalid.'
}

ops_xray_public_key() {
  local private_key=$1 runner=${2:-container} output public_key
  case $runner in
    host) output=$(ops_xray_host_exec x25519 -i "$private_key") ;;
    container) output=$(ops_xray_exec x25519 -i "$private_key") ;;
    *) ops_die "Unknown Xray execution context: $runner" ;;
  esac
  public_key=$(awk -F': *' '/^(Password|Password \(PublicKey\)|PublicKey|Public key):/{print $2; exit}' <<<"$output")
  [[ -n $public_key ]] || ops_die 'Unable to derive the X25519 public key.'
  printf '%s\n' "$public_key"
}

ops_xray_auto_identity() {
  local server_name=$1 target=$2 port=$3 output
  output=$(ops_xray_host_exec x25519)
  XRAY_PRIVATE_KEY=$(awk -F': *' '/^(PrivateKey|Private key):/{print $2; exit}' <<<"$output")
  [[ -n $XRAY_PRIVATE_KEY ]] || ops_die 'Unable to generate the X25519 private key.'
  XRAY_UUID=$(ops_xray_host_exec uuid | tr -d '[:space:]')
  XRAY_SHORT_ID=$(openssl rand -hex 8)
  XRAY_SERVER_NAME=$server_name
  XRAY_TARGET=${target:-$server_name:443}
  XRAY_PORT=$port
}

ops_xray_auto_identity_sing() {
  local server_name=$1 target=$2 port=$3 output
  output=$(ops_xray_singbox_exec generate reality-keypair)
  XRAY_PRIVATE_KEY=$(awk -F': *' '/^PrivateKey:/{print $2; exit}' <<<"$output")
  XRAY_PUBLIC_KEY=$(awk -F': *' '/^PublicKey:/{print $2; exit}' <<<"$output")
  [[ -n $XRAY_PRIVATE_KEY && -n $XRAY_PUBLIC_KEY ]] || ops_die 'Unable to generate the sing-box Reality key pair.'
  XRAY_UUID=$(ops_xray_singbox_exec generate uuid | tr -d '[:space:]')
  XRAY_SHORT_ID=$(ops_xray_singbox_exec generate rand 8 --hex | tr -d '[:space:]')
  XRAY_SERVER_NAME=$server_name
  XRAY_TARGET=${target:-$server_name:443}
  XRAY_PORT=$port
}

ops_xray_engine_for_file() {
  local file=$1
  if jq -e '.inbounds[0].protocol? != null' "$file" >/dev/null 2>&1; then
    printf 'xray\n'
  elif jq -e '.inbounds[0].type? != null' "$file" >/dev/null 2>&1; then
    printf 'sing-box\n'
  else
    printf 'json\n'
  fi
}

ops_xray_validate_file() {
  local file=$1 engine=${2:-auto} runner=${3:-container}
  ops_require_command jq
  jq empty "$file" || ops_die "Invalid JSON: $file"
  [[ $engine != auto ]] || engine=$(ops_xray_engine_for_file "$file")
  case $engine in
    xray)
      case $runner in
        host) ops_xray_host_exec run -test -format json -config "$file" >/dev/null || ops_die 'Local Xray rejected the configuration.' ;;
        container) docker exec -i "$OPS_XRAY_CONTAINER" xray run -test -format json -config stdin: <"$file" >/dev/null || ops_die 'Docker Xray rejected the configuration.' ;;
        *) ops_die "Unknown Xray validation context: $runner" ;;
      esac
      ;;
    sing-box)
      if ops_xray_singbox_binary >/dev/null 2>&1; then
        ops_xray_singbox_exec check -c "$file" >/dev/null || ops_die 'sing-box rejected the configuration.'
      else
        ops_warn 'sing-box is not installed; only JSON syntax was checked.'
      fi
      ;;
    json) ops_warn 'Unknown engine; only JSON syntax was checked.' ;;
    *) ops_die "Unknown validation engine: $engine" ;;
  esac
}

ops_xray_commit_json() {
  local source=$1 target=$2 backup=${3:-1} engine=${4:-auto} runner=${5:-container}
  local parent stage original_owner=''
  ops_xray_assert_external_path "$target"
  ops_xray_validate_file "$source" "$engine" "$runner"
  if ((OPS_DRY_RUN)); then
    ops_log "Would write validated configuration to $target"
    rm -f "$source"
    return 0
  fi
  parent=$(dirname -- "$target")
  if [[ -f $target && ! -L $target ]]; then original_owner=$(stat -c '%u:%g' "$target"); fi
  install -d -m 0750 "$parent"
  stage=$(mktemp "$parent/.ops-xray.XXXXXX")
  install -m 0664 "$source" "$stage"
  rm -f "$source"
  if ((backup)) && [[ -f $target && ! -L $target ]]; then
    cp -p "$target" "$target.bak"
    chmod 0600 "$target.bak"
  fi
  mv -f "$stage" "$target"
  if [[ -n $original_owner && $EUID == 0 ]]; then chown "$original_owner" "$target"; fi
  ops_xray_apply_shared_permissions "$target"
}

ops_xray_commit_text() {
  local source=$1 target=$2 parent stage original_owner=''
  ops_xray_assert_external_path "$target"
  if ((OPS_DRY_RUN)); then
    ops_log "Would write identity metadata to $target"
    rm -f "$source"
    return 0
  fi
  parent=$(dirname -- "$target")
  if [[ -f $target && ! -L $target ]]; then original_owner=$(stat -c '%u:%g' "$target"); fi
  install -d -m 0750 "$parent"
  stage=$(mktemp "$parent/.ops-xray.XXXXXX")
  install -m 0664 "$source" "$stage"
  rm -f "$source"
  mv -f "$stage" "$target"
  if [[ -n $original_owner && $EUID == 0 ]]; then chown "$original_owner" "$target"; fi
  ops_xray_apply_shared_permissions "$target"
}

ops_xray_deps() {
  local -a args
  local scan_tools=0 xray_binary=0 singbox_binary=0
  ops_parse_safety_flags args "$@"
  set -- "${args[@]}"
  while (($#)); do
    case $1 in
      --xray)
        xray_binary=1
        shift
        ;;
      --scan-tools)
        scan_tools=1
        shift
        ;;
      --sing-box)
        singbox_binary=1
        shift
        ;;
      *) ops_die "Unknown deps option: $1" ;;
    esac
  done
  ops_ensure_commands 'Xray management' \
    'jq|jq|jq' 'openssl|openssl|openssl' 'curl|curl|curl' \
    'unzip|unzip|unzip' 'timeout|coreutils|coreutils'
  ((xray_binary == 0)) || ops_xray_install_host_binary
  ((singbox_binary == 0)) || ops_xray_install_singbox_binary
  ((scan_tools == 0)) || ops_xray_install_scan_tools
}

ops_xray_generate() {
  local -a args
  local type=${1:-} env_file='' output=$OPS_XRAY_CONFIG server_name='' target='' port=44301
  local client_output='' write_client=0 template program temp client_temp public_key=''
  [[ -n $type ]] || ops_die 'Xray template type is required.'
  shift || true
  ops_parse_safety_flags args "$@"
  set -- "${args[@]}"
  while (($#)); do
    case $1 in
      --env-file)
        env_file=${2:?}
        shift 2
        ;;
      --output)
        output=${2:?}
        shift 2
        ;;
      --server-name)
        server_name=${2:?}
        shift 2
        ;;
      --target)
        target=${2:?}
        shift 2
        ;;
      --port)
        port=${2:?}
        shift 2
        ;;
      --client-output)
        client_output=${2:?}
        write_client=1
        shift 2
        ;;
      --no-client-output)
        write_client=0
        shift
        ;;
      *) ops_die "Unknown generate option: $1" ;;
    esac
  done
  if [[ $type == sing-reality ]]; then
    ops_ensure_commands 'sing-box configuration generation' 'jq|jq|jq'
    ops_xray_ensure_singbox_binary
  else
    if [[ -n $env_file ]]; then ops_ensure_commands 'Xray configuration generation' 'jq|jq|jq'; else ops_ensure_commands 'Xray configuration generation' 'jq|jq|jq' 'openssl|openssl|openssl'; fi
    ops_xray_ensure_host_binary
  fi
  if ((OPS_DRY_RUN)) && { [[ $type == sing-reality ]] && ! ops_xray_singbox_binary >/dev/null 2>&1 || [[ $type != sing-reality ]] && ! ops_xray_host_binary >/dev/null 2>&1; }; then
    ops_log "Would generate $type configuration after installing the local engine."
    return 0
  fi
  unset XRAY_UUID XRAY_PRIVATE_KEY XRAY_PUBLIC_KEY XRAY_SERVER_NAME XRAY_SHORT_ID XRAY_PORT XRAY_TARGET || true
  if [[ -n $env_file ]]; then
    ops_xray_load_env "$env_file"
  else
    [[ -n $server_name ]] || ops_die '--server-name is required when --env-file is omitted.'
    if [[ $type == sing-reality ]]; then ops_xray_auto_identity_sing "$server_name" "$target" "$port"; else ops_xray_auto_identity "$server_name" "$target" "$port"; fi
  fi
  ops_xray_validate_identity
  if [[ -e $output || -L $output ]]; then
    [[ ! -L $output ]] || ops_die 'Output may not be a symbolic link.'
    ops_confirm "Overwrite $output after saving $output.bak?"
  fi
  case $type in
    reality)
      template=$OPS_ROOT/tools/xray/templates/reality.json
      # shellcheck disable=SC2016
      program='.inbounds[0].port=$port | .inbounds[0].settings.clients[0].id=$uuid | .inbounds[0].streamSettings.realitySettings.target=$target | .inbounds[0].streamSettings.realitySettings.serverNames=[$server] | .inbounds[0].streamSettings.realitySettings.privateKey=$key | .inbounds[0].streamSettings.realitySettings.shortIds=[$short]'
      ;;
    xhttp)
      template=$OPS_ROOT/tools/xray/templates/xhttp.json
      # shellcheck disable=SC2016
      program='.inbounds[0].port=$port | .inbounds[0].settings.clients[0].id=$uuid | .inbounds[0].streamSettings.realitySettings.dest=$target | .inbounds[0].streamSettings.realitySettings.serverNames=[$server] | .inbounds[0].streamSettings.realitySettings.privateKey=$key | .inbounds[0].streamSettings.realitySettings.shortIds=[$short]'
      ;;
    sing-reality)
      template=$OPS_ROOT/tools/xray/templates/sing-reality.json
      # shellcheck disable=SC2016
      program='.inbounds[0].listen_port=$port | .inbounds[0].users[0].uuid=$uuid | .inbounds[0].tls.server_name=$server | .inbounds[0].tls.reality.handshake.server=($target | split(":")[0]) | .inbounds[0].tls.reality.handshake.server_port=($target | split(":")[1] | tonumber) | .inbounds[0].tls.reality.private_key=$key | .inbounds[0].tls.reality.short_id=[$short]'
      ;;
    *) ops_die "Unknown Xray template type: $type" ;;
  esac
  temp=$(mktemp)
  jq --arg uuid "$XRAY_UUID" --arg key "$XRAY_PRIVATE_KEY" \
    --arg server "$XRAY_SERVER_NAME" --arg short "$XRAY_SHORT_ID" \
    --arg target "$XRAY_TARGET" --argjson port "$XRAY_PORT" \
    "$program" "$template" >"$temp"
  ops_xray_commit_json "$temp" "$output" 1 auto host
  if [[ -n ${XRAY_PUBLIC_KEY:-} ]]; then
    public_key=$XRAY_PUBLIC_KEY
  else
    ops_xray_ensure_host_binary
    public_key=$(ops_xray_public_key "$XRAY_PRIVATE_KEY" host)
  fi
  if ((write_client)); then
    client_temp=$(mktemp)
    printf '%s\n' \
      "XRAY_UUID=$XRAY_UUID" \
      "XRAY_PUBLIC_KEY=$public_key" \
      "XRAY_SERVER_NAME=$XRAY_SERVER_NAME" \
      "XRAY_SHORT_ID=$XRAY_SHORT_ID" \
      "XRAY_PORT=$XRAY_PORT" >"$client_temp"
    ops_xray_commit_text "$client_temp" "$client_output"
  fi
  ops_log "Generated $type server configuration: $output"
  printf '\n%s\n' '════════════════ Xray client parameters ════════════════'
  printf 'UUID:       %s\n' "$XRAY_UUID"
  printf 'Public Key: %s\n' "$public_key"
  printf 'Short ID:   %s\n' "$XRAY_SHORT_ID"
  printf 'SNI:        %s\n' "$XRAY_SERVER_NAME"
  printf 'Port:       %s\n' "$XRAY_PORT"
  printf '%s\n\n' '════════════════════════════════════════════════════════'
  ((write_client == 0)) || ops_log "Generated optional client metadata: $client_output"
}

ops_xray_validate_command() {
  local -a args
  local config=$OPS_XRAY_CONFIG engine=auto
  ops_parse_safety_flags args "$@"
  set -- "${args[@]}"
  while (($#)); do
    case $1 in
      --config)
        config=${2:?}
        shift 2
        ;;
      --engine)
        engine=${2:?}
        shift 2
        ;;
      *) ops_die "Unknown validate option: $1" ;;
    esac
  done
  ops_xray_ensure_jq
  [[ -f $config && ! -L $config ]] || ops_die "Configuration not found: $config"
  ops_xray_validate_file "$config" "$engine"
  ops_log "Configuration is valid: $config"
}

ops_xray_status() {
  local config=$OPS_XRAY_CONFIG binary
  while (($#)); do
    case $1 in
      --config)
        config=${2:?}
        shift 2
        ;;
      *) ops_die "Unknown status option: $1" ;;
    esac
  done
  if binary=$(ops_xray_host_binary); then
    printf 'local_xray=%s\n' "$binary"
    printf 'local_xray_version='
    "$binary" version | sed -n '1p'
  else
    printf 'local_xray=%s (missing)\n' "$OPS_XRAY_BIN"
  fi
  if ops_xray_container_running; then
    printf 'xray_container=%s\n' "$OPS_XRAY_CONTAINER"
    printf 'xray='
    ops_xray_exec version | sed -n '1p'
  else
    printf 'xray_container=%s (missing-or-stopped)\n' "$OPS_XRAY_CONTAINER"
  fi
  if [[ -f $config && ! -L $config ]]; then
    if ! ops_has jq; then
      printf 'config=%s (present, jq-missing)\n' "$config"
    elif jq empty "$config" >/dev/null 2>&1; then
      printf 'config=%s (valid-json, mode=%s)\n' "$config" "$(stat -c '%a' "$config")"
    else
      printf 'config=%s (invalid-json)\n' "$config"
    fi
  else
    printf 'config=%s (missing)\n' "$config"
  fi
  if ops_has docker && docker inspect "$OPS_XRAY_CONTAINER" >/dev/null 2>&1; then
    docker inspect --format='container={{.Name}} status={{.State.Status}}' "$OPS_XRAY_CONTAINER"
  else
    printf 'container=%s (unavailable)\n' "$OPS_XRAY_CONTAINER"
  fi
}

ops_xray_view() {
  local -a args
  local config=$OPS_XRAY_CONFIG full=0 private_key public_key='' file_size file_mtime
  ops_parse_safety_flags args "$@"
  set -- "${args[@]}"
  while (($#)); do
    case $1 in
      --config)
        config=${2:?}
        shift 2
        ;;
      --full)
        full=1
        shift
        ;;
      *) ops_die "Unknown view option: $1" ;;
    esac
  done
  ops_xray_ensure_jq
  [[ -f $config && ! -L $config ]] || ops_die "Configuration not found: $config"
  if ((full)); then
    ops_confirm 'Print the complete configuration, including private identity material?'
    jq . "$config"
    return
  fi
  file_size=$(du -h "$config" | awk '{print $1}')
  file_mtime=$(stat -c '%y' "$config" | cut -d. -f1)
  printf 'config=%s\nsize=%s\nmodified=%s\n' "$config" "$file_size" "$file_mtime"
  jq -r '
    "engine=" + (if .inbounds[0].protocol? then "xray" else "sing-box" end),
    "port=" + ((.inbounds[0].port // .inbounds[0].listen_port // "unset") | tostring),
    "server_name=" + (.inbounds[0].streamSettings.realitySettings.serverNames[0] // .inbounds[0].tls.server_name // "unset"),
    "short_id=" + (.inbounds[0].streamSettings.realitySettings.shortIds[0] // .inbounds[0].tls.reality.short_id[0] // "unset"),
    "uuid=" + (.inbounds[0].settings.clients[0].id // .inbounds[0].users[0].uuid // "unset"),
    "clients=" + ((.inbounds[0].settings.clients // .inbounds[0].users // []) | length | tostring),
    "reverse_connections=" + ([.inbounds[0].settings.clients[]? | select(.reverse != null)] | length | tostring)
  ' "$config"
  private_key=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey // .inbounds[0].tls.reality.private_key // empty' "$config")
  if [[ -n $private_key ]]; then
    public_key=$(ops_xray_public_key "$private_key")
    printf 'public_key=%s\n' "$public_key"
  fi
}

ops_xray_restart() {
  local -a args containers
  local scope=xray container
  ops_parse_safety_flags args "$@"
  ((${#args[@]} <= 1)) || ops_die 'Usage: opsctl xray restart [xray|all]'
  ((${#args[@]} == 0)) || scope=${args[0]}
  case $scope in
    xray) containers=("$OPS_XRAY_CONTAINER") ;;
    all) containers=("$OPS_XRAY_CONTAINER" "$OPS_NGINX_CONTAINER") ;;
    *) ops_die 'Restart scope must be xray or all.' ;;
  esac
  ops_confirm "Restart container scope '$scope'?"
  ((OPS_DRY_RUN)) || ops_require_command docker
  for container in "${containers[@]}"; do
    ops_validate_container "$container" || ops_die "Invalid container name: $container"
    if ((OPS_DRY_RUN == 0)); then
      docker inspect "$container" >/dev/null 2>&1 || ops_die "Container not found: $container"
    fi
    ops_run docker restart "$container"
    ops_log "Restarted container: $container"
  done
}

ops_xray_rollback() {
  local -a args
  local config=$OPS_XRAY_CONFIG restart=0 current
  ops_parse_safety_flags args "$@"
  set -- "${args[@]}"
  while (($#)); do
    case $1 in
      --config)
        config=${2:?}
        shift 2
        ;;
      --restart)
        restart=1
        shift
        ;;
      *) ops_die "Unknown rollback option: $1" ;;
    esac
  done
  ops_xray_ensure_jq
  [[ -f $config.bak && ! -L $config.bak ]] || ops_die "Rollback file not found: $config.bak"
  ops_xray_validate_file "$config.bak"
  ops_confirm "Restore $config.bak to $config?"
  if ((OPS_DRY_RUN)); then
    ops_log "Would restore $config.bak"
  else
    current=$(mktemp)
    [[ ! -f $config ]] || cp -p "$config" "$current"
    install -m 0600 "$config.bak" "$config"
    if [[ -s $current ]]; then
      install -m 0600 "$current" "$config.bak"
    fi
    rm -f "$current"
    ops_xray_apply_shared_permissions "$config"
    ops_log "Restored configuration: $config"
  fi
  if ((restart)); then
    local -a restart_args=(xray --yes)
    ((OPS_DRY_RUN == 0)) || restart_args+=(--dry-run)
    ops_xray_restart "${restart_args[@]}"
  fi
}

ops_xray_sni_set() {
  local -a args restart_args
  local domain=${1:-} config=$OPS_XRAY_CONFIG nginx_stream=$OPS_NGINX_STREAM_CONFIG restart=0 temp nginx_temp
  [[ -n $domain ]] || ops_die 'A new SNI domain is required.'
  shift || true
  ops_parse_safety_flags args "$@"
  set -- "${args[@]}"
  while (($#)); do
    case $1 in
      --config)
        config=${2:?}
        shift 2
        ;;
      --nginx-stream)
        nginx_stream=${2:?}
        shift 2
        ;;
      --restart)
        restart=1
        shift
        ;;
      *) ops_die "Unknown sni option: $1" ;;
    esac
  done
  ops_xray_ensure_jq
  [[ $domain =~ ^[A-Za-z0-9.-]+$ ]] || ops_die 'Invalid SNI domain.'
  [[ -f $config && ! -L $config ]] || ops_die "Configuration not found: $config"
  ops_confirm "Change Reality SNI to $domain?"
  temp=$(mktemp)
  # shellcheck disable=SC2016
  jq --arg destination "$domain:443" --arg server "$domain" \
    '.inbounds[0].streamSettings.realitySettings |=
       (if has("target") then .target=$destination else .dest=$destination end) |
     .inbounds[0].streamSettings.realitySettings.serverNames=[$server]' \
    "$config" >"$temp"
  ops_xray_commit_json "$temp" "$config"
  if [[ -f $nginx_stream && ! -L $nginx_stream ]]; then
    if ((OPS_DRY_RUN)); then
      ops_log "Would update Nginx stream mapping in $nginx_stream"
    else
      nginx_temp=$(mktemp)
      sed -E "s#^([[:space:]]*)[^[:space:];]+([[:space:]]+reality;)#\1$domain\2#" "$nginx_stream" >"$nginx_temp"
      if cmp -s "$nginx_stream" "$nginx_temp"; then
        rm -f "$nginx_temp"
        ops_warn 'No Nginx stream line ending in reality; was found.'
      else
        cp -p "$nginx_stream" "$nginx_stream.bak"
        install -m 0644 "$nginx_temp" "$nginx_stream"
        rm -f "$nginx_temp"
      fi
    fi
  else
    ops_warn "Nginx stream configuration not found; only Xray was updated: $nginx_stream"
  fi
  if ((restart)); then
    restart_args=(all --yes)
    ((OPS_DRY_RUN == 0)) || restart_args+=(--dry-run)
    ops_xray_restart "${restart_args[@]}"
  fi
  ops_log "Reality SNI updated to $domain"
}

ops_xray_scan() {
  local -a args
  local target=auto scanner=$OPS_XRAY_SCANNER checker=$OPS_XRAY_CHECKER
  local minutes=3 threads=100 output_dir=$OPS_XRAY_LOG_DIR safe_target csv result status
  ops_parse_safety_flags args "$@"
  set -- "${args[@]}"
  while (($#)); do
    case $1 in
      --target)
        target=${2:?}
        shift 2
        ;;
      --scanner)
        scanner=${2:?}
        shift 2
        ;;
      --checker)
        checker=${2:?}
        shift 2
        ;;
      --minutes)
        minutes=${2:?}
        shift 2
        ;;
      --threads)
        threads=${2:?}
        shift 2
        ;;
      --output-dir)
        output_dir=${2:?}
        shift 2
        ;;
      *) ops_die "Unknown scan option: $1" ;;
    esac
  done
  ops_ensure_commands 'Reality scanning' 'curl|curl|curl' 'jq|jq|jq' 'timeout|coreutils|coreutils' 'unzip|unzip|unzip'
  if [[ ! -x $scanner || ! -x $checker ]]; then
    [[ $scanner == "$OPS_XRAY_SCANNER" && $checker == "$OPS_XRAY_CHECKER" ]] || ops_die 'A custom scanner/checker path is missing or not executable.'
    ops_warn 'Reality scanner or checker is missing.'
    ops_xray_install_scan_tools
  fi
  [[ $minutes =~ ^[1-9][0-9]*$ ]] || ops_die '--minutes must be a positive integer.'
  if [[ ! $threads =~ ^[1-9][0-9]*$ ]] || ((threads > 1000)); then
    ops_die '--threads must be between 1 and 1000.'
  fi
  ops_validate_absolute_path "$output_dir" || ops_die '--output-dir must be an absolute safe path.'
  if [[ $target == auto ]]; then
    ops_require_command curl
    target=$(curl -fsSL --connect-timeout 10 https://api.ipify.org)
  fi
  [[ $target =~ ^[A-Za-z0-9:.-]+$ ]] || ops_die 'Invalid scan target.'
  if ((OPS_DRY_RUN)); then
    ops_log "Would use scanner: $scanner"
    ops_log "Would use checker: $checker"
  else
    [[ -f $scanner && -x $scanner && ! -L $scanner ]] || ops_die '--scanner must be an executable, non-symlink file.'
    [[ -f $checker && -x $checker && ! -L $checker ]] || ops_die '--checker must be an executable, non-symlink file.'
  fi
  ops_confirm "Execute the Reality scanner against $target?"
  if ((OPS_DRY_RUN)); then
    ops_log "Would scan $target for $minutes minute(s) with $threads threads into $output_dir"
    return 0
  fi
  ops_require_command timeout
  install -d -m 0750 "$output_dir"
  safe_target=$(tr ':/' '__' <<<"$target" | tr -cd 'A-Za-z0-9_.-')
  csv=$output_dir/$safe_target.csv
  set +e
  timeout "${minutes}m" "$scanner" -addr "$target" -port 443 -thread "$threads" -timeout 5 -out "$csv"
  status=$?
  set -e
  if ((status != 0 && status != 124)); then ops_warn "Reality scanner exited with status $status; preserving any CSV output."; fi
  [[ -s $csv ]] || {
    ops_die 'Reality scanner produced no CSV results.'
  }
  chmod 0600 "$csv"
  result=$output_dir/scan_result.txt
  "$checker" csv "$csv" 2>&1 | sed $'s/\033\[[0-9;]*m//g' | tee "$result"
  chmod 0600 "$result"
  ops_xray_apply_shared_permissions "$csv"
  ops_xray_apply_shared_permissions "$result"
  ops_log "Reality checker output: $result"
  ops_log "Reality scan CSV: $csv"
}

ops_xray_reverse_require_config() {
  local config=$1
  [[ -f $config && ! -L $config ]] || ops_die "Configuration not found: $config"
  jq -e '.inbounds[0].settings.clients | type == "array"' "$config" >/dev/null || ops_die 'Reverse management requires an Xray VLESS server configuration.'
}

ops_xray_mask_uuid() {
  local value=$1
  if ((${#value} > 12)); then
    printf '%s…%s' "${value:0:8}" "${value: -4}"
  else
    printf '***'
  fi
}

ops_xray_reverse_list() {
  local -a args
  local config=$OPS_XRAY_CONFIG name tag portal_uuid bridge_uuid found=0
  ops_parse_safety_flags args "$@"
  set -- "${args[@]}"
  while (($#)); do
    case $1 in
      --config)
        config=${2:?}
        shift 2
        ;;
      *) ops_die "Unknown reverse list option: $1" ;;
    esac
  done
  ops_xray_ensure_jq
  ops_xray_reverse_require_config "$config"
  while IFS=$'\t' read -r name tag portal_uuid; do
    [[ -n $name ]] || continue
    found=1
    bridge_uuid=$(jq -r --arg tag "$tag" '.inbounds[0].settings.clients[] | select(.email == $tag) | .id' "$config")
    printf 'name=%s\ntag=%s\nportal_uuid=%s\nbridge_uuid=%s\n---\n' "$name" "$tag" "$portal_uuid" "$bridge_uuid"
  done < <(jq -r '.inbounds[0].settings.clients[] | select(.reverse != null) | [.email, .reverse.tag, .id] | @tsv' "$config")
  ((found)) || ops_log 'No reverse connections configured.'
}

ops_xray_reverse_add() {
  local -a args restart_args
  local name=${1:-} config=$OPS_XRAY_CONFIG restart=0 next tag bridge_uuid portal_uuid temp
  [[ -n $name ]] || ops_die 'A reverse connection name is required.'
  shift || true
  ops_parse_safety_flags args "$@"
  set -- "${args[@]}"
  while (($#)); do
    case $1 in
      --config)
        config=${2:?}
        shift 2
        ;;
      --restart)
        restart=1
        shift
        ;;
      *) ops_die "Unknown reverse add option: $1" ;;
    esac
  done
  ops_xray_ensure_jq
  [[ $name =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || ops_die 'Reverse name may contain only letters, digits, dot, underscore and hyphen.'
  ops_xray_reverse_require_config "$config"
  jq -e --arg name "$name" '[.inbounds[0].settings.clients[] | select(.email == $name)] | length == 0' "$config" >/dev/null || ops_die "Reverse name already exists: $name"
  ops_confirm "Add reverse connection '$name'?"
  next=$(jq -r '[.inbounds[0].settings.clients[]?.email? | try capture("^reverse-out-(?<n>[0-9]+)$").n catch empty | tonumber] | if length == 0 then 1 else max + 1 end' "$config")
  tag=reverse-out-$next
  bridge_uuid=$(ops_xray_exec uuid | tr -d '[:space:]')
  portal_uuid=$(ops_xray_exec uuid | tr -d '[:space:]')
  [[ $bridge_uuid != "$portal_uuid" ]] || portal_uuid=$(ops_xray_exec uuid | tr -d '[:space:]')
  temp=$(mktemp)
  # shellcheck disable=SC2016
  jq --arg bridge "$bridge_uuid" --arg portal "$portal_uuid" --arg tag "$tag" --arg name "$name" '
    .inbounds[0].settings.clients[0].email = (.inbounds[0].settings.clients[0].email // "direct-in") |
    .outbounds = (.outbounds // []) |
    if ([.outbounds[] | select(.tag == "direct-out")] | length) == 0
      then .outbounds += [{"protocol":"freedom","tag":"direct-out"}] else . end |
    .routing = (.routing // {"domainStrategy":"AsIs","rules":[]}) |
    .routing.rules = (.routing.rules // []) |
    if ([.routing.rules[] | select(.outboundTag == "direct-out" and (.user // [] | index("direct-in")))] | length) == 0
      then .routing.rules = ([{"type":"field","user":["direct-in"],"outboundTag":"direct-out"}] + .routing.rules) else . end |
    .inbounds[0].settings.clients += [
      {"id":$bridge,"email":$tag,"flow":"xtls-rprx-vision"},
      {"id":$portal,"email":$name,"flow":"xtls-rprx-vision","reverse":{"tag":$tag}}
    ] |
    .routing.rules += [{"type":"field","user":[$tag],"outboundTag":$tag}]
  ' "$config" >"$temp"
  ops_xray_commit_json "$temp" "$config"
  ops_log "Added reverse connection '$name' with internal tag '$tag'."
  if ((restart)); then
    restart_args=(xray --yes)
    ((OPS_DRY_RUN == 0)) || restart_args+=(--dry-run)
    ops_xray_restart "${restart_args[@]}"
  fi
}

ops_xray_reverse_delete() {
  local -a args restart_args
  local name=${1:-} config=$OPS_XRAY_CONFIG restart=0 tag temp
  [[ -n $name ]] || ops_die 'A reverse connection name is required.'
  shift || true
  ops_parse_safety_flags args "$@"
  set -- "${args[@]}"
  while (($#)); do
    case $1 in
      --config)
        config=${2:?}
        shift 2
        ;;
      --restart)
        restart=1
        shift
        ;;
      *) ops_die "Unknown reverse delete option: $1" ;;
    esac
  done
  ops_xray_ensure_jq
  ops_xray_reverse_require_config "$config"
  tag=$(jq -r --arg name "$name" '.inbounds[0].settings.clients[] | select(.email == $name and .reverse != null) | .reverse.tag' "$config")
  [[ -n $tag ]] || ops_die "Reverse connection not found: $name"
  ops_confirm "Delete reverse connection '$name' and its bridge identity?"
  temp=$(mktemp)
  # shellcheck disable=SC2016
  jq --arg name "$name" --arg tag "$tag" '
    .inbounds[0].settings.clients |= map(select(.email != $name and .email != $tag)) |
    .routing.rules |= map(select(.outboundTag != $tag))
  ' "$config" >"$temp"
  ops_xray_commit_json "$temp" "$config"
  ops_log "Deleted reverse connection: $name"
  if ((restart)); then
    restart_args=(xray --yes)
    ((OPS_DRY_RUN == 0)) || restart_args+=(--dry-run)
    ops_xray_restart "${restart_args[@]}"
  fi
}

ops_xray_reverse_client() {
  local -a args
  local name=${1:-} config=$OPS_XRAY_CONFIG address='' output='' uuid tag private_key public_key server_name short_id port temp
  [[ -n $name ]] || ops_die 'A reverse connection name is required.'
  shift || true
  ops_parse_safety_flags args "$@"
  set -- "${args[@]}"
  while (($#)); do
    case $1 in
      --config)
        config=${2:?}
        shift 2
        ;;
      --address)
        address=${2:?}
        shift 2
        ;;
      --output)
        output=${2:?}
        shift 2
        ;;
      *) ops_die "Unknown reverse client option: $1" ;;
    esac
  done
  ops_xray_ensure_jq
  [[ -n $address ]] || ops_die '--address is required.'
  [[ $address =~ ^[A-Za-z0-9:.-]+$ ]] || ops_die 'Invalid server address.'
  ops_xray_reverse_require_config "$config"
  uuid=$(jq -r --arg name "$name" '.inbounds[0].settings.clients[] | select(.email == $name and .reverse != null) | .id' "$config")
  tag=$(jq -r --arg name "$name" '.inbounds[0].settings.clients[] | select(.email == $name and .reverse != null) | .reverse.tag' "$config")
  [[ -n $uuid && -n $tag ]] || ops_die "Reverse connection not found: $name"
  private_key=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$config")
  server_name=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$config")
  short_id=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$config")
  port=$(jq -r '.inbounds[0].port' "$config")
  public_key=$(ops_xray_public_key "$private_key")
  temp=$(mktemp)
  # shellcheck disable=SC2016
  jq --arg address "$address" --arg uuid "$uuid" --arg tag "$tag" \
    --arg server "$server_name" --arg public "$public_key" --arg short "$short_id" \
    --argjson port "$port" '
      .outbounds[] |= if .tag == "reality-out" then
        .settings.address=$address | .settings.port=$port | .settings.id=$uuid |
        .settings.reverse.tag=$tag | .streamSettings.realitySettings.serverName=$server |
        .streamSettings.realitySettings.password=$public |
        .streamSettings.realitySettings.shortId=$short
      else . end |
      .routing.rules[0].inboundTag=[$tag]
    ' "$OPS_ROOT/tools/xray/templates/reverse-client.json" >"$temp"
  if [[ -n $output ]]; then
    ops_xray_commit_json "$temp" "$output" 0 xray
    ops_log "Generated reverse client configuration: $output"
  else
    ops_xray_validate_file "$temp" xray container
    printf '\n%s\n' '════════════════ Reverse client configuration ════════════════'
    jq . "$temp"
    printf '%s\n\n' '═══════════════════════════════════════════════════════════════'
    rm -f "$temp"
  fi
}

ops_xray_reverse_main() {
  case ${1:-help} in
    list)
      shift
      ops_xray_reverse_list "$@"
      ;;
    add)
      shift
      ops_xray_reverse_add "$@"
      ;;
    delete)
      shift
      ops_xray_reverse_delete "$@"
      ;;
    client)
      shift
      ops_xray_reverse_client "$@"
      ;;
    help | --help | -h) ops_xray_help ;;
    *) ops_die "Unknown reverse command: $1" ;;
  esac
}

ops_xray_reverse_menu() {
  local choice name address output
  while true; do
    cat <<'EOF'

Reverse connection management
1) List   2) Add   3) Delete   4) Generate client   0) Back
EOF
    read -r -p 'Select: ' choice
    case $choice in
      1) ops_xray_reverse_list ;;
      2)
        read -r -p 'Connection name: ' name
        [[ -z $name ]] || ops_xray_reverse_add "$name"
        ;;
      3)
        read -r -p 'Connection name: ' name
        [[ -z $name ]] || ops_xray_reverse_delete "$name"
        ;;
      4)
        read -r -p 'Connection name: ' name
        read -r -p 'Server address: ' address
        read -r -p 'Absolute output path: ' output
        if [[ -n $name && -n $address ]]; then
          if [[ -n $output ]]; then ops_xray_reverse_client "$name" --address "$address" --output "$output"; else ops_xray_reverse_client "$name" --address "$address"; fi
        fi
        ;;
      0) return ;;
      *) ops_warn 'Invalid selection.' ;;
    esac
  done
}

ops_xray_menu() {
  [[ -t 0 ]] || ops_die 'The Xray menu requires an interactive terminal.'
  local choice type server target output domain scanner checker minutes
  while true; do
    cat <<'EOF'

Xray advanced management
1) Generate config      6) Change SNI
2) View summary         7) Reality scan
3) View full config     8) Reverse connections
4) Validate config      9) Rollback
5) Status / restart     h) Command help
0) Back
EOF
    read -r -p 'Select: ' choice
    case $choice in
      1)
        read -r -p 'Template [reality/xhttp/sing-reality] (reality): ' type
        type=${type:-reality}
        read -r -p 'Reality server name: ' server
        read -r -p "Target host:port ($server:443): " target
        target=${target:-$server:443}
        read -r -p "Absolute output path ($OPS_XRAY_CONFIG): " output
        output=${output:-$OPS_XRAY_CONFIG}
        [[ -z $server ]] || ops_xray_generate "$type" --server-name "$server" --target "$target" --output "$output"
        ;;
      2) ops_xray_view ;;
      3) ops_xray_view --full ;;
      4) ops_xray_validate_command ;;
      5)
        ops_xray_status
        ops_confirm 'Restart Xray now?'
        ops_xray_restart xray --yes
        ;;
      6)
        read -r -p 'New SNI domain: ' domain
        [[ -z $domain ]] || ops_xray_sni_set "$domain" --restart
        ;;
      7)
        read -r -p 'Target address (auto): ' target
        target=${target:-auto}
        read -r -p 'Scanner executable path: ' scanner
        read -r -p 'Optional checker executable path: ' checker
        read -r -p 'Scan minutes (3): ' minutes
        minutes=${minutes:-3}
        local -a scan_args=(--target "$target" --minutes "$minutes")
        [[ -z $scanner ]] || scan_args+=(--scanner "$scanner")
        [[ -z $checker ]] || scan_args+=(--checker "$checker")
        ops_xray_scan "${scan_args[@]}"
        ;;
      8) ops_xray_reverse_menu ;;
      9) ops_xray_rollback ;;
      h | H) ops_xray_help ;;
      0) return ;;
      *) ops_warn 'Invalid selection.' ;;
    esac
  done
}

ops_xray_main() {
  local command=${1:-}
  if [[ -z $command ]]; then
    if [[ -t 0 ]]; then
      ops_xray_menu
    else
      ops_xray_help
    fi
    return 0
  fi
  case $command in
    help | --help | -h | status | deps | generate | scan | menu) ;;
    restart) ops_xray_require_container_exists ;;
    *) ops_xray_require_container ;;
  esac
  case $command in
    deps)
      shift
      ops_xray_deps "$@"
      ;;
    status)
      shift
      ops_xray_status "$@"
      ;;
    generate)
      shift
      ops_xray_generate "$@"
      ;;
    validate)
      shift
      ops_xray_validate_command "$@"
      ;;
    view)
      shift
      ops_xray_view "$@"
      ;;
    restart)
      shift
      ops_xray_restart "$@"
      ;;
    rollback)
      shift
      ops_xray_rollback "$@"
      ;;
    scan)
      shift
      ops_xray_scan "$@"
      ;;
    sni)
      shift
      [[ ${1:-} == set ]] || ops_die 'Usage: opsctl xray sni set DOMAIN [OPTIONS]'
      shift
      ops_xray_sni_set "$@"
      ;;
    reverse)
      shift
      ops_xray_reverse_main "$@"
      ;;
    menu)
      shift
      (($# == 0)) || ops_die 'xray menu takes no arguments'
      ops_xray_menu
      ;;
    help | --help | -h) ops_xray_help ;;
    *) ops_die "Unknown xray command: $1" ;;
  esac
}
