# SSR manyuser 核心固定版本状态

**BLOCKED — 尚未固定核心归档**

- 预期仓库：`https://github.com/ToyoDAdoubiBackup/shadowsocksr`
- 上游分支名称：`manyuser`（只用于审查来源；部署必须固定到 commit）
- 公开 `setup.py` 版本字段：`2.6.12`
- 期望核心入口：`shadowsocks/server.py`
- 当前 commit SHA：**未取得/未验证**
- 当前归档 SHA256：**未取得/未验证**
- 核心源码是否随本项目打包：**否**
- 原 SSR 客户端端到端回归：**NOT TESTED**

本次构建容器不能解析 GitHub 域名，因此没有在本包中放入浮动分支 archive，也没有捏造 commit 或 SHA256。请在可访问 GitHub 的受控构建机上执行 `install/prepare-core-archive.sh`，人工审核并保存 commit 与 SHA256，再把归档复制到目标 Ubuntu 主机。

核心安装器会验证：归档 SHA256、精确顶层目录名、核心文件清单、`setup.py` 版本、空 `install_requires` 和启动日志补丁精确匹配。通过这些检查仍不等于客户端协议验收通过。
