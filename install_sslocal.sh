#!/usr/bin/env bash

set -euo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Error: This script must be run as root." >&2
    exit 1
fi

SS_DIR="/etc/shadowsocks"
SS_BIN="/usr/local/bin/sslocal"
SS_CONFIG="${SS_DIR}/local-config.json"
SS_SERVICE="/etc/systemd/system/sslocal.service"
LOCAL_ADDRESS="127.0.0.1"
LOCAL_PORT="1080"

install_deps() {
    if command -v apt >/dev/null 2>&1; then
        apt update -y
        DEBIAN_FRONTEND=noninteractive apt install -y ca-certificates curl wget jq xz-utils tar
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y ca-certificates curl wget jq xz tar
    elif command -v yum >/dev/null 2>&1; then
        yum install -y epel-release || true
        yum install -y ca-certificates curl wget jq xz tar
    else
        echo "Unsupported package manager. Please install: curl wget jq xz tar" >&2
        exit 1
    fi
}

detect_arch() {
    case "$(uname -m)" in
        i386|i686) ARCH="i686" ;;
        armv7*|armv6l) ARCH="arm" ;;
        aarch64|armv8*) ARCH="aarch64" ;;
        x86_64|amd64) ARCH="x86_64" ;;
        *)
            echo "Unsupported architecture: $(uname -m)" >&2
            exit 1
            ;;
    esac
}

prompt_required() {
    local label="$1"
    local value=""
    while true; do
        read -r -p "${label}: " value
        if [[ -n "${value}" ]]; then
            printf '%s\n' "${value}"
            return
        fi
        echo "Input cannot be empty."
    done
}

prompt_port() {
    local value=""
    while true; do
        read -r -p "请输入服务器端口: " value
        if [[ "${value}" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 65535 )); then
            printf '%s\n' "${value}"
            return
        fi
        echo "端口必须是 1-65535 之间的数字。"
    done
}

prompt_inputs() {
    echo "请填写远端 Shadowsocks 服务器信息："
    SS_SERVER="$(prompt_required "请输入服务器 IP 或域名")"
    SS_SERVER_PORT="$(prompt_port)"
    SS_PASSWORD="$(prompt_required "请输入密码")"
    SS_METHOD="$(prompt_required "请输入加密方式 (例如 chacha20-ietf-poly1305 / aes-256-cfb / aes-256-gcm)")"
}

install_sslocal() {
    local version tarball url tmpdir

    version="$(curl -fsSL https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases \
        | jq -r '[.[] | select(.prerelease == false and .draft == false)][0].tag_name')"

    if [[ -z "${version}" || "${version}" == "null" ]]; then
        echo "Failed to fetch latest shadowsocks-rust version." >&2
        exit 1
    fi

    tarball="shadowsocks-${version}.${ARCH}-unknown-linux-gnu.tar.xz"
    url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${version}/${tarball}"
    tmpdir="$(mktemp -d)"
    trap "rm -rf '${tmpdir}'" EXIT

    wget -qO "${tmpdir}/${tarball}" "${url}"
    tar -xJf "${tmpdir}/${tarball}" -C "${tmpdir}"

    if [[ ! -f "${tmpdir}/sslocal" ]]; then
        echo "sslocal binary was not found in release package." >&2
        exit 1
    fi

    install -m 0755 "${tmpdir}/sslocal" "${SS_BIN}"
}

write_config() {
    mkdir -p "${SS_DIR}"

    jq -n \
        --arg server "${SS_SERVER}" \
        --argjson server_port "${SS_SERVER_PORT}" \
        --arg local_address "${LOCAL_ADDRESS}" \
        --argjson local_port "${LOCAL_PORT}" \
        --arg password "${SS_PASSWORD}" \
        --arg method "${SS_METHOD}" \
        '{
            server: $server,
            server_port: $server_port,
            local_address: $local_address,
            local_port: $local_port,
            password: $password,
            method: $method,
            mode: "tcp_and_udp"
        }' > "${SS_CONFIG}"
}

write_service() {
    cat > "${SS_SERVICE}" <<EOF
[Unit]
Description=Shadowsocks Local Client (sslocal)
After=network.target

[Service]
Type=simple
ExecStart=${SS_BIN} -c ${SS_CONFIG}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

start_service() {
    systemctl daemon-reload
    systemctl enable --now sslocal.service
}

show_result() {
    local server_display="${SS_SERVER}"
    if [[ "${server_display}" == *:* && "${server_display}" != \[*\] ]]; then
        server_display="[${server_display}]"
    fi

    echo
    echo "sslocal 安装并启动完成"
    echo "本地 SOCKS5 监听: ${LOCAL_ADDRESS}:${LOCAL_PORT}"
    echo "远端服务器: ${server_display}:${SS_SERVER_PORT}"
    echo "加密方式: ${SS_METHOD}"
    echo "配置文件: ${SS_CONFIG}"
    echo "服务管理:"
    echo "  systemctl status sslocal.service"
    echo "  systemctl restart sslocal.service"
}

install_deps
detect_arch
prompt_inputs
install_sslocal
write_config
write_service
start_service
show_result
