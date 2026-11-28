# SSR-Ubuntu 交付状态

## 已包含在源码包中

- 原始用户上传脚本副本及 SHA256 校验记录；
- Bash 菜单入口（保留 1～15 操作布局）；
- Python3 JSON 配置管理模块；
- SSR/SS 链接生成及本地二维码调用；
- TCP 连接统计和可选 HTTPS IP 归属地查询；
- systemd unit；
- UFW/iptables 受限防火墙管理；原生 nftables 仅检测并提示人工处理；
- BBR sysctl 管理；
- 日志模式安全策略（详细 INFO 日志保持禁用）；
- 安装依赖、核心固定提交归档准备、核心校验/补丁、卸载、迁移检测/备份/阻断/回滚；
- 自动化测试、GitHub Actions 测试工作流、中文 README、CHANGELOG 和报告。

## 明确未完成/不可宣称通过

1. 本交付不含 SSR manyuser 核心源码压缩包。核心候选来源已按用户指定更新为 `https://github.com/ssrlive/shadowsocksr/tree/manyuser`，但当前执行环境无法连接 GitHub Git transport 获取固定 commit/tree SHA 并独立核验归档 SHA256。
2. 因缺少核心包，真实核心 Python/OpenSSL/libsodium 运行测试未完成。
3. 未在 Ubuntu 20.04、22.04、24.04、26.04 VM 完成安装测试。
4. 未在 ARM64 环境完成部署测试。
5. 未使用原有 SSR 客户端和原有 SSR 链接完成旧/新环境对照连接。
6. BT/PT/SPAM 封禁、详细连接日志、在线更新和生产迁移切换保持 BLOCKED。

## 使用限制

在固定 manyuser 核心 archive、commit、SHA256 准备好并通过核心安装器后，仍须在隔离 Ubuntu 测试机完成 `reports/compatibility.md` 的客户端回归矩阵。未完成之前，不建议把此版本用于生产迁移。

## 源码包构建与完整性验证

- 源码目录：`SSR-Ubuntu/`
- ZIP 文件：`/mnt/data/SSR-Ubuntu-project.zip`
- ZIP 文件包含 46 个条目，其中 45 个源文件由 `MANIFEST.sha256` 逐项校验。
- ZIP CRC 检查：PASS。
- 必需交付文件检查：PASS。
- Python 缓存文件排除检查：PASS。
- 注意：本 ZIP 是管理工具项目源码包；并未包含上游 SSR manyuser 核心归档。核心候选来源已改为用户指定的 ssrlive 仓库，并新增源码检查脚本；但核心归档因无法从当前构建环境取得并独立验证固定 commit/tree 与 SHA256，继续保持 BLOCKED。不得将此包描述为已完成 SSR 客户端端到端验收的生产安装包。
