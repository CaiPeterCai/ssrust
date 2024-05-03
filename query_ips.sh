#!/bin/bash
echo "请输入端口号:"
read port
netstat -anp | grep ":$port" | grep 'ESTABLISHED' | awk '{print $5}' | cut -d: -f1 | sort | uniq | while read ip
do
    curl "http://cip.cc/${ip}"
done