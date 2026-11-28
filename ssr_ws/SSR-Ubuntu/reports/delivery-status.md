# SSR-Ubuntu 0.2.1 交付状态

## 已包含

- 固定 SSR manyuser Commit、Tree 和归档 SHA256。
- 根目录一键安装入口 `install.sh`。
- 精确日志脱敏补丁与 OpenSSL 3 RC4/provider、EVP context 生命周期补丁。
- systemd 前台服务、专用 `ssr` 用户、随机初始密码和配置校验。
- SSR/SS 链接生成、本地二维码、账号显示、单/多端口用户管理。
- 配置备份/恢复、服务管理、TCP 连接统计、可选地理位置查询。
- 多端口新增用户自动防火墙流程：UFW、Firewalld 和原有受限 iptables 支持。
- Firewalld 运行时及永久 TCP/UDP 规则；仅管理由本工具创建的规则。
- 添加用户的配置事务、防火墙失败保护、SSR 重启失败回滚及结果汇报。
- BBR 管理、卸载、迁移检测/备份/回滚、测试套件和简化 README。

## 安全边界

- 不自动启用 UFW 或 Firewalld。
- 不清空规则、不修改默认策略、不修改 SSH 规则。
- 同时发现 UFW 与 Firewalld active/running 时拒绝自动修改。
- 原生 nftables 复杂规则不自动插入；提示人工检查。
- 未发现已启用的受支持防火墙时，账号可创建但提示手动放行。
- 活跃防火墙明确放行失败时，取消账号配置提交。
- 配置写入或 SSR 重启失败时恢复旧配置；若本次创建了规则则尝试撤销。
- Vultr 云防火墙/安全组不由 VPS 内脚本修改。

## 测试状态

- `bash tests/run.sh`：52 项 unittest 全部通过。
- 新增 Firewalld/UFW 及账号事务回滚 Mock 测试。
- Shell 语法、Python 编译、systemd unit 静态检查：按测试脚本执行。
- ShellCheck：构建容器未安装时为 NOT TESTED。
- 本次没有在真实 VPS 上执行防火墙规则修改；Mock 测试不能替代真实环境验收。

## 用户提供的既有实机验证记录

Ubuntu 22.04.5 LTS / x86_64 / Python 3.10.12 / OpenSSL 3.0.2；固定核心归档校验、核心部署、16 种加密算法往返、插件注册、配置 CRUD、systemd active 和 TCP/UDP 2333 监听均有既有终端记录。

这些是 0.2.0 基础版本的实机记录，不应误认为 0.2.1 新增防火墙功能已在该 VPS 实测。

源码 ZIP 不包含上游核心归档；一键安装时会从锁定 Commit 生成并校验。目标服务器需要能够访问 GitHub，或预先提供经过校验的固定归档。
