#!/bin/bash

# 函数：安装 jq
install_jq() {
    echo "jq 未安装。尝试安装 jq..."
    if grep -qs "ubuntu\|debian" /etc/os-release; then
        sudo apt install jq -y
    elif grep -qs "rhel\|centos\|fedora" /etc/os-release; then
        sudo yum install jq -y
    else
        echo "不支持的操作系统。请手动安装 jq。"
        exit 1
    fi
}

# 函数：检查 jq 是否已安装
check_jq_installed() {
    if ! command -v jq &> /dev/null
    then
        install_jq
    fi
    # 再次检查 jq 是否安装成功
    if ! command -v jq &> /dev/null
    then
        echo "jq 安装失败。请手动安装后重试。"
        exit 1
    fi
}

# 函数：获取配置文件路径
get_config_file() {
    local config_file="/var/snap/shadowsocks-libev/common/etc/shadowsocks-libev/config.json"
    if [ ! -f "$config_file" ]; then
        config_file="/etc/shadowsocks/config.json"
        if [ ! -f "$config_file" ]; then
            echo "未找到配置文件。"
            exit 1
        fi
    fi
    echo $config_file
}

# 函数：提取端口号
get_port() {
    local config_file=$1
    jq '.server_port' "$config_file"
}

# 函数：查询 IP 信息
query_ip_info() {
    local port=$1
    netstat -anp | grep ":$port" | grep 'ESTABLISHED' | awk '{print $5}' | cut -d: -f1 | sort | uniq | while read ip
    do
        curl "http://cip.cc/${ip}"
    done
}

# 主逻辑
main() {
    check_jq_installed
    local config_file=$(get_config_file)
    local port=$(get_port "$config_file")
    echo "使用端口号: $port"
    query_ip_info "$port"
}

# 执行主函数
main
