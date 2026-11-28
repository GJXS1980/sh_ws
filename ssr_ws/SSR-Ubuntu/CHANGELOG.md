# CHANGELOG

## 0.1.0-blocked-core-pin

- 建立 SSR manyuser 管理工具工程结构。
- 新增 Python3 JSON 配置事务管理：文件锁、备份、JSON 校验、原子替换、systemd 重启失败回滚。
- 新增单端口/多端口模式转换，保留原单端口账号；多转单需要显式选择和确认。
- 新增多端口用户增删改及重复端口检查。
- 新增按原版 SSR/SS 格式生成链接和本地 qrencode 二维码。
- 新增 systemd Type=simple 服务模板及运行时配置清理。
- 新增启动日志密码脱敏补丁；服务额外使用 -q 防止 INFO 级明文密码日志。
- 新增基于 ss 的 TCP 连接统计；明确区分 UDP socket 与 TCP ESTABLISHED。
- 新增 UFW/nftables/iptables 受限规则管理、BBR sysctl 管理、libsodium 软件源检查。
- 新增迁移检测、备份和回滚工具。
- 核心固定提交和 SHA256 未取得，真实 Ubuntu 与客户端兼容测试未完成；安装器因此拒绝使用浮动 manyuser 分支。
- BT/PT/SPAM、详细日志、在线更新和生产迁移切换保持 BLOCKED。

## 0.1.1-delivery-package

- 增加固定 commit 核心归档准备脚本 `install/prepare-core-archive.sh`，使用 Git HTTPS fetch + git archive，不执行上游脚本。
- 核心安装器收紧归档顶层目录校验，并要求上游 setup.py 版本为 2.6.12 且 `install_requires=[]`。
- 安装前在 staging 目录执行核心 Python compile/import smoke test；失败时清理未提交的新核心目录。
- 增加依赖安装脚本、systemd 服务包装器和日志策略模块。
- 配置端口变化后同步处理工具 ledger 记录的防火墙规则；新增端口必须由用户确认放行。
- 加固卸载路径检查、迁移备份目录唯一性。
- 增加 Python 3.8 语法 AST 测试、打包完整性测试、脚本测试、GitHub Actions 工作流和交付报告。
- 本次交付仍不含 manyuser 核心源码包；固定核心和真实 Ubuntu/客户端测试保持 BLOCKED/NOT TESTED。

## 0.1.2-user-selected-upstream

- 根据用户提供的 `https://github.com/ssrlive/shadowsocksr/tree/manyuser` 更新核心候选来源。
- 新增 `install/inspect-core-source.sh`，用于解析分支 HEAD、commit SHA、tree SHA 并核查核心关键文件。
- `install/prepare-core-archive.sh` 改为从 ssrlive manyuser 分支历史生成固定 commit 归档和 SHA256。
- 更新核心状态、README、NOTICE、systemd 文档来源链接和上游审查报告。
- 仍未从当前构建环境获取 Git commit/tree/archive SHA256；核心部署继续 fail-closed。
- 新来源与 Toyo 备份仓库尚未完成逐文件 diff；真实 Ubuntu 和 SSR 客户端回归仍为 NOT TESTED。
