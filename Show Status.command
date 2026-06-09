#!/bin/sh
cd "$(dirname "$0")" || exit 1
sh lan-share.sh status
echo
echo "Press Return to close..."
read _
