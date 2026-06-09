#!/bin/sh
cd "$(dirname "$0")" || exit 1
./lan-share.sh setup
echo
echo "按回车关闭窗口..."
read _
