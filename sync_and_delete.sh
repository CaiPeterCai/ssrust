#!/bin/bash

SOURCE_DIR="/var/packages/qBittorrent/target/qBittorrent_conf/downloads"
DEST_DIR="/volume1/down"

# 同步文件并删除源文件
rsync -av --remove-source-files "$SOURCE_DIR/" "$DEST_DIR/"

# 删除空目录
find "$SOURCE_DIR" -type d -empty -delete

# 检查是否还有剩余文件或目录
if [ -z "$(ls -A "$SOURCE_DIR")" ]; then
    echo "同步完成，所有文件已移动到目标目录。"
else
    echo "警告：源目录中仍有一些项目未能移动。请手动检查。"
fi
