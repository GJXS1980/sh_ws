# 兼容性与验收矩阵

## 当前已验证

| 环境/功能 | 状态 | 证据范围 |
|---|---|---|
| Ubuntu 22.04.5 / x86_64 / Python 3.10.12 | PASS（用户实机记录） | 核心安装、systemd 启动、TCP/UDP 2333 监听 |
| OpenSSL 3.0.2 RC4 Provider | PASS（用户实机记录） | RC4、RC4-MD5、RC4-MD5-6 往返测试 |
| 16 种加密算法 | PASS（用户实机记录） | 每种 50 次加解密往返 |
| 协议插件 | PASS（用户实机记录） | 7/7 注册 |
| 混淆插件 | PASS（用户实机记录） | 5/5 注册 |
| 配置管理 | PASS（用户实机记录） | 单/多端口转换、添加、修改、删除、备份、未知字段保留 |
| SSR/SS URL 编码 | PASS（项目单元测试） | 对照原脚本 URL-safe Base64 载荷 |

## 仍需目标环境验收

| 环境/功能 | 状态 |
|---|---|
| 原版 SSR 客户端使用生成链接连接 | NOT TESTED END-TO-END |
| 实际 TCP/UDP 代理流量 | NOT TESTED END-TO-END |
| IPv4/IPv6 客户端兼容 | NOT TESTED END-TO-END |
| Ubuntu 20.04 / 24.04 / 26.04 | NOT TESTED |
| ARM64 | NOT TESTED |
| UFW / iptables-nft / nftables 各种规则策略 | NOT TESTED |
| Vultr 云防火墙/安全组 | 需在控制台单独检查 |

## 兼容边界

- 服务入口保持上游 `shadowsocks/server.py`，不替换协议核心。
- `port_password` 仍由原 manyuser 核心处理。
- 链接生成保持原版 SSR URL-safe Base64 载荷规则；IPv6 链接仍需客户端专门验证。
- OpenSSL 3 补丁只处理 Provider 加载和 EVP context 生命周期，不修改 SSR 协议逻辑。
