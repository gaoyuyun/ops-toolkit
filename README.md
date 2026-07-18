# ops-toolkit

`ops-toolkit` 是一个面向 Debian、Ubuntu、Alpine 和 WSL 的模块化运维工具包，提供用户、系统、安全、Docker 数据、维护、WSL、Xray 和 Sing-box 管理能力。

当前版本为 `0.1.1`。入口 `opsctl` 启动时会显示工具版本和检测到的平台；不需要联网的模块在发布包离线解压后可直接运行。

## 项目范围

包含：

- 用户、SSH Key、Zsh/P10k、Hostname、Swap 和 BBR。
- SSH、UFW、Fail2ban、Logrotate 和 Vaultwarden Fail2ban 规则。
- Docker 安装、数据组、Compose 启停、备份、恢复和迁移。
- 系统清理、Alpine、WSL 初始化和 reinstall/DD 脚本下载。
- Xray Reality/XHTTP、Sing-box Reality、Reality 扫描和反向连接管理。

不包含：

- Docker Compose 服务栈、服务级配置、证书和运行时数据。
- Vaultwarden/Bitwarden 密钥导出工具。
- Python SOCKS 代理测试工具和 Python 运行时依赖。
- 授权和再发布范围不明确的原生 Windows 补丁。

## 一键临时运行

始终运行最新正式 Release：

```bash
bash <(curl -fsSL https://github.com/gaoyuyun/ops-toolkit/releases/latest/download/bootstrap.sh) --help
```

锁定到固定版本：

```bash
bash <(curl -fsSL https://github.com/gaoyuyun/ops-toolkit/releases/download/v0.1.1/bootstrap.sh) --help
```

`bootstrap.sh` 只下载它所属 Release 中的压缩包和 SHA-256 文件，完成校验后解压、调用真实的 `bin/opsctl`，最后清理临时目录，不会永久安装。

## 一键安装和升级

从最新正式 Release 永久安装；以后重新执行同一命令即可升级：

```bash
curl -fsSL https://github.com/gaoyuyun/ops-toolkit/releases/latest/download/install.sh | sudo bash
```

默认版本目录为 `/opt/ops-toolkit/ops-toolkit-vX.Y.Z`，`/opt/ops-toolkit/current` 指向当前版本，命令入口为 `/usr/local/bin/opsctl`。旧版本目录会保留，便于手动回滚。安装器与 `bootstrap.sh` 一样锁定并校验同一 Release 的压缩包，不执行 `main` 分支内容。

自定义安装位置：

```bash
curl -fsSL https://github.com/gaoyuyun/ops-toolkit/releases/latest/download/install.sh -o install.sh
bash install.sh --prefix "$HOME/.local/opt/ops-toolkit" --bin-dir "$HOME/.local/bin"
```

安装完成后可直接运行：

```bash
opsctl --version
sudo opsctl menu
```

也可以下载并离线使用：

```bash
curl -fSLO https://github.com/gaoyuyun/ops-toolkit/releases/download/v0.1.1/ops-toolkit-v0.1.1.tar.gz
curl -fSLO https://github.com/gaoyuyun/ops-toolkit/releases/download/v0.1.1/ops-toolkit-v0.1.1.tar.gz.sha256
sha256sum -c ops-toolkit-v0.1.1.tar.gz.sha256
tar -xzf ops-toolkit-v0.1.1.tar.gz
./ops-toolkit-v0.1.1/bin/opsctl --help
```

## 常用命令

```bash
bin/opsctl --version
bin/opsctl platform
sudo bin/opsctl menu
bin/opsctl user backup nas-backup --dry-run
bin/opsctl system swap 1G --dry-run
bin/opsctl ssh harden --port auto --dry-run
bin/opsctl firewall allow 22/tcp --dry-run
bin/opsctl firewall allow 80/tcp --dry-run
bin/opsctl firewall allow 443/tcp --dry-run
bin/opsctl firewall install --dry-run
bin/opsctl fail2ban install --dry-run
bin/opsctl logrotate install --dry-run
bin/opsctl docker init-data --user deploy --dry-run
bin/opsctl docker backup --source /srv/docker --output /tmp/docker.tar.gz --dry-run
bin/opsctl maintenance analyze
bin/opsctl maintenance cleanup --all --dry-run
bin/opsctl wsl status
bin/opsctl wsl startup init --dry-run
```

变更型命令会交互确认；自动化时使用 `--yes`。支持的命令尽量提供 `--dry-run`。SSH 加固会先校验 `sshd`，失败时恢复旧配置；首次修改 SSH 之前请保持一个现有会话。

命令会在使用外部程序前检测依赖。SSH、UFW、Fail2ban、Logrotate、WSL 和 Xray 辅助工具发现缺失命令时，会列出缺失项并提示是否通过当前发行版包管理器安装；安装后会再次确认命令确实可用。非交互环境需显式传入 `--yes`，`--dry-run` 只显示将安装的包。Docker Xray 是例外：工具不会安装 Docker 或 Xray 容器，容器不存在时直接返回。`firewall install` 会在启用 UFW 前自动放行配置的 SSH 端口、HTTP 和 HTTPS。

兼容入口 `sudo bin/opsctl menu` 提供与原 `init.sh` 类似的可执行交互菜单；用户、系统、安全、Docker、工具和维护操作也都有可组合子命令。兼容菜单沿用原脚本的 root 运行方式。

## Root 运行

会修改用户、系统配置、`/etc` 或 `/srv` 的命令应使用 root：

```bash
cd /path/to/ops-toolkit
sudo ./bin/opsctl menu
sudo ./bin/opsctl COMMAND [OPTIONS]
```

也可以进入 Root Shell：

```bash
sudo -i
cd /path/to/ops-toolkit
./bin/opsctl menu
```

通过 `sudo` 运行时应优先使用 `/etc/ops-toolkit/config.env`，因为普通用户的 `~/.config/ops-toolkit/config.env` 通常不会被 root 读取。

## 配置

主机相关设置依次从以下位置读取（前者存在时优先）：

1. `/etc/ops-toolkit/config.env`
2. `~/.config/ops-toolkit/config.env`

参考 [config.env.example](config.env.example)。解析器只接受已知的 `KEY=VALUE`，不会把配置文件当 Shell 执行。通用默认值如下：

```text
OPS_DATA_ROOT=/srv/docker
OPS_DOCKER_GROUP=docker-data
OPS_DEFAULT_SSH_PORT=22
OPS_XRAY_CONTAINER=xray
OPS_NGINX_CONTAINER=nginx
OPS_XRAY_CONFIG=/srv/docker/xray/config.json
OPS_NGINX_STREAM_CONFIG=/srv/docker/nginx/conf.d/default.stream
OPS_XRAY_LOG_DIR=/srv/docker/xray
```

普通用户的本地工具默认安装到 `~/.local/bin`，root 默认安装到 `/usr/local/bin`。只有需要覆盖时才在配置文件中设置 `OPS_BIN_DIR`/`OPS_XRAY_BIN` 等绝对路径。

Fail2ban 与 Logrotate 模板随发布包提供；SSH 端口、日志路径和容器名在安装时由配置注入，不需要访问私有仓库。

Root 配置初始化示例：

```bash
sudo install -d -m 0755 /etc/ops-toolkit
sudo install -m 0640 config.env.example /etc/ops-toolkit/config.env
sudoedit /etc/ops-toolkit/config.env
```

## 用户、系统和安全

```bash
sudo bin/opsctl user create deploy
sudo bin/opsctl user authorized-key deploy --key-file ./deploy.pub
sudo bin/opsctl user zsh deploy
sudo bin/opsctl system hostname server.example --cloud-init
sudo bin/opsctl system swap 1G --swappiness 10
sudo bin/opsctl system bbr
sudo bin/opsctl ssh harden --port 2222
sudo bin/opsctl firewall install --ssh-port 2222
sudo bin/opsctl fail2ban install
sudo bin/opsctl logrotate install
```

`firewall install` 会先放行指定 SSH 端口以及 HTTP/HTTPS，再启用 UFW。Vaultwarden jail/filter 会随 Fail2ban 资源保留；请确保 `OPS_VAULTWARDEN_LOG_PATH` 指向实际日志路径。

## Docker 数据和维护

```bash
sudo bin/opsctl docker install --source distro --user deploy
sudo bin/opsctl docker init-data --user deploy
sudo bin/opsctl docker backup --source /srv/docker --output /srv/docker_backup.tar.gz
sudo bin/opsctl docker restore /srv/docker_backup.tar.gz --target /srv/docker --clear --start
sudo bin/opsctl docker migrate /old/docker --target /srv/docker --clear
bin/opsctl maintenance analyze
sudo bin/opsctl maintenance cleanup --all
sudo bin/opsctl maintenance cleanup --vscode
```

Docker 迁移会识别目录顶层多个 `.yml`/`.yaml` 文件，停止源 Compose、迁移数据、修正权限并启动目标 Compose。使用 `--no-start` 可跳过启动；清理 Docker 卷必须显式使用 `--volumes`。

维护分析会统计历史 VS Code Server 版本。`cleanup --vscode` 会扫描本机登录用户的 `.vscode-server`、`.vscode-server-insiders` 和旧版 `.vscode-remote` 目录，每种 Server 安装保留最新版本以及所有正在运行的版本；使用 `--vscode-user USER` 可只清理指定用户。该类别也包含在默认清理和 `--all` 中。

## 独立工具

### Xray 管理

Xray 模块分为两条独立路径：

- 本地工具链：配置生成和 Reality 扫描。缺少二进制时提示下载并安装到标准 bin 目录；普通用户默认 `~/.local/bin`，root 默认 `/usr/local/bin`。
- Docker 运行时管理：状态/校验、配置查看、容器重启、SNI、回滚和反向连接。它要求 `OPS_XRAY_CONTAINER` 指定的容器存在并正在运行，但不会创建容器。

```bash
bin/opsctl xray --help
bin/opsctl xray status
bin/opsctl xray deps --xray --scan-tools --yes
bin/opsctl xray deps --sing-box --yes
```

本地 Xray 使用 XTLS 官方 GitHub `latest` release，根据 `amd64`/`arm64` 选择压缩包，并校验同一 release 的官方 `.dgst` SHA-256 后安装。`sing-reality` 会按同样方式安装 SagerNet sing-box latest 并校验 GitHub digest。默认 Reality/XHTTP 监听端口与原 `config-lab` 模板一致，为 `44301`；Reality 模板保留 Proxy Protocol。配置生成和扫描不要求 Docker 容器存在。运行时管理命令则检查容器及容器内 `xray`，失败时只提示先安装或启动 Docker Xray。

生成配置时不再强制提前准备 `xray.env`。如果本地 Xray 或 sing-box 缺失，工具会先提示安装；`reality`/`xhttp` 使用 Xray，`sing-reality` 使用 sing-box，short ID 由对应引擎生成：

```bash
sudo bin/opsctl xray generate reality \
  --server-name example.org \
  --target example.org:443 \
  --output /srv/docker/xray/config.json \
  --yes

sudo bin/opsctl xray generate sing-reality \
  --server-name example.org \
  --target example.org:443 \
  --output /srv/docker/sing-box/config.json \
  --yes
```

命令生成配置后会像原 `xray.sh` 一样直接在终端显示 UUID、Public Key、Short ID、SNI 和端口。只有显式指定 `--client-output FILE` 时才额外写客户端参数文件。需要复现或回滚相同身份时，仍可使用权限不宽于 `0600` 的外部输入文件：

```bash
bin/opsctl xray generate reality \
  --env-file ~/.config/ops-toolkit/xray.env \
  --output /srv/docker/xray/config.json
```

常用管理命令：

```bash
sudo bin/opsctl xray view
sudo bin/opsctl xray validate
sudo bin/opsctl xray restart xray --yes
sudo bin/opsctl xray sni set new.example.org --restart --yes
sudo bin/opsctl xray rollback --restart --yes
```

`view` 显示文件路径、大小、修改时间、完整 UUID、SNI、Short ID、Public Key 和反向连接数量，但不显示私钥；只有显式执行 `view --full --yes` 才打印完整配置。每次修改配置前会保留一个 `config.json.bak`，可由 `rollback` 恢复。为兼容原 Docker 数据目录，Xray 配置和扫描结果使用 `0664`，目录使用 `2775`；这意味着其他本机用户也可能读取配置，安全要求更高的主机应自行改回 `0640`/`0600`。

反向连接管理：

```bash
sudo bin/opsctl xray reverse add office --restart --yes
sudo bin/opsctl xray reverse list
bin/opsctl xray reverse client office \
  --address server.example.org
sudo bin/opsctl xray reverse delete office --restart --yes
```

首次运行 Reality 扫描时，如果没有找到扫描器或验证器，工具会提示安装。确认后，它会从两个项目的 GitHub `latest` release 中按 `amd64`/`arm64` 自动选择资产，并使用 GitHub release API 提供的 SHA-256 digest 校验后安装；扫描同样不要求 Docker Xray：

```bash
bin/opsctl xray deps --scan-tools --yes
bin/opsctl xray deps --sing-box --yes
bin/opsctl xray scan --minutes 3 --yes
```

默认安装位置由 `OPS_XRAY_SCANNER` 和 `OPS_XRAY_CHECKER` 控制。也可以通过 `--scanner` 和 `--checker` 使用经过自行审核的本地文件。扫描命令不提供 `--target` 时自动查询公网 IP；CSV 写入 `OPS_XRAY_LOG_DIR/<IP>.csv`，验证结果兼容原脚本写入 `OPS_XRAY_LOG_DIR/scan_result.txt`。

Fail2ban 和 Docker 数据迁移的兼容行为：Fail2ban 模板保留原默认封禁时间、nftables/DOCKER-USER 动作以及 Vaultwarden jail；Docker 迁移会自动查找源目录的 Compose 文件、停止服务、迁移数据、修正权限并启动目标 Compose，使用 `--no-start` 可跳过启动。

## WSL 与 Windows 边界

WSL 模块保留在本仓库，因为它在 Linux 内运行并复用同一套平台、包管理和 SSH 权限逻辑。当前恢复了原脚本的 systemd、清爽 PATH、Windows 别名、启动脚本管理、基础软件、Mihomo、nvm/uv/Node LTS 和 Windows SSH 同步：

```bash
sudo bin/opsctl wsl init --user grayson --windows-user grayson --yes
sudo bin/opsctl wsl target-user grayson
sudo bin/opsctl wsl enable-systemd --yes
sudo bin/opsctl wsl clean-path --user grayson --windows-user grayson --yes
sudo bin/opsctl wsl startup init --user grayson --yes
sudo bin/opsctl wsl install-base --yes
sudo bin/opsctl wsl install-mihomo --yes
sudo bin/opsctl wsl install-dev --user grayson --yes
sudo bin/opsctl wsl sync-ssh --user grayson --yes
```

`wsl init` 可按顺序执行完整初始化；单独的子命令适合按需调整或排错。修改 systemd 或 Windows PATH 继承设置后，请在 Windows 终端执行 `wsl.exe --shutdown`，再重新进入发行版使配置生效。

Mihomo 使用 latest release 的架构资产和 GitHub SHA-256 digest；nvm/uv 仍按原脚本执行官方安装器。原生 Windows PowerShell 补丁不纳入公开工具包：它与服务器运维边界不同，而且原补丁的授权和再发布风险未确认。

## 安全模型

- 仓库不包含 `.env` 实值、密钥、Token、私有域名、内网地址或生成后的服务配置。
- 配置与身份数据在运行时注入；生成的 `config.json` 和常见密钥文件已加入 `.gitignore`。
- Windows 软件补丁没有明确的授权与再发布依据，因此不在发布范围内。
- 项目不会保存 VPS 部署清单；Docker 备份文件只写到用户指定的运行时路径，并由 `.gitignore` 排除。
- 第一次公开 push 前仍需人工审查，并建议安装 `gitleaks` 后执行 `scripts/scan-secrets.sh`。

漏洞披露方式见 [SECURITY.md](SECURITY.md)。

## 开发、发布、升级与回滚

```bash
tests/run.sh
shellcheck bootstrap.sh.in install.sh.in bin/opsctl lib/*.sh modules/*.sh scripts/*.sh tests/*.sh
shfmt -d -i 2 -ci bootstrap.sh.in install.sh.in bin/opsctl lib modules scripts tests tools
RELEASE_BASE_URL=https://github.com/gaoyuyun/ops-toolkit/releases/download/v0.1.1 \
  scripts/build-release.sh
```

CI 会执行 Bash 语法、ShellCheck、shfmt 和公开树密钥扫描，并为 `v*` tag 构建压缩包、SHA-256、临时启动器和安装/升级脚本。工具包不依赖 Python。

临时运行时可重新执行旧 Tag 的 bootstrap 回滚。永久安装时，把 `/opt/ops-toolkit/current` 重新指向保留的旧版本目录即可回滚。不要使用 `main` URL 代替 Release 下载地址。

## 许可证

[MIT](LICENSE)
