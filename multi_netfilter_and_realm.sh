#!/usr/bin/env bash
# ============================================================
# 双栈多端口批量转发一键部署脚本（顺手版 / 持久化 / 可反复编辑）
# IPv4: nftables 内核态转发
# IPv6: realm 用户态转发
#
# 特性：
# - 启动时自动读取已有规则
# - 规则持久化到 /etc/relay-rules.conf
# - 可交互式新增 / 删除 / 查看 / 修改规则
# - 添加规则时，每次都会询问是否继续添加
# - 应用配置后不会强制退出，而是返回主菜单，便于继续调整
# - 可清空全部规则
# - 可重新加载磁盘上的规则文件
# ============================================================

set -euo pipefail

REALM_VER="2.7.0"
SYSCTL_FILE="/etc/sysctl.d/99-relay.conf"
NFT_FILE="/etc/nftables.conf"
REALM_DIR="/etc/realm"
REALM_CFG="${REALM_DIR}/config.toml"
REALM_SERVICE="/etc/systemd/system/realm.service"
RULES_FILE="/etc/relay-rules.conf"

declare -a FWD_PORTS=()
declare -a BACKENDS=()
declare -a BACKEND_PORTS=()

msg() { echo -e "$*"; }
die() { echo "❌ $*" >&2; exit 1; }

is_valid_port() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

is_valid_ipv4() {
  local ip="${1:-}"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS=.
  read -r o1 o2 o3 o4 <<<"$ip"
  for o in "$o1" "$o2" "$o3" "$o4"; do
    (( o >= 0 && o <= 255 )) || return 1
  done
}

pause() {
  echo ""
  read -rp "按回车继续..." _
}

rule_exists_exact() {
  local port="$1" backend="$2" backend_port="$3"
  local i
  for i in "${!FWD_PORTS[@]}"; do
    if [[ "${FWD_PORTS[$i]}" == "$port" && "${BACKENDS[$i]}" == "$backend" && "${BACKEND_PORTS[$i]}" == "$backend_port" ]]; then
      return 0
    fi
  done
  return 1
}

find_rule_by_port() {
  local port="$1"
  local i
  for i in "${!FWD_PORTS[@]}"; do
    if [[ "${FWD_PORTS[$i]}" == "$port" ]]; then
      echo "$i"
      return 0
    fi
  done
  return 1
}

load_existing_rules() {
  FWD_PORTS=()
  BACKENDS=()
  BACKEND_PORTS=()

  if [[ -f "$RULES_FILE" ]]; then
    while IFS=',' read -r fwd backend backend_port; do
      [[ -n "${fwd:-}" && -n "${backend:-}" && -n "${backend_port:-}" ]] || continue
      if is_valid_port "$fwd" && is_valid_ipv4 "$backend" && is_valid_port "$backend_port"; then
        FWD_PORTS+=("$fwd")
        BACKENDS+=("$backend")
        BACKEND_PORTS+=("$backend_port")
      fi
    done < <(sudo awk 'NF && $1 !~ /^#/' "$RULES_FILE")
  fi
}

save_rules() {
  local tmp
  tmp=$(mktemp)
  {
    echo "# fwd_port,backend_ipv4,backend_port"
    local i
    for i in "${!FWD_PORTS[@]}"; do
      echo "${FWD_PORTS[$i]},${BACKENDS[$i]},${BACKEND_PORTS[$i]}"
    done
  } > "$tmp"
  sudo install -m 600 "$tmp" "$RULES_FILE"
  rm -f "$tmp"
}

print_rules() {
  echo ""
  echo "当前规则列表："
  if (( ${#FWD_PORTS[@]} == 0 )); then
    echo "  (空)"
    return
  fi

  printf '  %-5s %-12s %-18s %-12s\n' "序号" "监听端口" "后端 IPv4" "后端端口"
  printf '  %-5s %-12s %-18s %-12s\n' "----" "--------" "---------" "--------"
  local i
  for i in "${!FWD_PORTS[@]}"; do
    printf '  %-5s %-12s %-18s %-12s\n' "$((i+1))" "${FWD_PORTS[$i]}" "${BACKENDS[$i]}" "${BACKEND_PORTS[$i]}"
  done
}

add_rule_once() {
  local fwd backend backend_port

  echo ""
  read -rp " 本机监听端口: " fwd
  is_valid_port "$fwd" || { echo "❌ 监听端口必须是 1-65535"; return 1; }

  read -rp " 远端 IPv4 地址: " backend
  is_valid_ipv4 "$backend" || { echo "❌ 远端地址必须是合法 IPv4"; return 1; }

  read -rp " 远端端口 [${fwd}]: " backend_port
  backend_port=${backend_port:-$fwd}
  is_valid_port "$backend_port" || { echo "❌ 远端端口必须是 1-65535"; return 1; }

  if rule_exists_exact "$fwd" "$backend" "$backend_port"; then
    echo "⚠️  这条规则已经存在，未重复添加。"
    return 0
  fi

  local existing_idx
  if existing_idx=$(find_rule_by_port "$fwd"); then
    echo "⚠️  监听端口 ${fwd} 已存在：${FWD_PORTS[$existing_idx]} -> ${BACKENDS[$existing_idx]}:${BACKEND_PORTS[$existing_idx]}"
    read -rp " 是否用新规则覆盖它? [y/N]: " overwrite
    overwrite=${overwrite:-N}
    if [[ "$overwrite" =~ ^[Yy]$ ]]; then
      BACKENDS[$existing_idx]="$backend"
      BACKEND_PORTS[$existing_idx]="$backend_port"
      echo "✅ 已覆盖: ${fwd} -> ${backend}:${backend_port}"
    else
      echo "已取消本次添加。"
    fi
    return 0
  fi

  FWD_PORTS+=("$fwd")
  BACKENDS+=("$backend")
  BACKEND_PORTS+=("$backend_port")
  echo "✅ 已添加: ${fwd} -> ${backend}:${backend_port}"
}

add_rules_interactive() {
  while true; do
    add_rule_once || true
    echo ""
    read -rp " 继续添加规则? [y/N]: " more
    more=${more:-N}
    [[ "$more" =~ ^[Yy]$ ]] || break
  done
}

delete_rule_interactive() {
  if (( ${#FWD_PORTS[@]} == 0 )); then
    echo ""
    echo "当前没有可删除的规则。"
    return
  fi

  while true; do
    print_rules
    echo ""
    read -rp " 输入要删除的序号（可输入多个，空格分隔；直接回车取消）: " line
    [[ -z "${line:-}" ]] && return

    local -a idxs=()
    local token
    for token in $line; do
      [[ "$token" =~ ^[0-9]+$ ]] || { echo "❌ 存在非法序号: $token"; return; }
      (( token >= 1 && token <= ${#FWD_PORTS[@]} )) || { echo "❌ 序号超出范围: $token"; return; }
      idxs+=("$token")
    done

    echo ""
    echo "将删除以下规则："
    local idx pos
    for idx in "${idxs[@]}"; do
      pos=$((idx-1))
      echo "  [$idx] ${FWD_PORTS[$pos]} -> ${BACKENDS[$pos]}:${BACKEND_PORTS[$pos]}"
    done

    read -rp " 确认删除? [y/N]: " confirm
    confirm=${confirm:-N}
    [[ "$confirm" =~ ^[Yy]$ ]] || return

    # 从大到小删，避免索引位移
    IFS=$'\n' idxs=($(printf "%s\n" "${idxs[@]}" | sort -rn | uniq))
    unset IFS
    for idx in "${idxs[@]}"; do
      pos=$((idx-1))
      unset 'FWD_PORTS[pos]'
      unset 'BACKENDS[pos]'
      unset 'BACKEND_PORTS[pos]'
    done

    FWD_PORTS=("${FWD_PORTS[@]}")
    BACKENDS=("${BACKENDS[@]}")
    BACKEND_PORTS=("${BACKEND_PORTS[@]}")

    echo "✅ 删除完成。"
    return
  done
}

edit_rule_interactive() {
  if (( ${#FWD_PORTS[@]} == 0 )); then
    echo ""
    echo "当前没有可修改的规则。"
    return
  fi

  print_rules
  echo ""
  read -rp " 输入要修改的序号（直接回车取消）: " idx
  [[ -z "${idx:-}" ]] && return
  [[ "$idx" =~ ^[0-9]+$ ]] || { echo "❌ 请输入数字序号"; return; }
  (( idx >= 1 && idx <= ${#FWD_PORTS[@]} )) || { echo "❌ 序号超出范围"; return; }

  local pos=$((idx-1))
  local cur_fwd="${FWD_PORTS[$pos]}"
  local cur_backend="${BACKENDS[$pos]}"
  local cur_backend_port="${BACKEND_PORTS[$pos]}"

  echo ""
  echo "当前规则: ${cur_fwd} -> ${cur_backend}:${cur_backend_port}"
  echo "直接回车表示保留原值。"

  local new_fwd new_backend new_backend_port
  read -rp " 新监听端口 [${cur_fwd}]: " new_fwd
  new_fwd=${new_fwd:-$cur_fwd}
  is_valid_port "$new_fwd" || { echo "❌ 监听端口必须是 1-65535"; return; }

  read -rp " 新后端 IPv4 [${cur_backend}]: " new_backend
  new_backend=${new_backend:-$cur_backend}
  is_valid_ipv4 "$new_backend" || { echo "❌ 后端 IPv4 非法"; return; }

  read -rp " 新后端端口 [${cur_backend_port}]: " new_backend_port
  new_backend_port=${new_backend_port:-$cur_backend_port}
  is_valid_port "$new_backend_port" || { echo "❌ 后端端口必须是 1-65535"; return; }

  local existing_idx
  if existing_idx=$(find_rule_by_port "$new_fwd"); then
    if [[ "$existing_idx" != "$pos" ]]; then
      echo "❌ 监听端口 ${new_fwd} 已被另一条规则占用。"
      return
    fi
  fi

  FWD_PORTS[$pos]="$new_fwd"
  BACKENDS[$pos]="$new_backend"
  BACKEND_PORTS[$pos]="$new_backend_port"
  echo "✅ 已更新: ${new_fwd} -> ${new_backend}:${new_backend_port}"
}

write_sysctl() {
  sudo tee "$SYSCTL_FILE" >/dev/null <<'EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sudo sysctl --system >/dev/null
}

build_ports_csv() {
  local IFS=,
  printf '%s' "$*"
}

write_empty_nftables() {
  sudo tee "$NFT_FILE" >/dev/null <<EOF
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;

    iifname "lo" accept
    ct state established,related accept
    ct state invalid drop

    tcp dport 22 ct state new limit rate 30/minute accept

    ip protocol icmp accept
    ip6 nexthdr ipv6-icmp accept
  }

  chain forward {
    type filter hook forward priority 0; policy drop;
    ct state established,related accept;
  }

  chain output {
    type filter hook output priority 0; policy accept;
  }
}

table ip nat {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
  }

  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
  }
}
EOF
  sudo systemctl enable nftables >/dev/null 2>&1 || true
  sudo nft -f "$NFT_FILE"
}

write_nftables() {
  if (( ${#FWD_PORTS[@]} == 0 )); then
    write_empty_nftables
    return
  fi

  local ports_csv
  ports_csv=$(build_ports_csv "${FWD_PORTS[@]}")

  sudo tee "$NFT_FILE" >/dev/null <<EOF
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;

    iifname "lo" accept
    ct state established,related accept
    ct state invalid drop

    tcp dport 22 ct state new limit rate 30/minute accept
    udp dport { ${ports_csv} } accept
    tcp dport { ${ports_csv} } accept

    ip protocol icmp accept
    ip6 nexthdr ipv6-icmp accept
  }

  chain forward {
    type filter hook forward priority 0; policy drop;
    ct state established,related accept
    iifname "${WAN_IF}" oifname "${WAN_IF}" accept
  }

  chain output {
    type filter hook output priority 0; policy accept;
  }
}

table ip nat {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
EOF

  local i
  for i in "${!FWD_PORTS[@]}"; do
    sudo tee -a "$NFT_FILE" >/dev/null <<EOF
    tcp dport ${FWD_PORTS[$i]} dnat to ${BACKENDS[$i]}:${BACKEND_PORTS[$i]}
    udp dport ${FWD_PORTS[$i]} dnat to ${BACKENDS[$i]}:${BACKEND_PORTS[$i]}
EOF
  done

  sudo tee -a "$NFT_FILE" >/dev/null <<EOF
  }

  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    oifname "${WAN_IF}" masquerade
  }
}
EOF

  sudo systemctl enable nftables >/dev/null 2>&1 || true
  sudo nft -f "$NFT_FILE"
}

install_realm() {
  if command -v realm >/dev/null 2>&1; then
    return
  fi

  local arch realm_arch
  arch=$(uname -m)
  case "$arch" in
    x86_64) realm_arch="x86_64-unknown-linux-gnu" ;;
    aarch64) realm_arch="aarch64-unknown-linux-gnu" ;;
    *) die "不支持的架构: $arch" ;;
  esac

  cd /tmp
  curl -fsSL "https://github.com/zhboner/realm/releases/download/v${REALM_VER}/realm-${realm_arch}.tar.gz" -o realm.tar.gz
  tar xzf realm.tar.gz
  sudo mv realm /usr/local/bin/realm
  sudo chmod +x /usr/local/bin/realm
  rm -f realm.tar.gz
}

disable_realm_if_present() {
  if systemctl list-unit-files | awk '{print $1}' | grep -qx 'realm.service'; then
    sudo systemctl disable --now realm >/dev/null 2>&1 || true
  fi
}

write_realm() {
  sudo mkdir -p "$REALM_DIR"

  if (( ${#FWD_PORTS[@]} == 0 )); then
    disable_realm_if_present
    sudo tee "$REALM_CFG" >/dev/null <<'EOF'
[log]
level = "warn"

[network]
no_tcp = false
use_udp = true
ipv6_only = true
EOF
    return
  fi

  sudo tee "$REALM_CFG" >/dev/null <<'EOF'
[log]
level = "warn"

[network]
no_tcp = false
use_udp = true
ipv6_only = true
EOF

  local i
  for i in "${!FWD_PORTS[@]}"; do
    sudo tee -a "$REALM_CFG" >/dev/null <<EOF

[[endpoints]]
listen = "[::]:${FWD_PORTS[$i]}"
remote = "${BACKENDS[$i]}:${BACKEND_PORTS[$i]}"
EOF
  done

  sudo tee "$REALM_SERVICE" >/dev/null <<'EOF'
[Unit]
Description=realm IPv6 relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/realm -c /etc/realm/config.toml
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable --now realm >/dev/null
}

apply_all() {
  echo ""
  echo "[1/5] 保存规则"
  save_rules
  echo " ✓"

  echo "[2/5] 内核参数"
  write_sysctl
  echo " 转发 + BBR ✓"

  echo "[3/5] 禁用 UFW (改用 nftables)"
  if systemctl is-active --quiet ufw 2>/dev/null; then
    sudo systemctl disable --now ufw
  fi
  echo " ✓"

  echo "[4/5] nftables (防火墙 + IPv4 多端口转发)"
  write_nftables
  echo " ✓"

  if $HAS_IPV6; then
    echo "[5/5] realm (IPv6 多端口转发)"
    install_realm
    write_realm
    echo " ✓"
  else
    echo "[5/5] 跳过 realm (无 IPv6)"
    echo " ✓"
  fi
}

show_runtime_summary() {
  echo ""
  echo "============================================"
  echo " 已应用配置"
  echo "============================================"
  echo " 网卡: $WAN_IF"
  echo " IPv4: $LOCAL4"
  if $HAS_IPV6; then
    echo " IPv6: $LOCAL6"
  else
    echo " IPv6: (无)"
  fi
  print_rules
  echo ""
  echo " 规则文件: $RULES_FILE"
  echo " nftables: $NFT_FILE"
  if $HAS_IPV6; then
    echo " realm配置: $REALM_CFG"
  fi
  echo "============================================"
}

show_header() {
  echo ""
  echo "============================================"
  echo " 双栈多端口批量转发部署（顺手版）"
  echo "============================================"
  echo " 网卡: $WAN_IF"
  echo " IPv4: $LOCAL4"
  if $HAS_IPV6; then
    echo " IPv6: $LOCAL6"
  else
    echo " IPv6: (无，将仅部署 IPv4)"
  fi
  echo " 已加载规则数: ${#FWD_PORTS[@]}"
  echo " 规则文件: $RULES_FILE"
  echo "============================================"
}

main_menu() {
  while true; do
    show_header
    echo ""
    echo "请选择操作："
    echo "  1) 查看当前规则"
    echo "  2) 添加规则"
    echo "  3) 删除规则"
    echo "  4) 修改一条规则"
    echo "  5) 应用当前规则"
    echo "  6) 清空全部规则"
    echo "  7) 重新从磁盘读取规则"
    echo "  8) 查看当前监听/服务状态"
    echo "  0) 退出"
    echo ""
    read -rp " 输入选项 [0-8]: " choice

    case "${choice:-}" in
      1)
        print_rules
        pause
        ;;
      2)
        add_rules_interactive
        echo ""
        read -rp " 现在应用配置吗? [Y/n]: " yes
        yes=${yes:-Y}
        if [[ "$yes" =~ ^[Yy]$ ]]; then
          apply_all
          show_runtime_summary
        else
          echo "已保留在内存中，尚未写入系统。"
          echo "可稍后选择“应用当前规则”。"
        fi
        pause
        ;;
      3)
        delete_rule_interactive
        echo ""
        read -rp " 现在应用配置吗? [Y/n]: " yes
        yes=${yes:-Y}
        if [[ "$yes" =~ ^[Yy]$ ]]; then
          apply_all
          show_runtime_summary
        else
          echo "删除结果仅保留在内存中，尚未写入系统。"
        fi
        pause
        ;;
      4)
        edit_rule_interactive
        echo ""
        read -rp " 现在应用配置吗? [Y/n]: " yes
        yes=${yes:-Y}
        if [[ "$yes" =~ ^[Yy]$ ]]; then
          apply_all
          show_runtime_summary
        else
          echo "修改结果仅保留在内存中，尚未写入系统。"
        fi
        pause
        ;;
      5)
        apply_all
        show_runtime_summary
        pause
        ;;
      6)
        read -rp " 确认清空全部规则? [y/N]: " yes
        yes=${yes:-N}
        if [[ "$yes" =~ ^[Yy]$ ]]; then
          FWD_PORTS=()
          BACKENDS=()
          BACKEND_PORTS=()
          echo "✅ 已清空内存中的全部规则。"
          read -rp " 现在应用配置吗? [Y/n]: " apply_now
          apply_now=${apply_now:-Y}
          if [[ "$apply_now" =~ ^[Yy]$ ]]; then
            apply_all
            show_runtime_summary
          fi
        fi
        pause
        ;;
      7)
        load_existing_rules
        echo "✅ 已重新从 $RULES_FILE 读取规则。"
        pause
        ;;
      8)
        echo ""
        echo "systemctl status nftables --no-pager"
        sudo systemctl status nftables --no-pager || true
        echo ""
        if $HAS_IPV6; then
          echo "systemctl status realm --no-pager"
          sudo systemctl status realm --no-pager || true
          echo ""
        fi
        local port_pattern
        if (( ${#FWD_PORTS[@]} > 0 )); then
          port_pattern=$(build_ports_csv "${FWD_PORTS[@]}" | sed 's/,/|/g')
          echo "ss -tulnp | egrep '$port_pattern'"
          sudo ss -tulnp | egrep "$port_pattern" || true
        else
          echo "当前没有规则，跳过 ss 检查。"
        fi
        pause
        ;;
      0)
        echo "已退出。"
        exit 0
        ;;
      *)
        echo "❌ 无效选项"
        pause
        ;;
    esac
  done
}

# ==================== 自动检测 ====================
WAN_IF=$(ip -4 route show default | awk '{print $5; exit}')
[[ -n "${WAN_IF:-}" ]] || die "无法检测默认网卡"

LOCAL4=$(ip -4 addr show "$WAN_IF" | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
[[ -n "${LOCAL4:-}" ]] || die "无法获取 ${WAN_IF} 的 IPv4 地址"

LOCAL6=$(ip -6 addr show "$WAN_IF" scope global | awk '/inet6/{print $2}' | cut -d/ -f1 | head -1 || true)
if [[ -n "${LOCAL6:-}" ]]; then
  HAS_IPV6=true
else
  HAS_IPV6=false
fi

load_existing_rules
main_menu
