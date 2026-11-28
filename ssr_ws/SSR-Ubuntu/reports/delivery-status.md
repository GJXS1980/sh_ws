# SSR-Ubuntu 0.2.0 交付状态

## 已包含

- 固定 SSR manyuser Commit、Tree 和归档 SHA256。
- 根目录一键安装入口 `install.sh`，自动获取固定 Commit 归档并校验 SHA256。
- 精确日志脱敏补丁与 OpenSSL 3 RC4/provider、EVP context 生命周期补丁。
- systemd 前台服务、专用 `ssr` 用户、随机初始密码和配置校验。
- SSR/SS 链接生成、本地二维码、账号显示、单/多端口用户管理。
- 配置备份/恢复、服务管理、TCP 连接统计、可选地理位置查询、防火墙和 BBR 模块。
- 卸载、迁移检测/备份/回滚、测试套件和简化 README。

## 用户提供的实机验证记录

- Ubuntu 22.04.5 LTS / x86_64 / Python 3.10.12 / OpenSSL 3.0.2。
- 核心归档 SHA256 校验通过，核心部署、编译和 import 通过。
- 16 种加密算法各 50 次往返测试全部通过；协议插件 7/7、混淆插件 5/5。
- 配置管理 CRUD、单/多端口转换、备份和字段保留通过。
- 正式安装后 `ssr.service` active；TCP/UDP 2333 同时监听。

这些是用户提供的服务器终端结果，不是当前构建容器对远端 VPS 的独立重跑。

## 未宣称完成

- 原版 SSR 客户端真实连接及实际代理流量端到端测试。
- Ubuntu 20.04、24.04、26.04 和 ARM64 实机测试。
- UFW、iptables-nft、原生 nftables 多种规则组合的全面集成测试。
- 核心/管理器在线更新、BT/PT/SPAM 规则、详细连接日志和自动生产迁移。

源码 ZIP 不包含上游核心归档；一键安装时会从锁定 Commit 生成并校验。若目标服务器不能访问 GitHub，可手动放入已核验的固定归档。

## 本次源码包验证

- `bash tests/run.sh`：43 项单元测试全部通过。
- Shell 语法、Python 编译、systemd unit 静态检查：PASS。
- ZIP CRC、MANIFEST SHA256、必需文件和缓存排除：PASS。
- ShellCheck：NOT TESTED（构建容器未安装）。
