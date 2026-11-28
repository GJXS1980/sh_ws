# 原始 ssr.sh v2.0.38 源码审查报告

## 1. 输入文件

- 文件：用户上传的 `ssr(1).sh`
- 脚本版本标记：`sh_ver="2.0.38"`
- 原作者标记：Toyo
- 文件行数：`wc -l` 输出 1526 行
- 原始文件 SHA256：`431c90eb0d961ea73587807b0dee89170536c78acdbba070d0a873eb53c0d7a1`
- 原始文件副本：`original/ssr.sh.v2.0.38`
- Bash 函数定义：86 个
- 原菜单：1～15，单次读取后执行一个分支

## 2. 原始函数清单（86 个）

### 系统识别、状态和防火墙

`check_root`、`check_sys`、`check_pid`、`SSR_installation_status`、`Server_Speeder_installation_status`、`LotServer_installation_status`、`BBR_installation_status`、`Add_iptables`、`Del_iptables`、`Save_iptables`、`Set_iptables`、`menu_status`。

### 账号信息和链接

`Get_IP`、`Get_User`、`urlsafe_base64`、`ss_link_qr`、`ssr_link_qr`、`ss_ssr_determine`、`View_User`。

### 配置输入、写入和修改

`Set_config_port`、`Set_config_password`、`Set_config_method`、`Set_config_protocol`、`Set_config_obfs`、`Set_config_protocol_param`、`Set_config_speed_limit_per_con`、`Set_config_speed_limit_per_user`、`Set_config_all`、`Modify_config_port`、`Modify_config_password`、`Modify_config_method`、`Modify_config_protocol`、`Modify_config_obfs`、`Modify_config_protocol_param`、`Modify_config_speed_limit_per_con`、`Modify_config_speed_limit_per_user`、`Modify_config_connect_verbose_info`、`Modify_config_all`、`Modify_config_port_many`、`Modify_config_password_many`、`Write_configuration`、`Write_configuration_many`。

### 安装、依赖、升级和卸载

`Check_python`、`Centos_yum`、`Debian_apt`、`Download_SSR`、`Service_SSR`、`JQ_install`、`Installation_dependency`、`Install_SSR`、`Update_SSR`、`Uninstall_SSR`、`Check_Libsodium_ver`、`Install_Libsodium`。

### 连接监控

`debian_View_user_connection_info`、`centos_View_user_connection_info`、`View_user_connection_info`、`View_user_connection_info_1`、`get_IP_address`。

### 多端口和模式转换

`Modify_Config`、`List_multi_port_user`、`Add_multi_port_user`、`Modify_multi_port_user`、`Del_multi_port_user`、`Manually_Modify_Config`、`Port_mode_switching`。

### 服务管理

`Start_SSR`、`Stop_SSR`、`Restart_SSR`、`View_Log`。

### 锐速、LotServer、BBR 和其他功能

`Configure_Server_Speeder`、`Install_ServerSpeeder`、`Uninstall_ServerSpeeder`、`Configure_LotServer`、`Install_LotServer`、`Uninstall_LotServer`、`Configure_BBR`、`Install_BBR`、`Start_BBR`、`Stop_BBR`、`Status_BBR`、`Other_functions`、`BanBTPTSPAM`、`UnBanBTPTSPAM`、`Set_config_connect_verbose_info`、`Update_Shell`。

## 3. 主菜单映射

| 选项 | 原始调用函数 | 现代化处理 |
|---|---|---|
| 1 安装 SSR | `Install_SSR` | 新版安装器；固定核心提交和 SHA256 必填 |
| 2 更新 SSR | `Update_SSR` | 原版本身已禁用；新版保持 BLOCKED，等待客户端回归 |
| 3 卸载 SSR | `Uninstall_SSR` | 安全卸载管理器，默认保留核心和配置 |
| 4 libsodium | `Install_Libsodium` | 官方软件源优先、运行时库检查 |
| 5 查看账号 | `View_User` | 保留 SSR/SS 链接逻辑、本地二维码 |
| 6 连接信息 | `View_user_connection_info` | 使用 `ss`；TCP/UDP 分开说明 |
| 7 用户配置 | `Modify_Config` | Python JSON 事务和回滚 |
| 8 手动编辑 | `Manually_Modify_Config` | 编辑候选文件，JSON 校验通过后提交 |
| 9 端口模式 | `Port_mode_switching` | 显式保留账号/选择账号/确认丢弃 |
| 10～13 服务 | `Start_SSR` 等 | systemd/journald |
| 14 其他 | `Other_functions` | BBR；BT/PT/SPAM 暂时 BLOCKED；详细日志暂时 BLOCKED |
| 15 更新脚本 | `Update_Shell` | 等待签名 manifest 和固定 hash，暂时 BLOCKED |

## 4. 关键源码事实

### 4.1 核心路径和下载

- `ssr_folder=/usr/local/shadowsocksr`
- `ssr_ss_file=/usr/local/shadowsocksr/shadowsocks`
- `config_user_file=/etc/shadowsocksr/user-config.json`
- `ssr_log_file=/usr/local/shadowsocksr/shadowsocks/ssserver.log`
- 核心下载函数 `Download_SSR` 使用 `https://github.com/ToyoDAdoubiBackup/shadowsocksr/archive/manyuser.zip`，这是浮动分支 archive。
- 安装时 `Download_SSR` 会删除已存在的 `/etc/shadowsocksr`，不符合迁移安全要求。
- `Service_SSR` 从 raw GitHub 下载旧 init 脚本。

### 4.2 Python、jq 和架构

- `Check_python` 调用 `python -h`，旧安装流程安装 `python` 而非隔离 Python3。
- `JQ_install` 以 `x86_64` 和“其他架构”二分；其他架构移动 `jq-linux32`，ARM64 会被误判为 32 位。
- jq 来自核心目录内置二进制，而非系统包管理器。

### 4.3 JSON 和账号管理

- 单端口配置由 `Write_configuration` 写 `server_port` 和 `password`。
- 多端口配置由 `Write_configuration_many` 写 `port_password` 对象。
- 多端口用户添加函数 `Add_multi_port_user` 使用 `sed -i "8 i ..."` 固定行号插入。
- 修改用户通过 grep/sed 替换文本，不是 JSON 结构化操作。
- 手动编辑 `Manually_Modify_Config` 调用 vi 后没有 JSON 校验。
- 单转多模式 `Port_mode_switching` 调用 `Set_config_all` 再重写多端口配置，可能重新生成账号而非迁移原账号。
- 多转单模式重新输入单端口配置，原多端口账号可能丢失。

### 4.4 SSR 链接

- `urlsafe_base64` 使用标准 Base64 后移除换行和 `=`，并替换 `+`、`/`。
- `ssr_link_qr` 对密码单独 Base64，再将 `IP:port:protocol:method:obfs:password_base64` 编码。
- `ss_ssr_determine` 按 protocol/obfs 的兼容后缀决定是否生成 SS 链接。
- 原脚本将链接发送到 `http://doub.pw/qr/qr.php?text=...`，会把完整认证信息发送给第三方；新版不再这样做。

### 4.5 服务和日志

- 旧服务通过 `/etc/init.d/ssr` 管理。
- `check_pid` 使用 `ps | grep server.py`。
- 卸载通过 `kill -9` 停进程。
- 日志通过旧核心日志文件 tail。
- 新版 systemd 服务模板采用前台方式；运行时配置移除 daemon 管理键，使用 `-q` 抑制原核心 INFO 级密码日志。

### 4.6 连接监控和外部请求

- 原连接统计依赖 netstat/grep/awk，并按 Debian/CentOS 分支解析 tcp/tcp6。
- 原 IP 归属地使用 HTTP `freeapi.ipip.net`，每个 IP `sleep 1s`。
- `Get_IP` 中的公网 IP 查询也有未显式使用 HTTPS 的 URL。

### 4.7 风险下载和网络优化

- `Download_SSR`、`Service_SSR`、`BBR_installation_status`、`Install_Libsodium`、`BanBTPTSPAM`、`Update_Shell` 等存在 `--no-check-certificate` 或不固定版本下载。
- `Install_ServerSpeeder` 和 `Install_LotServer` 下载并执行远程脚本。
- 原 BBR 功能依赖第三方 `bbr.sh`，并提示更换内核。
- 新版移除 Server Speeder/LotServer，不自动换内核。

## 5. 新版当前实现状态

已实现：

- JSON 结构校验、文件锁、备份、临时文件、原子替换、重启检查和失败恢复。
- 单端口/多端口用户管理基本操作和模式转换。
- SSR/SS 链接编码与原版函数对照单元测试。
- 本地 qrencode 生成入口。
- systemd unit 模板和运行时配置净化。
- 日志脱敏补丁的精确匹配机制。
- `ss` TCP 连接统计。
- BBR sysctl 状态/开关脚本。
- 防火墙受限规则记录和删除入口。
- 迁移检测、备份、受控阻断和文件回滚工具。

仍未完成：

- 固定核心 commit 和 SHA256 归档；
- 完整核心 Python/OpenSSL/libsodium 兼容性实测；
- 所有加密/协议/混淆插件逐项验证；
- Ubuntu 20.04/22.04/24.04/26.04 安装实测；
- AMD64/ARM64 真实部署实测；
- 原 SSR 客户端同链接对照测试；
- BT/PT/SPAM 固定规则集；
- 详细日志全路径脱敏审计；
- 在线更新签名 manifest。
