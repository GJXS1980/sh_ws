# SSR manyuser 核心固定版本状态

**SOURCE IDENTIFIED / PIN NOT YET VERIFIED**

- 用户指定仓库：`https://github.com/ssrlive/shadowsocksr`
- 分支：`manyuser`
- README 中列出的 clone URL：`https://github.com/ShadowsocksR-Live/shadowsocksr.git`
- 实际服务入口（沿用 Toyo v2.0.38 管理脚本）：`shadowsocks/server.py`
- 公开 `setup.py` 包版本字段：`2.6.12`
- 公开 `CHANGES` 顶部 SSR 版本：`3.4.0`，日期 `2017-07-27`
- 当前 commit SHA：**未取得/未验证**
- 当前 tree SHA：**未取得/未验证**
- 当前归档 SHA256：**未取得/未验证**
- 核心源码是否随本项目打包：**否**
- 原 SSR 客户端端到端回归：**NOT TESTED**

## 已核对的上游源码事实

1. `setup.py` 报告 Python 包版本 `2.6.12`，`install_requires=[]`，旧 classifier 只声明 Python 3.3/3.4 等历史版本。
2. `CHANGES` 顶部记录 SSR 3.4.0（2017-07-27），包含 `auth_chain_b`、`initmudbjson.sh` 和运行时速度限制相关更新。
3. `shadowsocks/server.py` 调用 `daemon.daemon_exec(config)`，按 `port_password` 创建 TCPRelay 和 UDPRelay；其 INFO 启动日志会输出明文 password 和 obfs_param，需要精确日志脱敏。
4. 仓库根目录还存在另一套多用户 API/数据库管理入口。为保持原 Toyo `ssr.sh v2.0.38` 的部署语义，本项目只将 `shadowsocks/server.py` 作为服务入口，不擅自切换根目录 API/数据库管理服务。
5. 上游 README 引用的 `ssr-install.sh` 是旧式安装器；它使用浮动 manyuser 分支、关闭 wget 证书验证、设置固定默认密码并部署 init.d/rc.local。本项目不调用该脚本。

## 固定版本操作

在能够访问 GitHub 的受控 Linux 构建机上执行：

```bash
bash install/inspect-core-source.sh
bash install/prepare-core-archive.sh /root/ssr-core-source <上一步显示的40位commit>
```

第二条命令会检查提交属于 `manyuser` 分支历史，确认核心关键文件存在，并生成固定 commit 的归档和 SHA256。将 commit、tree SHA、归档 SHA256 写入受控发布记录；不要手工编造值。

本次执行容器不能解析 GitHub 域名，因此没有在本包中放入浮动分支 archive，也没有捏造 commit 或 SHA256。核心安装器仍 fail-closed。新仓库与历史 Toyo 备份仓库之间的逐文件 diff、Python/加密算法兼容实测和原 SSR 客户端回归仍需完成。
