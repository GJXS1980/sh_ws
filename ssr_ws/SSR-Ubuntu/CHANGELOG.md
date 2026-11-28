# Changelog

## 0.2.0 - 2026-11-28

- 固定 SSR manyuser Commit `046078c9568bee891f0ac74085ee82fc08e99e3e` 和已验证归档 SHA256。
- 新增 OpenSSL 3 Provider 与 EVP cipher context 生命周期补丁，并将补丁状态写入核心元数据。
- 安装前增加核心加密往返 smoke test，覆盖 OpenSSL 算法；检测到 libsodium 时同时检查 Salsa20/ChaCha20。
- 新增根目录 `install.sh` 一键安装入口：从 CORE.lock 自动获取固定源码归档、核对 SHA256，再调用正式安装器。
- 修复菜单安装调用，统一通过 `bash` 执行安装/卸载脚本，降低 ZIP 解压后执行权限丢失的影响。
- 修正 libsodium 检查：系统已存在动态库时不再误报“软件源未提供”。
- 更新 README、核心锁定记录和测试报告，明确 Ubuntu 22.04 实机状态与客户端端到端测试边界。

## 0.1.1

- 固定核心归档准备与 SHA256 校验流程。
- 配置事务、用户管理、SSR/SS 链接、本地二维码、连接统计、防火墙和 BBR 管理模块。
