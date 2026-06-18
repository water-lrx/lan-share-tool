# LAN Share Tool for Windows

This is the Windows PowerShell version of LAN Share Tool.

## Requirements

- Windows 10 or Windows 11
- Built-in Windows PowerShell

No installation is required.

## Start

Double-click:

```text
Start-LANShare.bat
```

The browser opens automatically. Other devices on the same network can open the LAN URL shown in the terminal.

Default share directory:

```text
%USERPROFILE%\LANShare
```

Default port:

```text
8000
```

## Upload Files

The web page has an Upload Files section. Anyone who can open the LAN URL can upload files into the currently opened share folder.

Folders can be opened from the file list, so files inside subfolders can also be downloaded.

If an uploaded filename already exists, the script automatically saves it as:

```text
name (1).ext
name (2).ext
```

## Shared Clipboard

The page also includes a shared clipboard for moving text between the host PC and other devices.

## Custom Port or Folder

From PowerShell:

```powershell
.\LANShare.ps1 -Port 8080 -ShareDir "$env:USERPROFILE\Desktop\share"
```

## Firewall

If other devices cannot open the URL, Windows Firewall may ask for permission the first time. Allow access on private networks.

If the script says it cannot listen on the port, try running it once as Administrator or choose another port.
