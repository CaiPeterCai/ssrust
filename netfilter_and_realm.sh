#!/bin/bash
# ============================================================
# 双栈端口转发一键部署脚本
# IPv4: nftables 内核态转发 (高性能零拷贝)
# IPv6: realm 用户态转发 (轻量高性能)
#
# 适用: Ubuntu 22.04 / 24.04 全新机器
# 用法: bash setup.sh
# ============================================================
set -e

REALM_VER="2.7.0"

# ==================== 自动检测 ====================
WAN_IF=$(ip -4 route show default | awk '{print $5; exit}')
if [ -z "$WAN_IF" ]; then
  echo "❌ 无法检测默认网卡"; exit 1
fi

LOCAL4=$(ip -4 addr show "$WAN_IF" | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
if [ -z "$LOCAL4" ]; then
  echo "❌ 无法获取 $WAN_IF 的 IPv4 地址"; exit 1
fi

LOCAL6=$(ip -6 addr show "$WAN_IF" scope global | awk '/inet6/{print $2}' | cut -d/ -f1 | head -1)
if [ -z "$LOCAL6" ]; then
  HAS_IPV6=false
else
  HAS_IPV6=true
fi

echo ""
echo "============================================"
echo "  双栈端口转发部署"
echo "============================================"
echo ""
echo "  自动检测:"
echo "    网卡: $WAN_IF"
echo "    IPv4: $LOCAL4"
if $HAS_IPV6; then
  echo "    IPv6: $LOCAL6"
else
  echo "    IPv6: (无，将仅部署 IPv4)"
fi
echo ""

# ==================== 用户输入 ====================
read -rp "  本机监听端口: " FWD_PORT
if [ -z "$FWD_PORT" ]; then
  echo "❌ 监听端口不能为空"; exit 1
fi

read -rp "  远端 IP 地址: " BACKEND
if [ -z "$BACKEND" ]; then
  echo "❌ 远端地址不能为空"; exit 1
fi

read -rp "  远端端口 [${FWD_PORT}]: " BACKEND_PORT
BACKEND_PORT=${BACKEND_PORT:-$FWD_PORT}

echo ""
echo "  转发规则:"
echo "    IPv4: $LOCAL4:$FWD_PORT -> $BACKEND:$BACKEND_PORT"
if $HAS_IPV6; then
  echo "    IPv6: [$LOCAL6]:$FWD_PORT -> $BACKEND:$BACKEND_PORT"
fi
echo ""
read -rp "  确认部署? [Y/n]: " CONFIRM
CONFIRM=${CONFIRM:-Y}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "已取消"; exit 0
fi
echo ""

# --------------------------------------------------
echo "[1/5] 内核参数"
# --------------------------------------------------
sudo tee /etc/sysctl.d/99-relay.conf >/dev/null <<EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sudo sysctl --system >/dev/null
echo "  转发 + BBR ✓"

# --------------------------------------------------
echo "[2/5] 禁用 UFW (改用 nftables)"
# --------------------------------------------------
if systemctl is-active --quiet ufw 2>/dev/null; then
  sudo systemctl disable --now ufw
fi
echo "  ✓"

# --------------------------------------------------
echo "[3/5] nftables (防火墙 + IPv4 端口转发)"
# --------------------------------------------------
sudo tee /etc/nftables.conf >/dev/null <<NFT
#!/usr/sbin/nft -f
flush ruleset

define WAN          = "$WAN_IF"
define RELAY4       = $LOCAL4
define FWD_PORT     = $FWD_PORT
define BACKEND4     = $BACKEND
define BACKEND_PORT = $BACKEND_PORT

table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;
    ct state { established, related } accept
    iif "lo" accept
    ip protocol icmp accept
    ip6 nexthdr icmpv6 accept

    tcp dport 22 ct state new limit rate 10/minute burst 5 packets accept
    tcp dport 22 accept

    iifname \$WAN tcp dport \$FWD_PORT accept
    iifname \$WAN udp dport \$FWD_PORT accept
  }

  chain forward {
    type filter hook forward priority 0; policy drop;
    ct state { established, related } accept
    ip daddr \$BACKEND4 tcp dport \$BACKEND_PORT accept
    ip daddr \$BACKEND4 udp dport \$BACKEND_PORT accept
  }

  chain output {
    type filter hook output priority 0; policy accept;
  }
}

table ip nat {
  chain prerouting {
    type nat hook prerouting priority -100; policy accept;
    iifname \$WAN tcp dport \$FWD_PORT dnat to \$BACKEND4:\$BACKEND_PORT
    iifname \$WAN udp dport \$FWD_PORT dnat to \$BACKEND4:\$BACKEND_PORT
  }
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip daddr \$BACKEND4 tcp dport \$BACKEND_PORT ip saddr != \$RELAY4 masquerade
    ip daddr \$BACKEND4 udp dport \$BACKEND_PORT ip saddr != \$RELAY4 masquerade
  }
}
NFT

sudo nft -c -f /etc/nftables.conf && sudo nft -f /etc/nftables.conf
sudo systemctl enable nftables
echo "  nftables ✓"

# --------------------------------------------------
echo "[4/5] realm (IPv6 端口转发)"
# --------------------------------------------------
if $HAS_IPV6; then
  if ! command -v realm &>/dev/null; then
    ARCH=$(uname -m)
    case "$ARCH" in
      x86_64)  REALM_ARCH="x86_64-unknown-linux-gnu" ;;
      aarch64) REALM_ARCH="aarch64-unknown-linux-gnu" ;;
      *)       echo "  不支持的架构: $ARCH"; exit 1 ;;
    esac
    cd /tmp
    curl -fsSL "https://github.com/zhboner/realm/releases/download/v${REALM_VER}/realm-${REALM_ARCH}.tar.gz" -o realm.tar.gz
    tar xzf realm.tar.gz
    sudo mv realm /usr/local/bin/realm
    sudo chmod +x /usr/local/bin/realm
    rm -f realm.tar.gz
  fi
  echo "  $(realm --version)"

  sudo mkdir -p /etc/realm
  sudo tee /etc/realm/config.toml >/dev/null <<EOF
[log]
level = "warn"

[[endpoints]]
listen = "[$LOCAL6]:$FWD_PORT"
remote = "$BACKEND:$BACKEND_PORT"

[endpoints.transport]
no_tcp = false
use_udp = true
EOF

  sudo tee /etc/systemd/system/realm.service >/dev/null <<EOF
[Unit]
Description=Realm IPv6 port forwarding
After=network-online.target nftables.service
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/realm -c /etc/realm/config.toml
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable --now realm
  echo "  realm ✓"
else
  echo "  跳过 (无公网 IPv6)"
fi

# --------------------------------------------------
echo "[5/5] 验证"
# --------------------------------------------------
echo ""
echo "============================================"
echo "  ✅ 部署完成"
echo "============================================"
echo ""
echo "  IPv4 (nftables 内核转发):"
echo "    $LOCAL4:$FWD_PORT -> $BACKEND:$BACKEND_PORT"
if $HAS_IPV6; then
  echo ""
  echo "  IPv6 (realm 用户态转发):"
  echo "    [$LOCAL6]:$FWD_PORT -> $BACKEND:$BACKEND_PORT"
fi
echo ""
echo "  防火墙: policy drop, 开放 SSH(22) + $FWD_PORT"
echo "  拥塞控制: BBR"
echo ""
echo "  常用命令:"
echo "    sudo nft list ruleset        # 查看防火墙规则"
echo "    sudo systemctl status realm  # 查看 realm 状态"
echo "    sudo ss -tlnp | grep $FWD_PORT  # 查看端口监听"
echo "============================================"
