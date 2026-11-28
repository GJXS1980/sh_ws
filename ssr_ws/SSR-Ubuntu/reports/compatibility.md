# SSR manyuser 核心兼容性调查与待验收清单

## 1. 已通过公开源码页面核对的事实

调查对象：`ToyoDAdoubiBackup/shadowsocksr` 的 `manyuser` 分支公开文件。

- `setup.py` 中包名为 `shadowsocks`，版本字段为 `2.6.12`；classifiers 列出 Python 2.6/2.7、Python 3.3/3.4。该声明不能证明 Python 3.8/3.10/3.12/3.13 均兼容。
- `server.py` 入口导入 `shell`、`daemon`、`eventloop`、`tcprelay`、`udprelay`、`asyncdns`、`manager`、`common`。
- `server.py` 调用 `daemon.daemon_exec(config)`。
- `daemon.py` 仅在 config 中出现 `daemon` 字段时才执行 start/stop/restart 守护动作；start 会 `fork()`，父进程等待约 5 秒后退出，子进程写 PID、`setsid()` 并重定向日志。
- `server.py` 按 `port_password` 建立每端口 TCPRelay 和 UDPRelay。
- `workers` 大于 1 时会 fork worker；默认值由 `shell.py` 设为 1。
- `shell.py` 声明 Python 3.3+ 可用，但只是旧源码内的最低版本检查，不是现代 Python 的兼容性保证。
- `shell.py` 解析 `-q`，把 verbose 降低到 WARN，可抑制 INFO 日志。
- `server.py` 原始启动日志会把每个端口用户的 password 和 obfs_param 写到 INFO 日志。
- `encrypt.py` 将 RC4-MD5、OpenSSL、libsodium、table 的 cipher map 合并。
- `crypto/sodium.py` 通过 ctypes 查找 libsodium，调用 Salsa20、ChaCha20 和 ChaCha20-IETF stream API。
- `obfs.py` 导入 `plain`、`http_simple`、`obfs_tls`、`verify`、`auth`、`auth_chain` 等插件模块；没有在已核对路径中找到用户需求中单独列出的 `protocol.py`，协议插件实现需以实际源码目录为准。

## 2. OpenSSL 3 风险

`crypto/openssl.py` 使用 ctypes 加载 `libcrypto`，调用 `EVP_get_cipherbyname`、`EVP_CIPHER_CTX_new`、`EVP_CipherInit_ex`、`EVP_CipherUpdate`，并对 `EVP_CIPHER_CTX_cleanup` / `EVP_CIPHER_CTX_reset` 做兼容分支。

OpenSSL 3 默认 provider 对部分旧算法（例如 RC4）可能不提供默认可用实现。尚未在 Ubuntu 22.04/24.04 的 OpenSSL 3 环境逐项运行 cipher self-test，因此：

- 不降低系统 OpenSSL 安全级别；
- 不宣称 RC4、全部 AES 变体已通过；
- 不因菜单中有算法名称就认定核心支持；
- 必须在固定核心归档中逐算法运行 `encrypt.py` 自测及真实客户端握手。

## 3. libsodium 风险

源码使用 `crypto_stream_salsa20_xor_ic`、`crypto_stream_chacha20_xor_ic` 和 `crypto_stream_chacha20_ietf_xor_ic`。后者通过 try/except 检测是否存在。必须在每个 Ubuntu 目标版本和架构检查符号存在、密钥/nonce 长度和实际加解密结果。

## 4. systemd 设计依据

新版 unit 采用 `Type=simple`，运行时配置删除 `daemon`、`pid-file`、`log-file`、`user`，并使用 `-q`。这是根据已检查的 `daemon.py` / `server.py` 逻辑设计的前台启动策略，不代表已经在真实服务器通过启停/异常恢复/开机自启测试。

详细连接日志目前不启用：虽然 `connect_verbose_info` 字段保留，但服务 `-q` 会抑制 INFO 输出；在所有核心日志均脱敏前不能开放详细日志。

## 5. 测试状态矩阵

| 环境/功能 | 状态 | 说明 |
|---|---|---|
| Debian 13 / Python 3.13.5 本地脚本静态检查 | PASS | 仅脚本自身 |
| Python 3.8 语法兼容解析 | 待测 | 需 CI Python 3.8 实际解释器 |
| Ubuntu 20.04 / Python 3.8 | NOT TESTED | 无真实 Ubuntu 环境 |
| Ubuntu 22.04 / Python 3.10 | NOT TESTED | 无真实 Ubuntu 环境 |
| Ubuntu 24.04 / Python 3.12 | NOT TESTED | 无真实 Ubuntu 环境 |
| Ubuntu 26.04 | NOT TESTED | 无真实 Ubuntu 环境 |
| AMD64 | NOT TESTED | 当前宿主架构可识别但未部署核心 |
| ARM64 | NOT TESTED | 无 ARM64 运行环境 |
| OpenSSL 3 算法矩阵 | BLOCKED | 缺少固定核心归档和真实运行测试 |
| libsodium Salsa20/ChaCha20 | BLOCKED | 未安装目标 Ubuntu 包并运行核心自测 |
| SSR TCP/UDP 端到端 | BLOCKED | 没有可运行的固定核心和客户端 |
| IPv4/IPv6 客户端兼容 | BLOCKED | 未完成真实客户端测试 |
| 原链接同账号对照 | BLOCKED | 未在旧/新服务器连接 |

## 6. 必须完成的客户端验收

在原服务器与新服务器使用相同客户端、相同 SSR 链接、相同端口/密码/加密/协议/混淆参数，逐项验证：

1. SSR 链接导入；
2. TCP 建连与实际数据传输；
3. UDP 转发；
4. IPv4；
5. IPv6；
6. 每一种原用加密方式；
7. 每一种原用 protocol 插件；
8. 每一种原用 obfs 插件；
9. `_compatible` 后缀行为；
10. 多端口账号；
11. 设备数限制与两项限速；
12. 旧配置迁移后不改密码、不改链接。

只有以上测试完成并留存日志后，才能将对应环境标记为 PASS。

## 7. 上游 Python 包元数据补充核对

在公开的上游 `manyuser` 分支 `setup.py` 页面中，包版本字段为 `2.6.12`，`install_requires=[]`，分类器只列出 Python 3.3 和 3.4（以及 Python 2.6/2.7）。因此：

- 管理器不需要为了安装 SSR 而执行未经审查的 `pip install -r requirements.txt`；
- 原核心的 Python 运行时代码仍需对目标解释器执行 compile/import 和实际运行测试；
- 上游旧 classifiers 不是 Python 3.8/3.10/3.12 的兼容承诺；
- 不因 `install_requires=[]` 就推断 OpenSSL 3、libsodium、旧算法和插件均正常。

公开源码：<https://github.com/ToyoDAdoubiBackup/shadowsocksr/blob/manyuser/setup.py>。

## 8. 固定提交与可重复归档

本项目新增 `install/prepare-core-archive.sh`：从上游 Git 仓库 fetch 用户指定的 40 位 commit，并用 `git archive` 生成 `shadowsocksr-<commit>/` 顶层目录的 tar.gz。脚本不执行上游代码、不关闭 HTTPS 证书验证。构建机输出的 SHA256 必须由部署方保存在受控记录中。

本次交付环境不能访问 GitHub，因此没有选择或写入一个未经核验的 commit，也没有捏造核心 archive hash。真实固定 commit 与 archive 仍是安装前置条件。
