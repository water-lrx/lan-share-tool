# LAN Share Tool

A small macOS LAN sharing tool for quick file downloads and text exchange across devices on the same network.

It starts a local HTTP download page, shows a QR code in a desktop control panel, keeps Chinese/Unicode file names readable, and includes a shared clipboard for moving text between your Mac and phone.

## Features

- Browser-based file sharing over your local network
- Desktop control panel at `http://127.0.0.1:7999`
- QR code for phones to scan the download page
- UTF-8 file listing for Chinese and other Unicode file names
- Shared text clipboard with save, copy, refresh, and clear actions
- Configurable share directory, sync source directory, and download port
- macOS LaunchAgent support for login auto-start
- No Homebrew or npm dependencies required

## Requirements

- macOS
- Built-in Ruby
- Built-in Swift toolchain for QR generation

The tool uses macOS system components only.

## Quick Start

Clone or download this repository, then run:

```sh
cd lan-share-tool
sh lan-share.sh setup
```

Open the desktop control panel:

```sh
ruby app.rb
```

Then open:

```text
http://127.0.0.1:7999
```

The control panel shows your LAN download URL, usually something like:

```text
http://192.168.x.x:8000
```

Put files in the share directory and open that URL from another device on the same network.

## Double-Click Launchers

On macOS you can also double-click:

```text
Open Control Panel.command
Start Sharing.command
Show Status.command
Stop Sharing.command

打开控制面板.command
启动共享.command
查看状态.command
停止共享.command
```

If macOS blocks a `.command` file the first time, right-click it, choose Open, and confirm.

## Default Paths

Default share directory:

```text
~/Public/share
```

Default sync source directory:

```text
~/Desktop/share
```

Default download port:

```text
8000
```

Persistent settings are stored at:

```text
~/Library/Application Support/LANShare/config.env
```

The shared clipboard is stored as a hidden file in the share directory:

```text
.lan-share-clipboard.txt
```

It is hidden from the file list.

## Commands

Start and install the LaunchAgent:

```sh
sh lan-share.sh setup
```

Show status and access URLs:

```sh
sh lan-share.sh status
```

Start:

```sh
sh lan-share.sh start
```

Stop:

```sh
sh lan-share.sh stop
```

Restart:

```sh
sh lan-share.sh restart
```

Copy files from the sync source directory to the share directory:

```sh
sh lan-share.sh sync
```

Uninstall the LaunchAgent:

```sh
sh lan-share.sh uninstall
```

## Control Panel

Run:

```sh
ruby app.rb
```

Open:

```text
http://127.0.0.1:7999
```

The control panel lets you:

- Start, stop, restart, and sync
- Copy/open the LAN download link
- Scan a QR code from your phone
- Manage the shared clipboard
- Change the share directory, sync source directory, and download port

## Shared Clipboard

Both the desktop control panel and the LAN download page include a shared clipboard.

Typical flow:

1. Paste text into the clipboard box on your Mac.
2. Click `保存文字`.
3. Open the LAN page on your phone.
4. Click `刷新`, then `复制文字`.

The same works in the opposite direction.

## Custom Settings From Shell

Temporary port:

```sh
LAN_SHARE_PORT=8080 sh lan-share.sh restart
```

Temporary share directory:

```sh
LAN_SHARE_DIR="$HOME/Public/my-files" sh lan-share.sh restart
```

For persistent settings, use the control panel or edit:

```text
~/Library/Application Support/LANShare/config.env
```

## Troubleshooting

If another device cannot open the LAN URL:

- Make sure both devices are on the same network.
- Some campus, hotel, and public Wi-Fi networks isolate devices from each other.
- Check whether macOS Firewall is blocking incoming connections.
- Try changing the download port in the control panel.

If Chinese file names look wrong, make sure you are using the built-in LAN Share download page, not a raw `ruby -run -e httpd` directory listing.

## Security Notes

This tool is intended for trusted local networks. Anyone who can reach the LAN URL can view/download files in the share directory and use the shared clipboard.

Do not expose the download port directly to the public internet.
