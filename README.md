
搭建 Shadowsocks-libev， V2ray+ Nginx + WebSocket 和 Reality 代理脚本，支持 Debian、Ubuntu、Centos，并支持甲骨文ARM平台。

简单点讲，没域名的用户可以安装 Reality 和 ws 代理，有域名的可以安装 V2ray+ Nginx + WebSocket 代理，各取所需。

运行脚本：

```
bash <(curl -L -s https://raw.githubusercontent.com/CaiPeterCai/ssrust/main/ss-rust.sh)
```
```
bash <(curl -L -s https://raw.githubusercontent.com/CaiPeterCai/ssrust/refs/heads/main/IPv6_Check_Ver2.sh)
```
```
bash <(curl -L -s https://raw.githubusercontent.com/CaiPeterCai/ssrust/refs/heads/main/ss-link-generator.sh)
```
```
bash <(curl -L -s https://raw.githubusercontent.com/CaiPeterCai/ssrust/main/sslink.sh)
```

```
bash <(curl -L -s https://raw.githubusercontent.com/CaiPeterCai/ssrust/main/hy2.sh)
```
```
bash <(curl -L -s https://raw.githubusercontent.com/CaiPeterCai/ssrust/main/query_ips.sh)
```
```
bash <(curl -L -s https://raw.githubusercontent.com/getsomecat/Snell/master/snell_test.sh)
```
已测试系统如下：

Debian 9, 10, 11

Ubuntu 16.04, 18.04, 20.04

CentOS 7

WSS客户端配置信息保存在：
`cat /usr/local/etc/v2ray/client.json`

Shadowsocks客户端配置信息：
`cat /etc/shadowsocks-libev/config.json`

Reality客户端配置信息保存在：
`cat /usr/local/etc/xray/reclient.json`

卸载方法如下：
https://1024.day/d/1296

**提醒：连不上的朋友，建议先检查一下服务器自带防火墙有没有关闭？**
