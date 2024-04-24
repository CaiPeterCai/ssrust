#!/bin/bash

# Netplan configuration file path
CONFIG_FILE="/etc/netplan/50-cloud-init.yaml"

# Function to display messages in selected language
function prompt {
    case $1 in
        subnet)
            if [ "$LANGUAGE" == "en" ]; then
                echo "Enter the IPv6 subnet"
            else
                echo "请输入IPv6子网"
            fi
            ;;
        count)
            if [ "$LANGUAGE" == "en" ]; then
                echo "How many IPv6 addresses do you want to generate? "
            else
                echo "您希望生成多少个IPv6地址？"
            fi
            ;;
    esac
}

# Choose language
echo "Choose a language / 选择一种语言:"
echo "1. English"
echo "2. 中文"
read -p "Enter your choice (1 or 2): " lang_choice
if [ "$lang_choice" == "2" ]; then
    LANGUAGE="zh"
else
    LANGUAGE="en"
fi

# Get user input based on language selection
echo -n "$(prompt subnet)"
read subnet
echo -n "$(prompt count)"
read count

# Ensure dhcp4 and dhcp6 settings are correct
sudo sed -i '/dhcp4:/d' $CONFIG_FILE
sudo sed -i '/set-name: enp3s0/a \ \ \ \ \ \ \ \ dhcp4: true' $CONFIG_FILE
sudo sed -i '/dhcp6:/d' $CONFIG_FILE
sudo sed -i '/dhcp4: true/a \ \ \ \ \ \ \ \ dhcp6: false' $CONFIG_FILE

# Ensure the addresses array exists under enp3s0
if ! grep -q "addresses:" $CONFIG_FILE; then
    sudo sed -i '/set-name: enp3s0/a \ \ \ \ \ \ \ \ addresses: []' $CONFIG_FILE
fi

# Generate random IPv6 addresses within the given subnet
addresses=()
for ((i=0; i<count; i++)); do
    # Generate the last 64-bits of the address randomly, assuming a /64 subnet
    part1=$(printf '%x' $(( RANDOM % 65536 )))
    part2=$(printf '%x' $(( RANDOM % 65536 )))
    part3=$(printf '%x' $(( RANDOM % 65536 )))
    part4=$(printf '%x' $(( RANDOM % 65536 )))
    addresses+=("$prefix$part1:$part2:$part3:$part4/64")
done

# Add each address to the configuration file under the correct section
for addr in "${addresses[@]}"
do
    sudo sed -i "/addresses:/a \ \ \ \ \ \ \ \ \ \ \ \ - \"$addr\"" $CONFIG_FILE
done

# Apply the changes
sudo netplan apply

if [ "$LANGUAGE" == "en" ]; then
    echo "IPv6 addresses added and configuration applied."
else
    echo "IPv6地址已添加并且配置已应用。"
fi
