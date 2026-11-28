# SSR manyuser 核心固定版本状态

**COMMIT PINNED / ARCHIVE SHA256 PENDING / CLIENT TEST NOT TESTED**

## 已审核的候选核心

- 仓库：`https://github.com/ssrlive/shadowsocksr.git`
- 分支：`manyuser`
- 固定 Commit：`046078c9568bee891f0ac74085ee82fc08e99e3e`
- Tree SHA：`7c6884129710e658047c1c89ce17990d53f4af1c`
- 提交日期：`2022-12-18T20:57:50+08:00`（用户本机 Git 输出）
- 提交说明：`script issues`
- `setup.py` 包版本：`2.6.12`
- `CHANGES` 顶部 SSR 版本：`3.4.0`（2017-07-27）
- 核心入口：`shadowsocks/server.py`
- 核心服务管理调用：`daemon.daemon_exec(config)`
- 多端口映射：`port_password`
- 归档文件：**尚未生成**
- 归档 SHA256：**尚未生成，不得填写猜测值**
- 原 SSR 客户端端到端回归：`NOT TESTED`

## 人工审核结论

**允许执行固定 Commit 归档生成；暂不批准生产部署。**

审核依据：

1. GitHub API 能解析该 Commit，提交说明为 `script issues`，提交作者/提交者为 `ssrlive`。
2. 该 Commit 的 diff 仅涉及 `README.md` 和 `ssr-install.sh`：把旧安装来源/分支切换为 manyuser。核心 Python 源码仍由该 Commit 的 tree 固定，因此可作为归档输入；但这也意味着不能把该 Commit 描述为一次核心协议实现更新。
3. `setup.py` 的 `version` 为 `2.6.12`，`install_requires=[]`；这不代表已验证 Python 3.8/3.10/3.12/3.13 运行兼容性。
4. `CHANGES` 顶部为 SSR 3.4.0（2017-07-27），其中记录 `auth_chain_b`、`initmudbjson.sh` 和运行时速度限制相关更新。
5. `server.py` 调用 `daemon.daemon_exec(config)`。`daemon.py` 只有在配置含 `daemon` 字段时才 fork；本项目 systemd runtime 配置移除 `daemon`、`pid-file`、`log-file`、`user`，所以预期由 systemd 直接管理前台主进程。
6. `server.py` 启动日志存在明文密码和 `obfs_param` 输出。本项目日志脱敏补丁与该固定源码行匹配；部署前必须应用补丁，并验证补丁只修改日志、不改协议处理。
7. `ssr-install.sh` 仍属于上游旧式安装脚本，不应执行。本项目只使用固定 commit 的源码归档，不调用上游安装器。

## 下一步：生成固定归档

在用户的 GitHub 可访问构建机上运行：

```bash
bash install/prepare-core-archive.sh /root/ssr-core-source 046078c9568bee891f0ac74085ee82fc08e99e3e
```

脚本会重新验证该 Commit 属于 `manyuser` 分支历史、检查核心关键文件、使用 `git archive` 生成固定归档并计算 SHA256。执行后将实际输出的归档路径和 SHA256 保存到发布记录，再运行核心安装器的离线校验/补丁/语法导入测试。

**不要执行 `ssr-install.sh`，不要用分支 ZIP 替代固定 Commit 归档。**
