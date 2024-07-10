#!/bin/bash

# 定义可能的配置文件路径
config_paths=(
    "/etc/shadowsocks/config.json"
    "/var/snap/shadowsocks-libev/common/etc/shadowsocks-libev/config.json"
)

# 函数来获取当前机器的IP地址
getIP() {
    read -p "请选择IP类型 (4 或 6): " ip_version
    if [[ "$ip_version" == "4" ]]; then
        curl -s ipv4.ip.sb
    elif [[ "$ip_version" == "6" ]]; then
        curl -s ipv6.ip.sb
    else
        echo "无效选择"
        exit 1
    fi
}

# 查找存在的配置文件路径
for path in "${config_paths[@]}"; do
    if [[ -f "$path" ]]; then
        config_file="$path"
        break
    fi
done

# 检查是否找到配置文件
if [[ -z "$config_file" ]]; then
    echo "配置文件未找到"
    exit 1
fi

# 读取配置文件内容
ssport=$(jq -r '.server_port' "$config_file")
sspasswd=$(jq -r '.password' "$config_file")

# 提示用户输入名字
read -p "请输入名字: " name

# 编码名字
encoded_name=$(echo -n "$name" | jq -sRr @uri)

# 获取当前机器的IP地址
ip_address=$(getIP)

# 生成并返回编码后的字符串
encoded_string=$(echo -n "chacha20-ietf-poly1305:${sspasswd}" | base64 -w 0)
echo "ss://${encoded_string}@${ip_address}:${ssport}#${encoded_name}"