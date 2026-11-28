# ssrlive/shadowsocksr manyuser 固定提交审核报告

审核对象：`046078c9568bee891f0ac74085ee82fc08e99e3e`

## 提交身份

- 仓库：`https://github.com/ssrlive/shadowsocksr`
- 分支：`manyuser`
- Commit：`046078c9568bee891f0ac74085ee82fc08e99e3e`
- Tree：`7c6884129710e658047c1c89ce17990d53f4af1c`（来自用户本机 `git rev-parse` 输出）
- 时间：`2022-12-18T20:57:50+08:00`（来自用户本机 Git 输出）
- Subject：`script issues`
- GitHub commit 页面：<https://github.com/ssrlive/shadowsocksr/commit/046078c9568bee891f0ac74085ee82fc08e99e3e>

## 源码检查

- `setup.py` blob：`50a38081a3f46790372e44929870881d5c916588`
- `setup.py` package version：`2.6.12`
- `setup.py` `install_requires=[]`
- `CHANGES` blob：`0cd91768ea269287ddf6244e23443016d5a7a6a6`
- `CHANGES` top version：`3.4.0 2017-07-27`
- `shadowsocks/server.py` blob：`5bd0d03a33b01ba7ad8434088f4441757a98fca8`
- `shadowsocks/daemon.py` blob：`8dc5608d111e36e7b4a673c7ab3c6627a0e502d7`
- `shadowsocks/shell.py` blob：`2c802a33a4bdeb02259cad8caf8d120eda919068`
- `shadowsocks/obfs.py` blob：`3dfdb141f11c264ddd46e5cfc802fd1fc87026d7`
- `shadowsocks/encrypt.py` blob：`75efe0666e56339f9959b02d55dd84c289705a2a`
- `server.py` calls `daemon.daemon_exec(config)` and uses `port_password` to build TCP/UDP relay instances.
- `daemon.py` only forks when `daemon` is present in config. The project's generated runtime config removes `daemon`, `pid-file`, `log-file`, and `user` for systemd foreground management.
- The startup log writes plaintext `password` and `obfs_param`; redact before deployment.

## Commit diff assessment

The GitHub commit diff for this commit changes only `README.md` and `ssr-install.sh`, switching installation instructions from branch `old` to branch `manyuser`. It does not itself change the protocol implementation files. The commit still identifies a concrete repository tree and is suitable as a reproducible archive source, but must not be described as a protocol-core code update.

## Safety decision

**PASS: approve fixed-commit archive generation.** The user's local inspection verified the commit is the manyuser branch head at inspection time and printed the tree SHA. The project archive-preparation script independently fetches the manyuser history, verifies the selected commit is an ancestor of that branch, checks required source paths, and creates an archive from the exact commit.

**固定归档与 Ubuntu 22.04 运行验证已完成；原客户端端到端兼容仍待验收。** 用户提供的 Vultr 实机日志记录了归档 SHA256 `32a5a0fe14749f34f14859660f29e2bf10bc0a9deb3b278a55d4b42154b2de40`、Python/OpenSSL/libsodium 加密测试、插件注册、配置管理、systemd 启动以及 TCP/UDP 2333 监听通过。OpenSSL 3 兼容补丁和启动日志脱敏补丁均由项目安装器精确匹配应用。原版 SSR 客户端真实连接和业务流量端到端结果仍为 `NOT TESTED END-TO-END`。不要执行上游 `ssr-install.sh`。
