# SSR-Ubuntu

**基于固定版本 ShadowsocksR manyuser 核心的 Ubuntu 安装与管理工具。**

项目只管理原版 SSR manyuser 服务端，不使用 Xray、标准 Shadowsocks 或其他代理核心替代。当前发布版本：`0.2.0`。

## 1. 功能

- 固定 Commit + SHA256 核心归档校验，拒绝浮动分支源码。
- OpenSSL 3 兼容补丁：RC4 Legacy Provider 和 EVP 上下文生命周期修复。
- 启动日志凭据脱敏；systemd 前台运行，独立 `ssr` 系统用户。
- 单端口/多端口账号管理：查看、添加、删除、修改端口/密码、模式转换。
- 生成 SSR 链接；满足原版规则时同时生成 SS 链接；本机 `qrencode` 生成二维码。
- 配置事务：文件锁、自动备份、校验、原子写入、重启失败回滚。
- 服务启停、状态和日志；TCP 连接统计；可选 IP 归属地查询。
- 防火墙受限放行、BBR 管理、备份/恢复和安全卸载。

## 2. 一键安装

适用目标：Ubuntu 20.04 / 22.04 / 24.04 / 26.04，AMD64 / ARM64。当前有用户提供的 Ubuntu 22.04.5 x86_64 实机安装记录；其他版本和 ARM64 尚未实测。

将项目 ZIP 上传到服务器并解压，然后进入项目目录：

```bash
cd SSR-Ubuntu
sudo bash ./install.sh
```

首次安装时：

1. 安装必要系统依赖；若本机没有 Git，安装 Git。
2. 从 `core/CORE.lock` 读取固定 Commit。
3. 从 `manyuser` 分支历史获取该 Commit，并用 `git archive` 生成核心归档。
4. 对归档 SHA256 与锁定值进行比对；不一致立即停止。
5. 应用精确匹配的日志脱敏和 OpenSSL 3 兼容补丁。
6. 执行 Python 编译、导入及加密往返预检。
7. 创建专用虚拟环境、`ssr` 系统用户、配置和 systemd 服务。
8. 启动服务，并询问是否在当前已启用的防火墙中放行 TCP/UDP 端口。

固定核心信息：

| 项目 | 锁定值 |
|---|---|
| 仓库 | `ssrlive/shadowsocksr` |
| 分支 | `manyuser` |
| Commit | `046078c9568bee891f0ac74085ee82fc08e99e3e` |
| Tree | `7c6884129710e658047c1c89ce17990d53f4af1c` |
| Archive SHA256 | `32a5a0fe14749f34f14859660f29e2bf10bc0a9deb3b278a55d4b42154b2de40` |

如果服务器无法访问 GitHub，可将已核验的归档放到 `core/archives/`，文件名必须为：

```text
shadowsocksr-046078c9568bee891f0ac74085ee82fc08e99e3e.tar.gz
```

安装器仍会重新核验 SHA256。也可通过 `SSR_CORE_ARCHIVE=/绝对路径` 指定归档。安装器不会执行上游 `ssr-install.sh`，不会下载浮动分支 ZIP。

**安全说明：** 安装器只支持全新安装。检测到现有核心目录、配置或 systemd unit 时会拒绝覆盖；请先备份并按迁移流程处理。安装不会自动启用 UFW，也不会修改 Vultr 云防火墙/安全组。

## 3. 日常使用

进入交互管理菜单：

```bash
sudo ssr.sh
```

常用菜单：

| 菜单 | 功能 |
|---|---|
| 5 | 查看账号、生成 SSR/SS 链接和本地二维码 |
| 6 | 查看 TCP 连接信息；IP 归属地查询需另行确认 |
| 7 | 设置用户及全局参数 |
| 8 | 手动编辑 JSON 配置（带并发修改检查） |
| 9 | 单端口/多端口模式转换 |
| 10–13 | 启动、停止、重启、查看日志 |
| 14 | BBR、日志策略及暂未开放的规则功能 |
| 3 | 卸载管理器；默认保留核心和配置 |

### 查看 SSR 链接和二维码

选择菜单 `5`，输入服务器公网 IP 或域名。工具将显示各端口账号、SSR 链接；符合原版兼容条件时也会显示 SS 链接。二维码由本机 `qrencode` 生成，不会上传第三方网站。

二维码目录：`/var/lib/ssr-ubuntu/qr/`（目录权限 0700，图片权限 0600）。请将链接和二维码视为密码凭据，不要公开发布。

### 用户管理

选择菜单 `7`：

- 单端口模式：修改端口、密码、加密方式、协议、混淆、设备数限制和限速。
- 多端口模式：添加、删除、修改用户端口/密码；调整全局加密参数。
- 选择菜单 `9` 可在单端口和多端口模式间转换。

单端口转多端口会保留原端口和密码。多端口转单端口必须指定保留端口；有多个账号时还需输入确认词。所有修改都会自动备份，服务重启失败时尝试恢复旧配置。

配置文件：`/etc/shadowsocksr/user-config.json`  
自动备份：`/etc/shadowsocksr/backups/`

### 常用服务命令

```bash
sudo systemctl status ssr
sudo systemctl restart ssr
sudo systemctl stop ssr
sudo systemctl start ssr
sudo journalctl -u ssr -f
sudo ssr.sh status
```

### 直接查看账号

```bash
sudo /usr/local/shadowsocksr/venv/bin/python \
  /usr/local/libexec/ssr-ubuntu/config.py accounts
```

此命令会显示明文密码，仅应在可信终端执行。

## 4. 默认配置

新装默认端口为 `2333`，初始密码由安装器使用安全随机数生成。默认加密/协议/混淆参数以安装时输出及配置文件为准。安装完成后请通过菜单 `5` 生成实际 SSR 链接，不要手工猜测或拼接链接。

## 5. 安全与运行边界

- systemd 以 `ssr` 用户运行；启动日志使用 quiet 模式，避免原核心 INFO 日志输出明文密码。
- 配置和链接只在本机处理；二维码不使用第三方在线服务。
- 防火墙模块不会启用 UFW、清空 iptables/nftables 规则或修改 SSH 规则。原生 nftables 复杂规则需要人工检查。
- 新增端口是否放行由用户确认；Vultr 云防火墙/安全组需单独放行 TCP 和 UDP。
- IP 归属地查询默认关闭。启用时客户端公网 IP 会通过 HTTPS 发送给 ipapi.co。
- BBR 只使用当前内核能力，不下载第三方内核或更换内核。
- RC4 等旧算法仅用于兼容；优先选择客户端和业务允许的现代算法。

## 6. 当前不开放的功能

以下项目不会伪装成已完成：

- SSR 核心在线更新和管理器在线更新：等待签名发布清单及受控升级流程。
- BT/PT/SPAM 自动封禁/解封：等待固定、审计过的规则集。
- 详细连接日志：当前保持关闭，避免凭据泄露。
- 自动生产迁移切换：迁移脚本目前只做检测/备份，需人工确认后再切换。

## 7. 已知测试记录

根据用户在 Vultr 服务器提供的终端输出：

- Ubuntu 22.04.5 LTS / x86_64 / Python 3.10.12 / OpenSSL 3.0.2。
- 固定核心归档 SHA256 校验通过，核心编译和导入通过。
- OpenSSL 3 RC4 Provider 补丁测试通过。
- 16 种加密算法各 50 次加解密往返：16 PASS / 0 FAIL。
- 协议插件注册：7/7；混淆插件注册：5/5。
- 配置管理 CRUD、单/多端口切换、备份和未知字段保留测试通过。
- 正式安装后 `ssr.service` 为 `active (running)`，TCP 和 UDP 2333 均监听。

这些记录证明该 Ubuntu 22.04 实例的核心和服务启动验证通过；**尚不能替代原版 SSR 客户端真实连接、业务流量和不同网络环境的端到端验收**。Ubuntu 20.04/24.04/26.04、ARM64、不同防火墙组合仍需单独测试。

## 8. 开发测试与重新打包

在项目根目录运行：

```bash
bash tests/run.sh
```

重新生成干净源码 ZIP：

```bash
python3 tools/build-package.py --output /mnt/data/SSR-Ubuntu-project.zip
```

打包器会生成 `MANIFEST.sha256`，校验 ZIP CRC、必需文件，并排除 `__pycache__`、`.pyc` 和测试缓存。

## 9. 卸载

运行菜单 `3` 或：

```bash
sudo bash uninstall/uninstall.sh
```

默认只卸载管理器和 systemd 服务，保留核心、配置和备份。彻底删除核心及配置需要额外输入两次确认词。

## 10. 目录结构

```text
SSR-Ubuntu/
├── install.sh                  # 一键安装入口
├── ssr.sh                      # 交互管理菜单
├── core/CORE.lock              # 固定 Commit 与 SHA256
├── install/                    # 安装器、核心归档准备及兼容补丁
├── modules/                    # 配置、链接、二维码、连接、防火墙、BBR 等
├── service/ssr.service         # systemd 服务
├── config/                     # 示例配置
├── migration/                  # 检测、备份、回滚
├── uninstall/                  # 安全卸载
├── tests/                      # 自动化测试
├── reports/                    # 审计和测试记录
├── original/                   # 原始脚本留档
├── VERSION
├── CHANGELOG.md
└── MANIFEST.sha256
```
