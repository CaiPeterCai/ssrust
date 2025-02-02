#!/bin/bash

# 定义可能的配置文件路径
config_files=(
    "/etc/shadowsocks/config.json"
    "/var/snap/shadowsocks-libev/common/etc/shadowsocks-libev/config.json"
)

# 获取指定版本的IP地址
getIP(){
    local ip_version=$1
    local serverIP=
    
    if [[ "$ip_version" == "4" ]]; then
        serverIP=$(curl -s -4 http://www.cloudflare.com/cdn-cgi/trace | grep "ip" | awk -F "[=]" '{print $2}')
        if [[ -z "${serverIP}" ]]; then
            echo "Error: 无法获取 IPv4 地址"
            exit 1
        fi
    elif [[ "$ip_version" == "6" ]]; then
        serverIP=$(curl -s -6 http://www.cloudflare.com/cdn-cgi/trace | grep "ip" | awk -F "[=]" '{print $2}')
        if [[ -z "${serverIP}" ]]; then
            echo "Error: 无法获取 IPv6 地址"
            exit 1
        fi
    else
        echo "Error: 无效的 IP 版本选择"
        exit 1
    fi
    
    echo "${serverIP}"
}

# 检查是否安装了jq
if ! command -v jq &> /dev/null; then
    echo "jq is not installed. Installing..."
    if [ -f "/usr/bin/apt" ]; then
        sudo apt update && sudo apt install -y jq
    elif [ -f "/usr/bin/yum" ]; then
        sudo yum install -y jq
    else
        echo "Error: Package manager not found. Please install jq manually."
        exit 1
    fi
fi

# 查找所有可用的配置文件
available_configs=()
for file in "${config_files[@]}"; do
    if [ -f "$file" ]; then
        available_configs+=("$file")
    fi
done

# 检查是否找到配置文件
if [ ${#available_configs[@]} -eq 0 ]; then
    echo "Error: 未找到任何 shadowsocks 配置文件!"
    exit 1
fi

# 如果找到多个配置文件，让用户选择
config_file=""
if [ ${#available_configs[@]} -gt 1 ]; then
    echo "找到多个配置文件:"
    for i in "${!available_configs[@]}"; do
        echo "$((i+1)). ${available_configs[$i]}"
    done
    
    while true; do
        read -p "请选择要使用的配置文件 (1-${#available_configs[@]}): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#available_configs[@]}" ]; then
            config_file="${available_configs[$((choice-1))]}"
            break
        else
            echo "无效的选择，请重试"
        fi
    done
else
    config_file="${available_configs[0]}"
fi

echo "使用配置文件: $config_file"

# 验证配置文件的有效性
if ! jq empty "$config_file" 2>/dev/null; then
    echo "Error: 配置文件格式无效!"
    exit 1
fi

# 读取配置文件
server_port=$(jq -r '.server_port' "$config_file")
password=$(jq -r '.password' "$config_file")
method=$(jq -r '.method' "$config_file")

# 选择IP版本
while true; do
    echo
    echo "请选择 IP 版本:"
    echo "1. IPv4"
    echo "2. IPv6"
    read -p "请输入选项 (1 或 2): " ip_choice
    
    case $ip_choice in
        1)
            server_ip=$(getIP 4)
            break
            ;;
        2)
            server_ip=$(getIP 6)
            break
            ;;
        *)
            echo "无效选项，请重新选择"
            ;;
    esac
done

# 生成ss链接
raw_link="${method}:${password}@${server_ip}:${server_port}"
ss_link="ss://$(echo -n "$raw_link" | base64 -w 0)"

# 输出配置信息
echo
echo "===========Shadowsocks配置参数============"
echo "地址：${server_ip}"
echo "端口：${server_port}"
echo "密码：${password}"
echo "加密方式：${method}"
echo "========================================="
echo "SS链接："
echo "${ss_link}"
echo
