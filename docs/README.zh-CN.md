# LAN Share Tool 中文说明

LAN Share Tool 是一个面向 macOS 的局域网文件共享和文字交换小工具。它可以把本机文件夹通过浏览器分享给同一网络内的手机、平板或其他电脑，并提供二维码、中文文件名友好的下载页、共享剪切板和可视化控制面板。

## 功能特性

- 局域网浏览器文件下载，无需 SMB/Windows 文件共享
- 支持点击进入子文件夹，下载子文件夹中的文件
- 支持把文件夹打包成 `.zip` 下载
- 本机控制面板：`http://127.0.0.1:7999`
- 自动生成二维码，手机扫码即可打开下载页
- 自带 UTF-8 文件列表，中文文件名完整显示
- 共享剪切板，可在 Mac 和手机之间快速交换文字
- 网页上传：访问链接的用户可以把文件上传到主机共享目录
- 可在界面中设置共享目录、同步来源目录和下载端口
- 支持 macOS LaunchAgent，登录后自动启动共享服务
- 包含 Windows PowerShell 版本，位于 `windows/`
- 不依赖 Homebrew、npm 或第三方包

## 系统要求

- macOS
- 系统自带 Ruby
- 系统自带 Swift 工具链，用于生成二维码

## 快速开始

下载或克隆本仓库后执行：

```sh
cd lan-share-tool
sh lan-share.sh setup
```

打开控制面板：

```sh
ruby app.rb
```

然后在浏览器打开：

```text
http://127.0.0.1:7999
```

控制面板会显示局域网下载地址，例如：

```text
http://192.168.x.x:8000
```

把要共享的文件放进共享目录后，手机或其他设备打开这个地址即可下载。

## 双击启动

macOS 下可以直接双击这些入口：

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

如果 macOS 第一次拦截 `.command` 文件，可以右键文件，选择“打开”，再确认运行。

## 默认配置

默认共享目录：

```text
~/Public/share
```

默认同步来源目录：

```text
~/Desktop/share
```

默认下载端口：

```text
8000
```

持久化配置文件：

```text
~/Library/Application Support/LANShare/config.env
```

共享剪切板内容保存在共享目录里的隐藏文件：

```text
.lan-share-clipboard.txt
```

这个隐藏文件不会显示在下载页文件列表中。

## 常用命令

安装并启动后台共享服务：

```sh
sh lan-share.sh setup
```

查看状态和访问地址：

```sh
sh lan-share.sh status
```

启动：

```sh
sh lan-share.sh start
```

停止：

```sh
sh lan-share.sh stop
```

重启：

```sh
sh lan-share.sh restart
```

把同步来源目录中的文件复制到共享目录：

```sh
sh lan-share.sh sync
```

卸载自动启动服务：

```sh
sh lan-share.sh uninstall
```

## 控制面板

运行：

```sh
ruby app.rb
```

打开：

```text
http://127.0.0.1:7999
```

控制面板支持：

- 启动、停止、重启共享服务
- 同步桌面 `share` 文件夹到共享目录
- 复制或打开局域网下载链接
- 显示二维码，方便手机扫码
- 管理共享剪切板
- 修改共享目录、同步来源目录和下载端口

## 上传文件

局域网下载页包含“上传文件”区域。能打开共享链接的用户可以把文件上传到当前打开的共享文件夹中。

如果文件名已经存在，会自动改名，例如：

```text
name (1).ext
```

这个功能适合可信局域网使用，不建议暴露到公网。

## 下载文件夹

文件列表中的文件夹既可以点击进入，也会显示“下载”链接。点击下载时，工具会临时把该文件夹打包为 `.zip`，然后发送给浏览器。

## 共享剪切板

控制面板和手机访问的下载页都带有共享剪切板。

典型用法：

1. 在 Mac 控制面板的文本框中粘贴文字。
2. 点击 `保存文字`。
3. 手机打开局域网下载页。
4. 点击 `刷新`，再点击 `复制文字`。

反过来也一样：手机保存文字，Mac 端刷新后复制。

## Windows 版本

Windows PowerShell 版本位于：

```text
windows/
```

在 Windows 上双击：

```text
windows/Start-LANShare.bat
```

它提供基础网页功能：文件下载、文件上传和共享剪切板。

## 修改配置

推荐在控制面板的“设置”区域修改共享目录、同步来源目录和下载端口。保存后工具会自动重启共享服务并刷新二维码/访问链接。

也可以临时通过命令行指定端口：

```sh
LAN_SHARE_PORT=8080 sh lan-share.sh restart
```

临时指定共享目录：

```sh
LAN_SHARE_DIR="$HOME/Public/my-files" sh lan-share.sh restart
```

持久配置可以编辑：

```text
~/Library/Application Support/LANShare/config.env
```

## 常见问题

如果其他设备打不开局域网地址：

- 确认两台设备连接的是同一个网络。
- 校园网、酒店 Wi-Fi、公共 Wi-Fi 可能会隔离设备。
- 检查 macOS 防火墙是否阻止了入站连接。
- 尝试在控制面板里换一个下载端口。

如果中文文件名显示乱码：

- 请使用本工具自带的下载页。
- 不要直接使用 `ruby -run -e httpd` 生成的默认目录列表。

如果扫码后打不开：

- 确认手机和 Mac 在同一网络。
- 确认控制面板里的下载地址可以在 Mac 本机打开。
- 如果改过端口，请重新扫码新的二维码。

## 安全说明

本工具适合可信局域网内临时共享。能访问局域网下载地址的人都可以查看/下载共享目录中的文件，也可以使用共享剪切板。

不要把下载端口直接暴露到公网。
