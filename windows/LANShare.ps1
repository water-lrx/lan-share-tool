param(
  [int]$Port = 8000,
  [string]$ShareDir = "$env:USERPROFILE\LANShare",
  [string]$Bind = "+"
)

$ErrorActionPreference = "Stop"

function Ensure-Directory($Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path | Out-Null
  }
}

function HtmlEncode($Text) {
  return [System.Net.WebUtility]::HtmlEncode([string]$Text)
}

function UrlEncode($Text) {
  return [System.Net.WebUtility]::UrlEncode([string]$Text)
}

function UrlDecode($Text) {
  return [System.Net.WebUtility]::UrlDecode([string]$Text)
}

function Get-SafeRelativePath($Path) {
  $text = ([string]$Path).Replace("\", "/")
  $parts = @()
  foreach ($part in $text.Split("/")) {
    if ([string]::IsNullOrWhiteSpace($part) -or $part -eq "." -or $part -eq "..") { continue }
    $parts += $part
  }
  return ($parts -join [System.IO.Path]::DirectorySeparatorChar)
}

function Get-SharePath($RelativePath) {
  $relative = Get-SafeRelativePath $RelativePath
  $root = [System.IO.Path]::GetFullPath($ShareDir)
  $path = if ([string]::IsNullOrWhiteSpace($relative)) {
    $root
  } else {
    [System.IO.Path]::GetFullPath((Join-Path $root $relative))
  }
  if ($path -ne $root -and -not $path.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $null
  }
  return $path
}

function Join-UrlPath($Base, $Name) {
  if ([string]::IsNullOrWhiteSpace($Base)) { return $Name }
  return "$Base/$Name"
}

function Write-Response($Context, [int]$Status, [string]$ContentType, [byte[]]$Bytes) {
  $Context.Response.StatusCode = $Status
  $Context.Response.ContentType = $ContentType
  $Context.Response.ContentLength64 = $Bytes.Length
  $Context.Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
  $Context.Response.OutputStream.Close()
}

function Write-Text($Context, [int]$Status, [string]$ContentType, [string]$Text) {
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
  Write-Response $Context $Status $ContentType $bytes
}

function Get-LocalIPv4 {
  $addresses = @()
  try {
    $addresses = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
      Where-Object { $_.OperationalStatus -eq "Up" -and $_.NetworkInterfaceType -ne "Loopback" } |
      ForEach-Object { $_.GetIPProperties().UnicastAddresses } |
      Where-Object { $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
      ForEach-Object { $_.Address.IPAddressToString } |
      Select-Object -Unique
  } catch {}
  return @($addresses)
}

function Format-Size([long]$Bytes) {
  if ($Bytes -lt 1KB) { return "$Bytes B" }
  if ($Bytes -lt 1MB) { return ("{0:N1} KB" -f ($Bytes / 1KB)) }
  if ($Bytes -lt 1GB) { return ("{0:N1} MB" -f ($Bytes / 1MB)) }
  return ("{0:N1} GB" -f ($Bytes / 1GB))
}

function Get-SafeFileName($Name) {
  $fileName = [System.IO.Path]::GetFileName($Name)
  foreach ($char in [System.IO.Path]::GetInvalidFileNameChars()) {
    $fileName = $fileName.Replace($char, "_")
  }
  if ([string]::IsNullOrWhiteSpace($fileName)) {
    $fileName = "upload.bin"
  }
  return $fileName
}

function Get-UniquePath($Directory, $FileName) {
  $base = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
  $ext = [System.IO.Path]::GetExtension($FileName)
  $candidate = Join-Path $Directory $FileName
  $index = 1
  while (Test-Path -LiteralPath $candidate) {
    $candidate = Join-Path $Directory ("{0} ({1}){2}" -f $base, $index, $ext)
    $index += 1
  }
  return $candidate
}

function Get-ClipboardPath {
  return Join-Path $ShareDir ".lan-share-clipboard.txt"
}

function Get-ClipboardText {
  $path = Get-ClipboardPath
  if (Test-Path -LiteralPath $path) {
    return [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
  }
  return ""
}

function Set-ClipboardText($Text) {
  [System.IO.File]::WriteAllText((Get-ClipboardPath), [string]$Text, [System.Text.Encoding]::UTF8)
}

function Get-IndexHtml($CurrentPath) {
  $current = (Get-SafeRelativePath $CurrentPath).Replace("\", "/")
  $currentDir = Get-SharePath $current
  $ips = Get-LocalIPv4
  $urls = if ($ips.Count -gt 0) {
    ($ips | ForEach-Object { "<code>http://$($_):$Port</code>" }) -join "<br>"
  } else {
    "<span class='muted'>No LAN IPv4 address detected.</span>"
  }

  $rows = ""
  if ($currentDir -and (Test-Path -LiteralPath $currentDir -PathType Container)) {
    Get-ChildItem -LiteralPath $currentDir -Force | Where-Object { $_.Name -ne ".lan-share-clipboard.txt" } | Sort-Object Name | ForEach-Object {
      $name = HtmlEncode $_.Name
      $relative = (Join-UrlPath $current $_.Name)
      $href = if ($_.PSIsContainer) { "/?path=$(UrlEncode $relative)" } else { "/download?name=$(UrlEncode $relative)" }
      $prefix = if ($_.PSIsContainer) { "[dir] " } else { "" }
      $size = if ($_.PSIsContainer) { "Folder" } else { Format-Size $_.Length }
      $modified = $_.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
      $rows += "<tr><td class='name'><a href='$href'>$prefix$name</a></td><td>$size</td><td>$modified</td></tr>"
    }
  }
  if ([string]::IsNullOrWhiteSpace($rows)) {
    $message = if ($currentDir -and (Test-Path -LiteralPath $currentDir -PathType Container)) { "No files yet." } else { "Folder not found." }
    $rows = "<tr><td colspan='3' class='empty'>$message</td></tr>"
  }

  $clip = HtmlEncode (Get-ClipboardText)
  $displayPath = if ([string]::IsNullOrWhiteSpace($current)) { $ShareDir } else { Join-Path $ShareDir $current }
  $dir = HtmlEncode $displayPath
  $parentPath = ""
  $back = ""
  if (-not [string]::IsNullOrWhiteSpace($current)) {
    $parentPath = Split-Path $current -Parent
    $parentPath = $parentPath.Replace("\", "/")
    $back = "<a class='back' href='/?path=$(UrlEncode $parentPath)'>Back to parent folder</a>"
  }
  $currentJson = $current | ConvertTo-Json -Compress

  return @"
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>LAN Share for Windows</title>
  <style>
    body { margin:0; background:#f5f7fb; color:#202124; font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }
    main { max-width:960px; margin:0 auto; padding:24px 16px 36px; }
    h1 { margin:0 0 4px; font-size:26px; }
    h2 { margin:0 0 12px; font-size:18px; }
    .muted,.path { color:#5f6368; }
    .path { overflow-wrap:anywhere; font-family:ui-monospace,Consolas,monospace; font-size:13px; }
    .panel { background:#fff; border:1px solid #d8dde6; border-radius:8px; padding:16px; margin-top:16px; }
    .back { display:inline-flex; align-items:center; min-height:32px; margin-top:8px; font-size:14px; }
    .links code { font-family:ui-monospace,Consolas,monospace; }
    textarea { width:100%; min-height:116px; resize:vertical; border:1px solid #d8dde6; border-radius:6px; padding:10px; font:14px/1.5 Consolas,monospace; box-sizing:border-box; }
    button,input[type=file]::file-selector-button { border:1px solid #d8dde6; border-radius:6px; background:#fff; color:#202124; min-height:38px; padding:8px 12px; font:inherit; cursor:pointer; }
    button.primary,input[type=file]::file-selector-button { background:#1a73e8; border-color:#1a73e8; color:#fff; }
    .actions { display:flex; flex-wrap:wrap; gap:8px; margin-top:10px; }
    table { width:100%; border-collapse:collapse; }
    th,td { padding:10px 8px; border-bottom:1px solid #d8dde6; text-align:left; vertical-align:top; }
    th { color:#5f6368; font-size:12px; }
    .name { overflow-wrap:anywhere; }
    .empty { color:#5f6368; text-align:center; padding:24px; }
    a { color:#1a73e8; text-decoration:none; }
    a:hover { text-decoration:underline; }
    @media (max-width:640px) { th:nth-child(2),td:nth-child(2){display:none;} }
  </style>
</head>
<body>
<main>
  <h1>LAN Share for Windows</h1>
  <div class="path">$dir</div>
  $back
  <section class="panel links">
    <h2>Access URL</h2>
    $urls
  </section>
  <section class="panel">
    <h2>Shared Clipboard</h2>
    <textarea id="clip" placeholder="Paste text here, save it, then copy it from another device.">$clip</textarea>
    <div class="actions">
      <button class="primary" onclick="saveClip()">Save Text</button>
      <button onclick="copyClip()">Copy Text</button>
      <button onclick="refreshClip()">Refresh</button>
      <button onclick="clearClip()">Clear</button>
      <span id="clipStatus" class="muted"></span>
    </div>
  </section>
  <section class="panel">
    <h2>Upload Files</h2>
    <input id="files" type="file" multiple>
    <div class="actions">
      <button class="primary" onclick="uploadFiles()">Upload to Share Folder</button>
      <span id="uploadStatus" class="muted"></span>
    </div>
  </section>
  <section class="panel">
    <h2>Files</h2>
    <table>
      <thead><tr><th>Name</th><th>Size</th><th>Modified</th></tr></thead>
      <tbody>$rows</tbody>
    </table>
  </section>
</main>
<script>
async function api(path, options) {
  const res = await fetch(path, options || {});
  if (!res.ok) throw new Error(await res.text());
  return res.json();
}
function setText(id, text) { document.getElementById(id).textContent = text; }
async function refreshClip() {
  const data = await api('/api/clipboard');
  document.getElementById('clip').value = data.text || '';
  setText('clipStatus', 'Refreshed');
}
async function saveClip() {
  const text = document.getElementById('clip').value;
  await api('/api/clipboard', { method:'POST', headers:{'Content-Type':'application/json; charset=utf-8'}, body:JSON.stringify({text}) });
  setText('clipStatus', 'Saved');
}
async function clearClip() {
  document.getElementById('clip').value = '';
  await saveClip();
  setText('clipStatus', 'Cleared');
}
async function copyClip() {
  const box = document.getElementById('clip');
  if (navigator.clipboard && window.isSecureContext) await navigator.clipboard.writeText(box.value);
  else { box.focus(); box.select(); document.execCommand('copy'); }
  setText('clipStatus', 'Copied');
}
async function uploadFiles() {
  const input = document.getElementById('files');
  if (!input.files.length) { setText('uploadStatus', 'Choose files first'); return; }
  const form = new FormData();
  for (const file of input.files) form.append('files', file, file.name);
  setText('uploadStatus', 'Uploading...');
  const data = await api('/upload?path=' + encodeURIComponent($currentJson), { method:'POST', body:form });
  setText('uploadStatus', 'Uploaded ' + data.files.length + ' file(s). Refreshing...');
  setTimeout(() => location.reload(), 700);
}
</script>
</body>
</html>
"@
}

function Send-Download($Context) {
  $name = UrlDecode $Context.Request.QueryString["name"]
  $path = Get-SharePath $name
  if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
    Write-Text $Context 404 "text/plain; charset=utf-8" "Not found"
    return
  }
  $bytes = [System.IO.File]::ReadAllBytes($path)
  $fileName = [System.IO.Path]::GetFileName($path)
  $Context.Response.ContentType = "application/octet-stream"
  $Context.Response.Headers["Content-Disposition"] = "attachment; filename*=UTF-8''$(UrlEncode $fileName)"
  Write-Response $Context 200 "application/octet-stream" $bytes
}

function Read-MultipartUpload($Context) {
  $uploadDir = Get-SharePath (UrlDecode $Context.Request.QueryString["path"])
  if (-not $uploadDir -or -not (Test-Path -LiteralPath $uploadDir -PathType Container)) {
    Write-Text $Context 404 "text/plain; charset=utf-8" "Upload folder not found"
    return
  }

  $contentType = $Context.Request.ContentType
  if ($contentType -notmatch "boundary=(.+)$") {
    Write-Text $Context 400 "text/plain; charset=utf-8" "Missing multipart boundary"
    return
  }
  $boundary = "--" + $Matches[1].Trim('"')
  $reader = New-Object System.IO.StreamReader($Context.Request.InputStream, [System.Text.Encoding]::GetEncoding("ISO-8859-1"))
  $body = $reader.ReadToEnd()
  $parts = $body -split [regex]::Escape($boundary)
  $saved = @()
  foreach ($part in $parts) {
    if ($part -notmatch 'filename="([^"]*)"') { continue }
    $rawName = $Matches[1]
    if ([string]::IsNullOrWhiteSpace($rawName)) { continue }
    $headerEnd = $part.IndexOf("`r`n`r`n")
    if ($headerEnd -lt 0) { continue }
    $content = $part.Substring($headerEnd + 4)
    $content = $content -replace "`r`n--$",""
    if ($content.EndsWith("`r`n")) { $content = $content.Substring(0, $content.Length - 2) }
    $fileName = Get-SafeFileName ([System.Text.Encoding]::UTF8.GetString([System.Text.Encoding]::GetEncoding("ISO-8859-1").GetBytes($rawName)))
    $path = Get-UniquePath $uploadDir $fileName
    $bytes = [System.Text.Encoding]::GetEncoding("ISO-8859-1").GetBytes($content)
    [System.IO.File]::WriteAllBytes($path, $bytes)
    $saved += [System.IO.Path]::GetFileName($path)
  }
  $json = @{ files = $saved } | ConvertTo-Json -Depth 3
  Write-Text $Context 200 "application/json; charset=utf-8" $json
}

function Handle-Clipboard($Context) {
  if ($Context.Request.HttpMethod -eq "GET") {
    $json = @{ text = (Get-ClipboardText) } | ConvertTo-Json -Depth 3
    Write-Text $Context 200 "application/json; charset=utf-8" $json
    return
  }
  if ($Context.Request.HttpMethod -eq "POST") {
    $reader = New-Object System.IO.StreamReader($Context.Request.InputStream, [System.Text.Encoding]::UTF8)
    $data = $reader.ReadToEnd() | ConvertFrom-Json
    Set-ClipboardText $data.text
    $json = @{ text = (Get-ClipboardText) } | ConvertTo-Json -Depth 3
    Write-Text $Context 200 "application/json; charset=utf-8" $json
    return
  }
  Write-Text $Context 405 "text/plain; charset=utf-8" "Method not allowed"
}

Ensure-Directory $ShareDir

$prefix = "http://$Bind`:$Port/"
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($prefix)

try {
  $listener.Start()
} catch {
  Write-Host "Failed to listen on $prefix"
  Write-Host "Try running this script as Administrator once, or use a different port."
  throw
}

Write-Host "LAN Share for Windows"
Write-Host "Share directory: $ShareDir"
Write-Host "Local URL: http://127.0.0.1:$Port"
foreach ($ip in Get-LocalIPv4) { Write-Host "LAN URL: http://$ip`:$Port" }
Start-Process "http://127.0.0.1:$Port"

try {
  while ($listener.IsListening) {
    $context = $listener.GetContext()
    try {
      $path = $context.Request.Url.AbsolutePath
      if ($path -eq "/") {
        Write-Text $context 200 "text/html; charset=utf-8" (Get-IndexHtml (UrlDecode $context.Request.QueryString["path"]))
      } elseif ($path -eq "/download") {
        Send-Download $context
      } elseif ($path -eq "/upload" -and $context.Request.HttpMethod -eq "POST") {
        Read-MultipartUpload $context
      } elseif ($path -eq "/api/clipboard") {
        Handle-Clipboard $context
      } else {
        Write-Text $context 404 "text/plain; charset=utf-8" "Not found"
      }
    } catch {
      Write-Text $context 500 "text/plain; charset=utf-8" $_.Exception.Message
    }
  }
} finally {
  $listener.Stop()
}
