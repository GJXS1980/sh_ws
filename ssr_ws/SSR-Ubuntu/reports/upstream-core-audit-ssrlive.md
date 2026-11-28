# 用户指定 ssrlive manyuser 上游源码审查（公开文件核对）

## 来源

- 用户给定页面：<https://github.com/ssrlive/shadowsocksr/tree/manyuser>
- README 中自述的 clone 地址：<https://github.com/ShadowsocksR-Live/shadowsocksr.git>
- 分支：`manyuser`

## 已通过公开文件核对的事实

- `setup.py`：Python 包名 `shadowsocks`，包版本 `2.6.12`，`install_requires=[]`，旧 classifier 列出 Python 3.3/3.4。
- `CHANGES`：顶部为 SSR 版本 `3.4.0`，日期 `2017-07-27`；列出 `auth_chain_b`、`initmudbjson.sh`、运行时速度限制等变更。
- `shadowsocks/server.py`：调用 `daemon.daemon_exec(config)`；处理 `port_password` 字典；每个端口创建 TCPRelay 和 UDPRelay；启动 INFO 日志包含明文 password 和 obfs_param。
- 仓库根目录 `server.py` 是另一个 API/数据库用户管理线程入口。为了忠实沿用用户提供的 Toyo v2.0.38 管理脚本，本项目继续以 `shadowsocks/server.py` 为 SSR 服务入口，不擅自切换根目录服务。
- README 展示旧式 `ssr-install.sh` 安装方式；该脚本内容包含浮动分支 git clone、`wget --no-check-certificate`、固定默认密码、旧 init.d/rc.local 管理。SSR-Ubuntu 不执行此安装脚本，只取其源码仓库作为待固定核心来源。

## 尚未核实

- GitHub Git transport 当前分支头对应的真实 commit SHA 和 tree SHA。
- `ssrlive/shadowsocksr` 与 `ToyoDAdoubiBackup/shadowsocksr` 对应 manyuser 分支之间的逐文件差异。
- 固定 commit 的完整归档 SHA256。
- 固定核心在 Ubuntu 20.04/22.04/24.04/26.04 的运行兼容性。
- 原 SSR 客户端的同链接 TCP/UDP/IPv4/IPv6 回归。

本执行环境无法解析 github.com，因此没有虚构 SHA 值。请在能访问 GitHub 的机器上运行 `install/inspect-core-source.sh` 和 `install/prepare-core-archive.sh`，然后把 commit/tree/archive SHA256 记录在正式发布清单中。
