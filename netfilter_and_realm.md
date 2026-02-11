# 双栈端口转发：nftables + realm 方案

## 需求

在中转机上实现双栈端口转发：IPv4 和 IPv6 客户端访问本机某端口时，都转发到远端 IPv4 后端（比如 Shadowsocks 落地机）。

## 方案选型

| 方案 | IPv4 | IPv6 | 优缺点 |
|------|------|------|--------|
| gost | ✅ | ✅ | 用户态，配置简单，性能一般 |
| nftables 纯内核 | ✅ | ❌ | 内核态零拷贝性能最优，但 IPv6→IPv4 需要 NAT64 |
| nftables + Jool NAT64 | ✅ | ⚠️ | 理论可行，实际 Jool 和 nftables 优先级冲突严重 |
| **nftables + realm** | ✅ | ✅ | **IPv4 内核态高性能 + IPv6 用户态可靠转发** |

### 为什么不用 nftables + Jool NAT64？

实测踩了以下坑：

1. **Jool netfilter 模式**：IPv6→IPv4 翻译成功，后端也回了包，但 Jool 翻译回 IPv6 的回程包源地址是 `64:ff9b::` 而非本机公网 IPv6。需要 SNAT 改写源地址，然而 Jool 输出的包完全绕过了 nftables 和 iptables 的 NAT 链（nft counter 始终为 0），SNAT 无法生效。

2. **Jool iptables 模式**：iptables 中 mangle PREROUTING 优先级（-150）高于 nat PREROUTING（-100），所以包先过 mangle（此时目标还没被 DNAT 改写，不匹配 Jool 规则），再过 nat（DNAT 改写后不会再回 mangle），Jool 永远拦截不到 DNAT 后的包。

3. **`flush ruleset` 的连带伤害**：nftables 配置文件开头的 `flush ruleset` 会清除所有 netfilter 表，包括 iptables 的 mangle 表里的 JOOL 规则。重启或 reload nftables 后 IPv6 必挂。

结论：Jool NAT64 不适合「nftables DNAT 改端口 + Jool 协议翻译」的组合场景。

## 最终架构

```
IPv4 客户端                                         IPv4 后端
    |                                                  ^
    | dst=中转机:FWD_PORT                              | dst=后端:BACKEND_PORT
    v                                                  |
[nftables DNAT] ──── 内核态转发，零拷贝 ──────────────>|
    中转机                                             
[realm 监听 IPv6] ── 用户态转发，TCP+UDP ─────────────>|
    ^                                                  |
    | dst=[中转机IPv6]:FWD_PORT                        |
    |                                                  
IPv6 客户端
```

- **IPv4**：nftables 在内核中直接 DNAT + masquerade，不经过用户态，性能最优
- **IPv6**：realm 绑定本机公网 IPv6 地址监听，转发到 IPv4 后端，TCP + UDP 都支持
- realm 绑定具体 IPv6 地址（而非 `[::]`），避免和 nftables 抢 IPv4 端口

## nftables 规则说明

```
table inet filter {
  input:  policy drop, 放行 established/related、SSH(限速)、转发端口
  forward: policy drop, 放行到后端 IP:PORT
  output: policy accept
}

table ip nat {
  prerouting:  DNAT  本机:FWD_PORT → 后端:BACKEND_PORT
  postrouting: masquerade (仅对非本机源 IP，避免回环)
}
```

`ip saddr != $RELAY4 masquerade` 的作用：如果本机自己访问后端（比如 curl 测试），不做 SNAT，避免回程包找不到路。只对从外部转发进来的包做 masquerade。

## realm 配置

```toml
[log]
level = "warn"

[[endpoints]]
listen = "[本机公网IPv6]:FWD_PORT"
remote = "后端IPv4:BACKEND_PORT"

[endpoints.transport]
no_tcp = false
use_udp = true
```

## 一键脚本

脚本自动检测网卡、IPv4、IPv6 地址，只需输入三个参数：

- 本机监听端口
- 远端 IP
- 远端端口

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/CaiPeterCai/ssrust/refs/heads/main/netfilter_and_realm.sh)
```

运行效果：

```
============================================
  双栈端口转发部署
============================================

  自动检测:
    网卡: eth0
    IPv4: 10.x.x.x
    IPv6: 2400:xxxx::xxxx

  本机监听端口: 12345
  远端 IP 地址: 1.2.3.4
  远端端口 [12345]: 54321

  转发规则:
    IPv4: 10.x.x.x:12345 -> 1.2.3.4:54321
    IPv6: [2400:xxxx::xxxx]:12345 -> 1.2.3.4:54321

  确认部署? [Y/n]:
```

脚本内容见附件或上方代码块。

## 文件位置

| 文件 | 用途 |
|------|------|
| `/etc/nftables.conf` | 防火墙 + IPv4 DNAT |
| `/etc/realm/config.toml` | realm IPv6 转发配置 |
| `/etc/systemd/system/realm.service` | realm 服务 |
| `/etc/sysctl.d/99-relay.conf` | 内核转发 + BBR |
| `/usr/local/bin/realm` | realm 二进制 |

## 常用命令

```bash
sudo nft list ruleset              # 查看防火墙和 NAT 规则
sudo systemctl status realm        # realm 状态
sudo systemctl restart realm       # 重启 realm
sudo ss -tlnp | grep 端口号        # 查看监听
sudo tcpdump -i eth0 -nn host 后端IP and port 后端端口 -c 20  # 抓包调试
```
