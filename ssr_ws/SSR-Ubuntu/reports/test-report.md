# SSR-Ubuntu 自动化测试报告

## 1. 测试环境

- OS：Debian GNU/Linux 13 (trixie)，不是目标 Ubuntu 系统
- Python：3.13.5
- CPU 架构：x86_64
- 内核：Linux 6.18.57
- Shell：Bash
- ShellCheck：当前环境未安装
- systemd-analyze：可用
- qrencode：当前环境未安装
- 真实 SSR manyuser 核心：未部署
- SSR 客户端：未提供/未连接

## 2. 测试结果

以下为本次源码包构建环境实际执行的检查；最终发布包中的结果应以构建时重新运行的结果为准。

| 项目 | 状态 | 说明 |
|---|---|---|
| 所有 Shell 文件 `bash -n` | PASS | 不代表运行时环境测试 |
| Python 文件 `compileall` | PASS | 使用 Python 3.13.5 |
| Python 3.8 语法 AST 检查 | PASS | `ast.parse(feature_version=(3,8))`；不是 Python 3.8 解释器实测 |
| JSON 配置管理单元测试 | PASS | 事务、锁、备份、原子替换、回滚、单/多端口 |
| SSR/SS 链接回归单元测试 | PASS | 对照原脚本 Base64 和链接载荷规则 |
| 连接统计解析单元测试 | PASS | IPv4/IPv6 endpoint、缓存、公网查询过滤 |
| 核心安装器 fixture 测试 | PASS | 测试伪造 fixture 的哈希/结构/补丁契约，不代表真实上游核心通过 |
| 管理脚本/服务包装器单元测试 | PASS | 使用 fake systemctl 验证参数传递 |
| ShellCheck | NOT TESTED | 当前环境未安装 |
| systemd unit 真实路径验证 | BLOCKED | 当前不存在 `/usr/local/shadowsocksr/venv/bin/python` 等部署文件 |
| Ubuntu 20.04 安装 | NOT TESTED | 无真实 Ubuntu 20.04 VM |
| Ubuntu 22.04 安装 | NOT TESTED | 无真实 Ubuntu 22.04 VM |
| Ubuntu 24.04 安装 | NOT TESTED | 无真实 Ubuntu 24.04 VM |
| Ubuntu 26.04 安装 | NOT TESTED | 无真实 Ubuntu 26.04 VM |
| ARM64 | NOT TESTED | 当前环境仅 x86_64 |
| libsodium 算法运行 | BLOCKED | 未在目标系统部署核心并执行 cipher self-test |
| OpenSSL 3 旧算法矩阵 | BLOCKED | 未在目标系统逐算法运行 |
| SSR TCP/UDP 端到端 | BLOCKED | 无固定核心部署及客户端 |
| IPv4/IPv6 客户端连接 | BLOCKED | 无真实客户端对照 |
| 原 SSR 链接同账号对照 | BLOCKED | 未在旧/新服务器执行同链接测试 |
| 防火墙集成 | NOT TESTED | 未在 UFW/iptables-nft/nftables 多种实际策略下执行 |
| BBR 内核参数 | NOT TESTED | 未在目标 Ubuntu 内核上执行 |
| 二维码 PNG | NOT TESTED | 当前环境未安装 qrencode |

## 3. 本地自动化测试覆盖

当前单元测试覆盖：

- 配置 JSON 校验、未知字段保留、文件锁和备份；
- 单端口转多端口账号保留；
- 多端口添加、删除、修改、最后一个用户保护；
- 多端口转单端口显式确认；
- 服务重启失败后的配置恢复；
- 旧式 manyuser list/dict 端口条目读取和密码修改；
- 原版 SSR URL-safe Base64、SSR 链接载荷和 SS 兼容规则；
- IPv4/IPv6 endpoint 解析、IP 归属地缓存及私网地址过滤；
- 核心归档哈希检查、固定目录契约、日志补丁精确匹配；
- 原始上传脚本 SHA256、菜单项、Python 3.8 语法解析和安全静态模式。

## 4. 验收结论

管理层代码的本地单元测试通过，不等于 SSR manyuser 核心已在 Ubuntu 20.04+ 上运行，也不等于客户端协议兼容已通过。核心固定提交和 SHA256、目标 Ubuntu 安装、加密算法矩阵、TCP/UDP、IPv4/IPv6 以及原客户端同链接回归仍为 BLOCKED/NOT TESTED。

## 5. 最近一次完整运行记录

- Python unittest：39 项测试全部通过（`Ran 39 tests ... OK`）。
- Bash 全部脚本语法：PASS。
- Python `compileall`：PASS。
- systemd unit：`systemd-analyze verify` 对部署路径做可执行文件替身后 PASS；不代表服务运行测试。
- 原始上传脚本副本 SHA256：PASS。
- ShellCheck：NOT TESTED（构建环境未安装）。
