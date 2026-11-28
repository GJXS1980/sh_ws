# SSR-Ubuntu：ShadowsocksR manyuser 现代化管理工具

> 当前工程状态：**0.1.1 预览交付版 / 核心部署受固定版本校验阻断 / 未通过真实客户端兼容验收**。  
> 本项目只围绕原版 ShadowsocksR manyuser 服务端构建管理层，不使用 Xray、标准 Shadowsocks 或其他代理核心替代 SSR。

## 1. 项目目标与当前边界

- 兼容原始 Toyo `ssr.sh v2.0.38` 的路径和 JSON 配置语义。
- 保留原始 manyuser 核心、SSR 链接编码方式、单端口/多端口账号结构。
- 将配置修改改为 Python3 JSON 事务操作：锁、备份、校验、原子替换、服务重启检查和失败回滚。
- 采用 systemd 前台服务；运行时配置移除原核心的 daemon 管理字段，避免双重守护。
- 使用 `ss` 统计 TCP ESTABLISHED 远端 IP；不把 UDP socket 误称为 UDP 会话。
- 二维码只通过本机 `qrencode` 生成，不发送 SSR 链接到第三方网站。
- 防火墙只尝试接入当前已经启用的规则管理机制，不启用 UFW、不清空规则、不覆盖 SSH 规则。

**重要限制：** 当前执行环境无法取得 manyuser 分支的固定 commit SHA 和可验证压缩包 SHA256，也无法运行真实 Ubuntu 虚拟机和原版 SSR 客户端。因此安装脚本要求用户提供按固定 commit 下载的核心归档及 SHA256；缺少时拒绝安装。没有通过真实客户端对照测试前，不建议在生产服务器执行核心更新或迁移切换。

## 2. 目录结构

```text
SSR-Ubuntu/
├── core/CORE_PIN_STATUS.md
├── tools/build-package.py
├── VERSION
├── original/
│   ├── ssr.sh.v2.0.38
│   └── SHA256SUMS
├── ssr.sh
├── install/
│   ├── install.sh
│   ├── dependencies.sh
│   ├── inspect-core-source.sh
│   ├── prepare-core-archive.sh
│   └── core_install.py
├── modules/
│   ├── config.py
│   ├── link.py
│   ├── connection.py
│   ├── firewall.sh
│   ├── bbr.sh
│   ├── qr.sh
│   ├── service.sh
│   └── log.sh
├── service/ssr.service
├── uninstall/uninstall.sh
├── migration/
│   ├── detect.sh
│   ├── backup.sh
│   ├── migrate.sh
│   └── rollback.sh
├── config/user-config.example.json
├── patches/redact-server-password.patch
├── tests/
├── reports/
├── .github/workflows/tests.yml
├── Makefile
├── NOTICE.md
├── README.md
└── CHANGELOG.md
```

## 3. 核心源码来源与固定版本要求

核心源码来源（按用户最新指定更新）：

- 仓库入口：<https://github.com/ssrlive/shadowsocksr>
- 分支：`manyuser`
- 该分支 README 中给出的 clone URL：`https://github.com/ShadowsocksR-Live/shadowsocksr.git`
- 本项目归档脚本固定使用用户提供的仓库 URL：`https://github.com/ssrlive/shadowsocksr.git`
- 本项目沿用原 Toyo `ssr.sh v2.0.38` 的运行方式，实际服务入口仍是仓库中的 `shadowsocks/server.py`，不擅自切换到仓库根目录的数据库/API 管理入口 `server.py`。
- 当前可见 `setup.py` 的 Python 包版本字段为 `2.6.12`；`CHANGES` 顶部记录 SSR 代码版本 `3.4.0`（2017-07-27）。两者属于不同版本标识，不应混为一谈。
- `setup.py` 的 classifiers 只列 Python 3.3/3.4 等旧版本；这不是 Python 3.8/3.10/3.12/3.13 兼容保证。

**来源变更说明：** 用户提供的 `ssrlive/shadowsocksr` 与原脚本历史下载地址 `ToyoDAdoubiBackup/shadowsocksr` 是不同仓库标识。本项目现在将前者作为待固定、待验证的目标来源，但在完成两仓库源码差异审查和客户端回归前，不宣称它与 Toyo 原始下载内容逐字节相同，也不宣称已经通过客户端兼容验收。

**不要使用 `archive/manyuser.zip` 作为正式安装版本。** 该 URL 指向可变分支，不是固定版本。

正式安装必须准备：

1. 由 Git 仓库中一个明确的 40 位 commit SHA 生成的 archive；
2. 对应的 40 位 commit SHA；
3. 对生成的 archive 计算并独立保存 SHA256；
4. archive 顶层目录必须严格为 `shadowsocksr-<commit>`。

先在能访问 GitHub 的机器上解析并审查当前分支头：

```bash
sudo apt-get install -y git
bash install/inspect-core-source.sh
```

该脚本会显示实际解析出的 40 位 commit、tree SHA、提交日期、`setup.py` 包版本、`CHANGES` 顶部版本，并检查关键源码文件；它只 fetch 源码，不执行上游安装脚本。人工确认后，再用输出的 commit 生成固定归档：

```bash
bash install/prepare-core-archive.sh /root/ssr-core-source <40位commit SHA>
```

归档脚本使用 Git 默认 HTTPS 证书验证，检查 commit 属于 `manyuser` 分支历史，再由 `git archive` 从该 commit 生成归档；不执行上游代码，也不跟随浮动分支。**当前对话环境无法连接 GitHub Git 服务，因此尚未替用户实取 commit/tree SHA 和归档 SHA256。**

脚本会输出 archive 路径和 SHA256。请在受控记录中保存这两个值，并在目标服务器核对。当前项目没有取得一个可独立核验的上游 commit 和 archive SHA256，因此没有把任何核心压缩包伪装成已验证版本。

`install/core_install.py` 会检查 SHA256、归档顶层目录、核心文件清单、`setup.py` 版本 `2.6.12` 及空 `install_requires`，并仅对 `shadowsocks/server.py` 启动日志中的密码/obfs 参数进行精确匹配脱敏补丁。补丁无法精确匹配时会拒绝安装。不会关闭 TLS 证书校验，不会替换代理核心。用户提供仓库的 README 还引用了旧式一键安装脚本；该脚本含浮动分支 clone、`--no-check-certificate`、固定默认密码和 init.d/rc.local 管理，不属于本项目可信安装流程，严禁直接执行。

## 4. 安装方式

安装目标：Ubuntu 20.04 / 22.04 / 24.04 / 26.04；架构：AMD64、ARM64。**这些目标系统目前尚未在本工程环境中逐一实测。**

先将固定 commit 的 archive 放在服务器本地，例如 `/root/ssr-core-source/shadowsocksr-<commit>.tar.gz`，并核验 SHA256。然后在项目目录执行：

```bash
sudo env \
  SSR_CORE_ARCHIVE=/root/ssr-core-source/shadowsocksr-<commit>.tar.gz \
  SSR_CORE_COMMIT=<40位commit SHA> \
  SSR_CORE_SHA256=<64位SHA256> \
  bash ./ssr.sh install
```

如果缺少 archive、commit 或 SHA256，安装会停止，不会使用浮动分支或替代核心。当前安装器要求上游目录名严格为 `shadowsocksr-<commit>`，并在安装前运行核心 Python compile/import smoke test。

安装程序会：

- 检查 Ubuntu 版本和 CPU 架构；
- 安装 Python3、venv、iproute2、qrencode 和可用的 libsodium 软件包；
- 默认使用系统 Python 创建专用 venv；可通过 `SSR_PYTHON_BIN` 指定解释器；
- 对核心 Python 文件执行 compile/import smoke test（不替代真实客户端测试）；
- 校验并部署核心；
- 创建独立 Python venv 和 `ssr` 系统用户；
- 新装时生成随机密码；
- 写入 `/etc/systemd/system/ssr.service`；
- 启动服务并检查状态；
- 询问是否通过当前已启用的防火墙放行 TCP/UDP 端口。

安装不会自动开启 UFW，不会覆盖云平台安全组。

## 5. 日常管理

```bash
sudo ssr.sh
sudo systemctl start ssr
sudo systemctl stop ssr
sudo systemctl restart ssr
sudo systemctl status ssr
sudo journalctl -u ssr -f
```

主菜单尽量保持原版 1～15 项布局。已实现的管理能力包括：账号查看、SSR/SS 链接生成、本地二维码、单/多端口配置修改、模式转换、systemd 管理、journald、连接统计、libsodium 检查、BBR。端口变更后会对比配置端口列表：只移除 ledger 记录的旧规则；新增端口需用户确认后才尝试放行。

### 查看链接与二维码

菜单 5 要求输入服务器公网 IP 或域名。不会默认把 `0.0.0.0` 当作公网地址。二维码 PNG 存放在 `/var/lib/ssr-ubuntu/qr/`，目录 0700、文件 0600。

链接生成规则对应原脚本：

- SSR：`ssr://` + URL-safe Base64；
- 密码先单独 Base64；
- `+` → `-`，`/` → `_`，去掉末尾 `=`；
- `_compatible` 后缀在链接中剥除；
- SS 链接仅在原 `ss_ssr_determine()` 兼容条件满足时生成。

IPv6 地址的 SSR 链接格式仍需使用目标客户端进行专门回归验证，不应仅凭生成成功认定兼容。

### 用户配置

- 单端口转多端口：将原端口和密码直接迁移到 `port_password`，不重新生成账号。
- 多端口转单端口：要求选择保留端口；存在多个用户时必须二次确认。其余账号仍在自动备份中。
- 添加用户：检查端口格式和重复端口。
- 删除用户：不允许删除最后一个用户。
- 所有配置变更均会生成备份并校验 JSON。
- 服务重启失败时恢复旧配置并尝试重启旧服务。

备份目录：`/etc/shadowsocksr/backups/`。也可通过 Python 管理器执行：

```bash
sudo /usr/local/shadowsocksr/venv/bin/python /usr/local/libexec/ssr-ubuntu/config.py accounts
sudo /usr/local/shadowsocksr/venv/bin/python /usr/local/libexec/ssr-ubuntu/config.py validate
sudo /usr/local/shadowsocksr/venv/bin/python /usr/local/libexec/ssr-ubuntu/config.py restore --backup /etc/shadowsocksr/backups/user-config.json.<时间戳>.bak
```

## 6. systemd 与日志安全

`server.py` 调用 `daemon.daemon_exec(config)`；核心仅在配置包含 `daemon` 字段时执行后台 fork。systemd 的运行时配置会删除 `daemon`、`pid-file`、`log-file`、`user`，持久配置不被修改。

服务采用 `Type=simple`，默认 `workers=1` 时由 systemd 直接跟踪前台进程。服务使用 `-q` 屏蔽原核心 INFO 级日志，因为原核心启动 INFO 日志包含明文密码。详细连接日志目前**暂不开放**，待所有日志路径完成脱敏并经过审计后再启用。

服务用户为 `ssr`，只配置 `CAP_NET_BIND_SERVICE` 能力，不以 root 运行。更严格的 `ProtectSystem` 等 systemd 沙箱参数暂不启用，需在目标环境逐项验证后再增加。

## 7. 防火墙

`modules/firewall.sh` 当前自动管理已启用的 UFW 或现有 iptables/iptables-nft 规则。检测到原生 nftables 服务时只提示人工配置，不向未知 base chain 插入规则，以免误改变现有默认拒绝策略。

- 不执行 `ufw enable`；
- 不执行 `iptables -F`；
- 不执行 `nft flush ruleset`；
- 不修改 SSH 端口规则；
- 只删除本工具 ledger 记录的规则；
- 没有活动防火墙时不自动开启防火墙，提醒检查云安全组；
- 原生 nftables 当前只检测、不自动改写，标记为待集成测试。

防火墙模块尚未在 Ubuntu 多种防火墙组合下完成集成测试，生产环境启用前应先在测试机验证。

## 8. libsodium 与算法

优先检查 Ubuntu 软件源的 `libsodium23` 或 `libsodium-dev`。`ldconfig -p` 用于验证动态库是否注册。

配置管理器保留原脚本列出的算法名称，但这只是配置层白名单，不等于每个算法已经在 Ubuntu 20.04/22.04/24.04/26.04、OpenSSL 3、目标 libsodium 版本上通过加密回归测试。尤其 RC4 等旧算法可能受 OpenSSL 3 provider 策略影响；本项目不会降低系统 OpenSSL 安全级别。

## 9. BBR

BBR 只使用当前内核已有能力，不下载第三方内核脚本，不更换内核。开启前检查 `net.ipv4.tcp_available_congestion_control` 是否包含 `bbr`；保存原始 qdisc 和 congestion control 值，关闭时恢复。

## 10. 连接监控

TCP 连接使用 `ss -Htn state established`，按本机监听端口统计唯一远端 IP，并处理 IPv4-mapped IPv6。UDP 只展示本机 UDP socket 端口，不伪称为 UDP ESTABLISHED 会话。

IP 归属地查询为显式 opt-in：菜单 6 默认不查询；用户确认后，才通过 HTTPS 调用 ipapi.co，最多 4 路并发、缓存 30 天，且仅查询公网 IP。该操作会把客户端公网 IP 发送给第三方服务；服务商可能记录查询，敏感环境建议保持关闭。可通过 `SSR_GEO_CACHE` 修改本地缓存位置。

## 11. 当前未开放的功能

以下功能明确标记为 BLOCKED，不会打印虚假的成功信息：

- SSR 核心在线更新：等待固定发布版本和客户端回归验收；
- 管理脚本在线更新：等待签名 release manifest 和 SHA256；
- BT/PT/SPAM 封禁/解封：等待固定且经过审计的规则集；
- 详细连接日志：等待核心全部日志脱敏及安全审计；
- 生产迁移切换：等待真实旧/新 Ubuntu 服务器对照测试。

## 12. 旧服务器迁移

先执行：

```bash
sudo bash migration/detect.sh
sudo bash migration/backup.sh
```

`migration/migrate.sh` 当前只完成检测和备份，随后明确停止，不会切换服务或停止旧 SSR。原因是核心版本固定及客户端回归测试尚未完成。

如果未来已经完成切换且需要回滚：

```bash
sudo bash migration/rollback.sh /root/ssr-migration-backups/ssr-YYYYMMDD-HHMMSS
```

回滚脚本不会自动恢复防火墙快照，避免覆盖其他应用的规则。必须人工审阅 `meta/` 目录的快照。

## 13. 卸载

菜单 3 默认只卸载管理器、systemd unit 和辅助文件，保留核心、配置、备份和防火墙规则。彻底删除核心和配置需要额外输入两次明确确认词。

## 14. 测试与验收状态

请查看：

- `reports/source-audit.md`
- `reports/compatibility.md`
- `reports/upstream-core-audit-ssrlive.md`
- `reports/test-report.md`
- `reports/delivery-status.md`
- `CHANGELOG.md`

当前执行环境为 Debian 13 / Python 3.13.5，不是 Ubuntu 20.04/22.04/24.04/26.04。没有真实 SSR 客户端和服务器环境。因此，静态检查或本地 JSON/链接单元测试通过，不代表真实 SSR 客户端兼容通过。

## 15. 构建源码 ZIP 包

在项目根目录执行：

```bash
python3 tools/build-package.py --output /mnt/data/SSR-Ubuntu-project.zip
```

脚本会生成 `MANIFEST.sha256`、创建 ZIP、检查 CRC、必需交付文件和 Python 缓存排除情况，并输出 ZIP SHA256。

## 核心源码固定版本（已审核候选 Commit）

当前候选核心已锁定到 `ssrlive/shadowsocksr` 的 manyuser 提交：

- Commit：`046078c9568bee891f0ac74085ee82fc08e99e3e`
- Tree：`7c6884129710e658047c1c89ce17990d53f4af1c`
- `setup.py` 版本：`2.6.12`
- `CHANGES` 顶部版本：`3.4.0`

该提交已通过源码入口、多端口结构和 daemon 行为的初步人工审核，**批准生成固定 Commit 归档，但不代表生产部署或原客户端兼容性验收通过**。归档 SHA256 需在可访问 GitHub 的构建机上实际生成。

```bash
bash install/prepare-core-archive.sh /root/ssr-core-source 046078c9568bee891f0ac74085ee82fc08e99e3e
```

不要执行归档内的上游 `ssr-install.sh`。部署前必须应用日志脱敏补丁，并完成 Python/加密库和原 SSR 客户端回归测试。详见 `core/CORE_PIN_STATUS.md` 与 `reports/upstream-core-audit-ssrlive.md`。

