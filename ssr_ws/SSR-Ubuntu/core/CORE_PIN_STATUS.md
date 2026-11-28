# SSR manyuser 核心固定版本记录

## 固定来源

- 仓库：`https://github.com/ssrlive/shadowsocksr.git`
- 分支：`manyuser`
- Commit：`046078c9568bee891f0ac74085ee82fc08e99e3e`
- Tree：`7c6884129710e658047c1c89ce17990d53f4af1c`
- 提交日期：`2022-12-18T20:57:50+08:00`
- `setup.py` 包版本：`2.6.12`
- `CHANGES` 记录版本：`3.4.0`
- 归档：`core/archives/shadowsocksr-046078c9568bee891f0ac74085ee82fc08e99e3e.tar.gz`
- SHA256：`32a5a0fe14749f34f14859660f29e2bf10bc0a9deb3b278a55d4b42154b2de40`

## 已完成验证（用户提供的 Vultr 实机日志）

- Ubuntu 22.04.5 LTS / x86_64 / Python 3.10.12。
- OpenSSL 3.0.2；系统动态库中存在 libsodium。
- 固定归档 SHA256 校验通过。
- 核心部署、Python 编译、核心模块导入通过。
- OpenSSL 3 default/legacy provider 补丁已应用；RC4、RC4-MD5、RC4-MD5-6 加解密通过。
- 16 种加密方式各 50 次加解密往返测试通过（16 PASS / 0 FAIL）。
- SSR 协议插件 7/7 注册测试通过；混淆插件 5/5 注册测试通过。
- 配置管理单端口/多端口转换、用户增删改、备份和未知字段保留测试通过。
- 正式安装后 `ssr.service` 为 `active (running)`；TCP 和 UDP 2333 均处于监听状态。

以上是用户提供的实际终端记录，不代表本项目构建容器独立重跑了 Vultr 实机测试。

## 补丁边界

1. `patches/redact-server-password.patch` / `core_install.py`：只对固定源码中的启动日志行做精确匹配脱敏，隐藏密码与 obfs 参数。
2. `install/patch_core_crypto.py`：在 OpenSSL 3 上显式保留 default/legacy Provider、RC4 查找前加载 legacy Provider，并使 EVP cipher context 清理幂等。

两项补丁都要求源码锚点精确匹配；未知源码布局时安装中止。它们不替换 SSR 核心，不修改 SSR 协议插件或链路格式。

## 尚未宣称通过

- 原版 SSR 客户端对照连接和真实外网流量端到端验收：`NOT TESTED END-TO-END`。
- Ubuntu 20.04、24.04、26.04 和 ARM64：未在本次记录中实测。
- 不同 UFW / iptables / nftables 规则组合及云安全组：未完成全面集成测试。
- 在线核心更新、在线管理器更新、BT/PT/SPAM 规则和自动生产迁移保持 BLOCKED。
