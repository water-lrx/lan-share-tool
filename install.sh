#!/bin/sh
set -eu

cd "$(dirname "$0")"
chmod +x lan-share.sh *.command 2>/dev/null || true
sh lan-share.sh setup

echo
echo "LAN Share Tool is installed."
echo "Run the control panel with:"
echo "  ruby app.rb"
echo
echo "Then open:"
echo "  http://127.0.0.1:7999"
