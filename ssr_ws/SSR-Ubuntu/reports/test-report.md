# SSR-Ubuntu 0.2.0 测试报告

## 1. 用户提供的 Vultr 实机环境

- OS：Ubuntu 22.04.5 LTS
- CPU：x86_64 / amd64
- Python：3.10.12
- OpenSSL：3.0.2
- libsodium：`ldconfig -p` 可发现动态库

## 2. 用户提供的实机测试结果

| 测试项 | 结果 |
|---|---|
| 固定核心 archive SHA256 | PASS |
| 核心部署与 Python compileall | PASS |
| `shadowsocks.server` / daemon / encrypt / obfs 导入 | PASS |
| OpenSSL 3 default/legacy provider 加载 | PASS |
| RC4 / RC4-MD5 / RC4-MD5-6 | PASS |
| 16 种加密算法各 50 次加解密往返 | 16 PASS / 0 FAIL |
| SSR 协议插件注册 | 7/7 PASS |
| SSR 混淆插件注册 | 5/5 PASS |
| 配置单/多端口 CRUD、备份和未知字段保留 | PASS |
| 正式安装与配置 runtime 生成 | PASS |
| systemd `ssr.service` | active (running) |
| TCP 2333 监听 | PASS |
| UDP 2333 监听 | PASS |

以上实机结果来自用户在本次对话提供的终端输出。

## 3. 本项目构建环境自动化测试

`bash tests/run.sh` 覆盖：

- Bash 语法、Python 编译和 Python 3.8 AST 兼容检查；
- 配置校验、锁、备份、原子写入、失败回滚、单/多端口 CRUD；
- SSR/SS 链接编码和 manyuser 用户覆盖；
- TCP endpoint 解析和地理位置缓存；
- 固定归档契约、日志脱敏补丁、OpenSSL 3 补丁锚点/幂等性；
- 菜单版本、安装入口、服务包装器和打包文件检查。

## 4. 未测试/未通过项

- 当前打包容器无法访问 GitHub Git transport，因此不能在此重建上游归档；固定归档 SHA256 来自用户提供的服务器输出及项目锁定记录。
- 原版 SSR 客户端真实连接、同链接对照和实际代理流量：NOT TESTED END-TO-END。
- Ubuntu 20.04/24.04/26.04、ARM64：NOT TESTED。
- ShellCheck：若构建机未安装则显示 NOT TESTED。
- 不同防火墙组合、BBR 内核参数和公网安全组：需目标环境另行验收。

## 5. 验收说明

核心加密、插件、配置管理和 Ubuntu 22.04 systemd 双协议监听已有用户实机通过记录；这不能替代原版客户端端到端兼容验收。任何更新或生产迁移仍应先做备份并在测试环境验证。

## 6. 本次 0.2.0 源码包验证记录

在 Debian GNU/Linux 13 / Python 3.13.5 / x86_64 构建容器执行：

- `bash tests/run.sh`：43 项 unittest 全部通过（43 PASS / 0 FAIL）。
- 所有 Shell 文件语法检查：PASS。
- Python compileall：PASS。
- systemd unit 静态语法检查（部署路径使用测试桩）：PASS。
- ShellCheck：NOT TESTED（未安装）。
- 源码 ZIP CRC、MANIFEST SHA256、必需文件和缓存排除检查：PASS。

本地构建容器没有 GitHub Git transport 网络，因此未在此处重新下载上游核心归档，也未重新执行真实 Ubuntu 安装。Ubuntu 22.04 实机结果见第 2 节。
