# SSR-Ubuntu 0.2.1 测试报告

## 1. 用户提供的 Vultr 实机环境（既有记录）

- OS：Ubuntu 22.04.5 LTS
- CPU：x86_64 / amd64
- Python：3.10.12
- OpenSSL：3.0.2
- libsodium：`ldconfig -p` 可发现动态库

## 2. 既有实机测试结果

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

以上实机结果来自用户在此前对话提供的终端输出，不代表本次防火墙新增功能已在该 VPS 上实测。

## 3. 本次 0.2.1 自动化测试

`bash tests/run.sh`：**52 项 unittest 全部通过（52 PASS / 0 FAIL）**。

新增防火墙模拟测试：

- Firewalld 自动识别。
- Firewalld 运行时 TCP/UDP 放行。
- Firewalld 永久 TCP/UDP 规则。
- Firewalld 仅删除本工具创建的规则。
- UFW TCP/UDP 放行。
- 未启用防火墙时返回非致命状态。
- 无效端口拒绝。

新增账号流程测试：

- 新增用户调用防火墙 helper 并输出结果。
- 活跃防火墙放行失败时不提交账号。
- 无受支持的活动防火墙时继续创建账号并提示人工放行。
- SSR 重启失败时恢复旧配置并撤销本次新建防火墙规则。

其他检查：

- 所有 Shell 文件 `bash -n`：PASS。
- Python 编译：PASS。
- systemd unit 静态检查：由 `tests/run.sh` 执行。
- ShellCheck：若构建机未安装则显示 NOT TESTED。

## 4. 防火墙支持边界

- UFW：仅在 `Status: active` 时自动添加 TCP/UDP 规则。
- Firewalld：仅在 `firewall-cmd --state` 返回 `running` 时添加运行时及永久规则。
- 项目专用 iptables 链：保留原有受限支持逻辑。
- 同时检测到 UFW 和 Firewalld 时拒绝自动修改。
- 原生 nftables：不向未知 base chain 自动插入规则；会提示人工处理。
- 没有已启用的受支持防火墙时，不自动开启防火墙；账号可以创建，但需要人工检查 VPS 防火墙和云安全组。
- 当前测试通过 Mock 模拟防火墙命令，未在真实 UFW/Firewalld 主机上执行规则变更。

## 5. 未测试/未通过项

- 原版 SSR 客户端真实连接、同链接对照和实际代理流量：NOT TESTED END-TO-END。
- Ubuntu 20.04/24.04/26.04、ARM64：NOT TESTED。
- Vultr 云防火墙/安全组联动：NOT TESTED。
- 不同真实防火墙发行版、zone、IPv6 策略组合：仍需目标环境验收。
- 当前构建容器无法访问 GitHub Git transport，因此未重新下载上游核心归档。

## 6. 验收说明

0.2.1 已完成源码级防火墙集成和 Mock 自动化测试。首次部署或升级到真实服务器后，应先确认现有防火墙类型和规则，再用一个测试端口验证 TCP/UDP 可达性。任何生产升级仍应先备份配置和防火墙规则。
