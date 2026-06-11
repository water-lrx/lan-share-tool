#!/usr/bin/env ruby
# frozen_string_literal: true

require "cgi"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "timeout"
require "webrick"

ROOT = File.expand_path(__dir__)
SCRIPT = File.join(ROOT, "lan-share.sh")
QR_SCRIPT = File.join(ROOT, "qr.swift")
QR_CACHE = {}
APP_SUPPORT_DIR = File.expand_path("~/Library/Application Support/LANShare")
CONFIG_FILE = File.join(APP_SUPPORT_DIR, "config.env")
APP_PORT = Integer(ENV.fetch("LAN_SHARE_APP_PORT", "7999"))
MAX_CLIPBOARD_BYTES = 64 * 1024

def load_config
  config = {
    "LAN_SHARE_DIR" => ENV.fetch("LAN_SHARE_DIR", File.expand_path("~/Public/share")),
    "LAN_SHARE_SOURCE" => ENV.fetch("LAN_SHARE_SOURCE", File.expand_path("~/Desktop/share")),
    "LAN_SHARE_PORT" => ENV.fetch("LAN_SHARE_PORT", "8000")
  }
  if File.file?(CONFIG_FILE)
    File.readlines(CONFIG_FILE, chomp: true).each do |line|
      next if line.strip.empty? || line.start_with?("#")

      key, value = line.split("=", 2)
      next unless key && value && config.key?(key)

      config[key] = value
    end
  end
  config
end

def share_dir
  File.expand_path(load_config["LAN_SHARE_DIR"])
end

def source_dir
  File.expand_path(load_config["LAN_SHARE_SOURCE"])
end

def share_port
  load_config["LAN_SHARE_PORT"].to_s
end

def clipboard_file
  File.join(share_dir, ".lan-share-clipboard.txt")
end

def utf8_text(value)
  value.to_s.dup.force_encoding("UTF-8").scrub
end

def run_script(command)
  stdout = ""
  stderr = ""
  status = nil
  timed_out = false
  begin
    Timeout.timeout(8) do
      stdout, stderr, status = Open3.capture3("/bin/sh", SCRIPT, command)
    end
  rescue Timeout::Error
    timed_out = true
  end
  output = utf8_text([stdout, stderr].reject(&:empty?).join("\n").strip)
  if timed_out
    running = service_running?
    return {
      ok: running,
      command: command,
      output: running ? "Command is still finishing, but sharing service is running." : "Command timed out before the sharing service responded."
    }
  end
  {
    ok: status&.success?,
    command: command,
    output: output
  }
end

def lan_ips
  %w[en0 en1].map do |iface|
    output, = Open3.capture2("ipconfig", "getifaddr", iface)
    ip = output.strip
    ip.empty? ? nil : ip
  end.compact.uniq
end

def service_running?
  system("curl", "-fsS", "--max-time", "1", "http://127.0.0.1:#{share_port}/",
         out: File::NULL, err: File::NULL)
end

def share_files
  dir = share_dir
  return [] unless Dir.exist?(dir)

  Dir.children(dir).sort.map do |raw_name|
    name = utf8_text(raw_name)
    next if name == ".lan-share-clipboard.txt"

    path = File.join(dir, name)
    stat = File.stat(path)
    {
      name: name,
      directory: stat.directory?,
      size: stat.directory? ? nil : stat.size,
      modified: stat.mtime.strftime("%Y-%m-%d %H:%M")
    }
  rescue Errno::ENOENT
    nil
  end.compact
end

def clipboard_text
  path = clipboard_file
  return "" unless File.file?(path)

  File.binread(path).force_encoding("UTF-8").scrub
end

def save_clipboard_text(text)
  FileUtils.mkdir_p(share_dir)
  text = text.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
  text = text.byteslice(0, MAX_CLIPBOARD_BYTES).to_s.force_encoding("UTF-8").scrub
  File.write(clipboard_file, text)
  text
end

def handle_clipboard(request, response)
  case request.request_method
  when "GET"
    json_response(response, { text: clipboard_text })
  when "POST"
    raw = request.body.to_s.force_encoding("UTF-8")
    data = raw.empty? ? {} : JSON.parse(raw)
    json_response(response, { text: save_clipboard_text(data["text"]) })
  else
    json_response(response, { error: "Method not allowed" }, 405)
  end
rescue JSON::ParserError
  json_response(response, { error: "Invalid JSON" }, 400)
end

def validate_port(value)
  port = Integer(value.to_s, exception: false)
  raise ArgumentError, "端口必须是 1024 到 65535 之间的数字" unless port && port.between?(1024, 65_535)

  port.to_s
end

def write_config(config)
  FileUtils.mkdir_p(APP_SUPPORT_DIR)
  File.write(CONFIG_FILE, <<~CONFIG)
    LAN_SHARE_DIR=#{config["LAN_SHARE_DIR"]}
    LAN_SHARE_SOURCE=#{config["LAN_SHARE_SOURCE"]}
    LAN_SHARE_PORT=#{config["LAN_SHARE_PORT"]}
  CONFIG
end

def handle_settings(request, response)
  if request.request_method == "GET"
    return json_response(response, load_config)
  end

  return json_response(response, { error: "Method not allowed" }, 405) unless request.request_method == "POST"

  data = JSON.parse(request.body.to_s.force_encoding("UTF-8"))
  config = load_config
  config["LAN_SHARE_DIR"] = File.expand_path(data["share_dir"].to_s.strip.empty? ? config["LAN_SHARE_DIR"] : data["share_dir"].to_s.strip)
  config["LAN_SHARE_SOURCE"] = File.expand_path(data["source_dir"].to_s.strip.empty? ? config["LAN_SHARE_SOURCE"] : data["source_dir"].to_s.strip)
  config["LAN_SHARE_PORT"] = validate_port(data["share_port"] || config["LAN_SHARE_PORT"])
  FileUtils.mkdir_p(config["LAN_SHARE_DIR"])
  write_config(config)
  result = run_script("restart")
  json_response(response, { ok: result[:ok], config: config, output: result[:output] })
rescue JSON::ParserError
  json_response(response, { error: "Invalid JSON" }, 400)
rescue ArgumentError => e
  json_response(response, { error: e.message }, 400)
end

def state
  ips = lan_ips
  port = share_port
  {
    running: service_running?,
    share_dir: utf8_text(share_dir),
    source_dir: utf8_text(source_dir),
    share_port: port,
    app_port: APP_PORT,
    urls: ips.map { |ip| "http://#{ip}:#{port}" },
    files: share_files
  }
end

def json_response(response, payload, status = 200)
  response.status = status
  response["Content-Type"] = "application/json; charset=utf-8"
  response.body = JSON.pretty_generate(payload)
end

def qr_png(text)
  return QR_CACHE[text] if QR_CACHE.key?(text)

  png, stderr, status = Open3.capture3("/usr/bin/swift", QR_SCRIPT, text)
  raise "QR generation failed: #{stderr}" unless status.success?

  QR_CACHE[text] = png
end

def html
  <<~HTML
    <!doctype html>
    <html lang="zh-CN">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>LAN Share</title>
      <style>
        :root {
          color-scheme: light;
          --ink: #202124;
          --muted: #5f6368;
          --line: #d8dde6;
          --panel: #ffffff;
          --paper: #f5f7fb;
          --green: #188038;
          --red: #b3261e;
          --blue: #1a73e8;
          --blue-soft: #e8f0fe;
          --amber: #f9ab00;
          font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        }
        * { box-sizing: border-box; }
        body {
          margin: 0;
          background: var(--paper);
          color: var(--ink);
          font-size: 15px;
        }
        .shell {
          max-width: 1120px;
          margin: 0 auto;
          padding: 28px 20px 36px;
        }
        header {
          display: flex;
          align-items: center;
          justify-content: space-between;
          gap: 16px;
          margin-bottom: 18px;
        }
        h1 {
          margin: 0;
          font-size: 28px;
          line-height: 1.15;
          font-weight: 700;
        }
        .sub {
          margin: 6px 0 0;
          color: var(--muted);
        }
        .status {
          display: inline-flex;
          align-items: center;
          gap: 8px;
          border: 1px solid var(--line);
          border-radius: 999px;
          padding: 8px 12px;
          background: var(--panel);
          white-space: nowrap;
        }
        .dot {
          width: 10px;
          height: 10px;
          border-radius: 50%;
          background: var(--red);
        }
        .status.running .dot { background: var(--green); }
        .grid {
          display: grid;
          grid-template-columns: minmax(0, 1fr) 340px;
          gap: 16px;
        }
        .panel {
          background: var(--panel);
          border: 1px solid var(--line);
          border-radius: 8px;
          padding: 16px;
        }
        .panel h2 {
          margin: 0 0 12px;
          font-size: 17px;
          line-height: 1.3;
        }
        .url-row {
          display: grid;
          grid-template-columns: minmax(0, 1fr) auto auto;
          gap: 8px;
          align-items: center;
          margin-bottom: 10px;
        }
        .url {
          overflow: hidden;
          text-overflow: ellipsis;
          white-space: nowrap;
          border: 1px solid var(--line);
          border-radius: 6px;
          padding: 9px 10px;
          background: #fbfcff;
          font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
          font-size: 14px;
        }
        .qr-wrap {
          display: grid;
          grid-template-columns: 190px minmax(0, 1fr);
          gap: 14px;
          align-items: center;
          border: 1px solid var(--line);
          border-radius: 8px;
          padding: 12px;
          background: #fbfcff;
          margin: 4px 0 14px;
        }
        .qr {
          width: 174px;
          height: 174px;
          display: grid;
          place-items: center;
          background: #fff;
          border: 1px solid var(--line);
          border-radius: 6px;
          padding: 10px;
        }
        .qr img {
          width: 100%;
          height: 100%;
          object-fit: contain;
          display: block;
        }
        .qr-note {
          color: var(--muted);
          line-height: 1.5;
        }
        .actions {
          display: grid;
          grid-template-columns: repeat(2, minmax(0, 1fr));
          gap: 10px;
        }
        .clip-panel {
          margin-top: 20px;
        }
        .clip-head {
          display: flex;
          align-items: center;
          justify-content: space-between;
          gap: 12px;
          margin-bottom: 10px;
        }
        .clip-status {
          color: var(--green);
          min-height: 20px;
          font-size: 13px;
        }
        textarea {
          width: 100%;
          min-height: 130px;
          resize: vertical;
          border: 1px solid var(--line);
          border-radius: 6px;
          padding: 10px;
          background: #fbfcff;
          color: var(--ink);
          font: 14px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace;
        }
        .clip-actions {
          display: flex;
          flex-wrap: wrap;
          gap: 8px;
          margin-top: 10px;
        }
        button, .button-link {
          appearance: none;
          border: 1px solid var(--line);
          border-radius: 6px;
          background: #fff;
          color: var(--ink);
          min-height: 38px;
          padding: 8px 12px;
          font: inherit;
          cursor: pointer;
          text-decoration: none;
          display: inline-flex;
          align-items: center;
          justify-content: center;
          gap: 8px;
        }
        button.primary {
          background: var(--blue);
          border-color: var(--blue);
          color: #fff;
        }
        button.danger {
          color: var(--red);
          border-color: #f0c7c2;
        }
        button:disabled {
          opacity: .58;
          cursor: progress;
        }
        .meta {
          display: grid;
          gap: 9px;
        }
        .settings {
          display: grid;
          gap: 10px;
        }
        .settings input {
          width: 100%;
          min-height: 36px;
          border: 1px solid var(--line);
          border-radius: 6px;
          padding: 8px 10px;
          background: #fbfcff;
          color: var(--ink);
          font: 13px ui-monospace, SFMono-Regular, Menlo, monospace;
        }
        .settings .hint {
          color: var(--muted);
          font-size: 12px;
          line-height: 1.45;
        }
        .meta-row {
          display: grid;
          gap: 4px;
        }
        .label {
          color: var(--muted);
          font-size: 12px;
        }
        .path {
          overflow-wrap: anywhere;
          font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
          font-size: 13px;
        }
        table {
          width: 100%;
          border-collapse: collapse;
        }
        th, td {
          border-bottom: 1px solid var(--line);
          padding: 10px 8px;
          text-align: left;
          vertical-align: middle;
        }
        th {
          color: var(--muted);
          font-size: 12px;
          font-weight: 600;
        }
        td.name {
          max-width: 420px;
          overflow-wrap: anywhere;
        }
        .empty {
          color: var(--muted);
          padding: 22px 8px;
        }
        .log {
          min-height: 44px;
          max-height: 150px;
          overflow: auto;
          white-space: pre-wrap;
          border: 1px solid var(--line);
          border-radius: 6px;
          background: #fbfcff;
          padding: 10px;
          color: var(--muted);
          font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
          font-size: 12px;
        }
        .toast {
          position: fixed;
          right: 18px;
          bottom: 18px;
          border: 1px solid var(--line);
          background: var(--panel);
          border-radius: 8px;
          padding: 10px 12px;
          box-shadow: 0 8px 28px rgba(32,33,36,.15);
          opacity: 0;
          transform: translateY(8px);
          transition: .18s ease;
          pointer-events: none;
        }
        .toast.show {
          opacity: 1;
          transform: translateY(0);
        }
        @media (max-width: 820px) {
          header { align-items: flex-start; flex-direction: column; }
          .grid { grid-template-columns: 1fr; }
          .url-row { grid-template-columns: 1fr; }
          .qr-wrap { grid-template-columns: 1fr; }
          .qr { width: min(100%, 220px); height: auto; aspect-ratio: 1; }
          .actions { grid-template-columns: 1fr; }
        }
      </style>
    </head>
    <body>
      <div class="shell">
        <header>
          <div>
            <h1>LAN Share</h1>
            <p class="sub">本地文件夹到局域网浏览器下载</p>
          </div>
          <div id="status" class="status"><span class="dot"></span><span>检查中</span></div>
        </header>

        <div class="grid">
          <main class="panel">
            <h2>访问链接</h2>
            <div id="urls"></div>

            <section class="clip-panel">
              <div class="clip-head">
                <h2 style="margin:0;">共享剪切板</h2>
                <div id="clipStatus" class="clip-status"></div>
              </div>
              <textarea id="clipText" placeholder="电脑端在这里粘贴文字，点保存；手机页面刷新后即可复制。"></textarea>
              <div class="clip-actions">
                <button class="primary" data-clip="save">保存文字</button>
                <button data-clip="copy">复制文字</button>
                <button data-clip="refresh">刷新</button>
                <button data-clip="clear">清空</button>
              </div>
            </section>

            <h2 style="margin-top:20px;">文件</h2>
            <div style="overflow:auto;">
              <table>
                <thead>
                  <tr><th>名称</th><th>大小</th><th>修改时间</th></tr>
                </thead>
                <tbody id="files"></tbody>
              </table>
            </div>
          </main>

          <aside class="panel">
            <h2>控制</h2>
            <div class="actions">
              <button class="primary" data-action="start">启动</button>
              <button data-action="restart">重启</button>
              <button data-action="sync">同步桌面 share</button>
              <button class="danger" data-action="stop">停止</button>
              <button data-action="openShare">打开文件夹</button>
              <button data-action="refresh">刷新</button>
              <button class="danger" data-action="quitPanel">退出控制面板</button>
            </div>

            <h2 style="margin-top:20px;">设置</h2>
            <div class="settings">
              <label>
                <div class="label">共享目录</div>
                <input id="settingShareDir" type="text" autocomplete="off">
              </label>
              <label>
                <div class="label">同步来源</div>
                <input id="settingSourceDir" type="text" autocomplete="off">
              </label>
              <label>
                <div class="label">下载端口</div>
                <input id="settingPort" type="number" min="1024" max="65535" step="1">
              </label>
              <button class="primary" data-setting="save">保存并重启共享</button>
              <div class="hint">修改端口后，手机需要重新扫码或打开新的下载链接。</div>
            </div>

            <h2 style="margin-top:20px;">目录</h2>
            <div class="meta">
              <div class="meta-row">
                <div class="label">控制面板</div>
                <div class="path">仅本机访问 http://127.0.0.1:#{APP_PORT}</div>
              </div>
              <div class="meta-row">
                <div class="label">共享目录</div>
                <div id="shareDir" class="path"></div>
              </div>
              <div class="meta-row">
                <div class="label">同步来源</div>
                <div id="sourceDir" class="path"></div>
              </div>
            </div>

            <h2 style="margin-top:20px;">输出</h2>
            <div id="log" class="log">等待操作</div>
          </aside>
        </div>
      </div>
      <div id="toast" class="toast"></div>

      <script>
        const $ = (id) => document.getElementById(id);
        const buttons = [...document.querySelectorAll("button[data-action]")];
        const clipButtons = [...document.querySelectorAll("button[data-clip]")];
        const settingButtons = [...document.querySelectorAll("button[data-setting]")];
        let current = null;

        function formatSize(bytes) {
          if (bytes === null || bytes === undefined) return "文件夹";
          const units = ["B", "KB", "MB", "GB"];
          let value = bytes;
          let unit = 0;
          while (value >= 1024 && unit < units.length - 1) {
            value /= 1024;
            unit += 1;
          }
          return `${value.toFixed(unit === 0 ? 0 : 1)} ${units[unit]}`;
        }

        function toast(text) {
          $("toast").textContent = text;
          $("toast").classList.add("show");
          setTimeout(() => $("toast").classList.remove("show"), 1600);
        }

        function clipStatus(text) {
          $("clipStatus").textContent = text;
          setTimeout(() => {
            if ($("clipStatus").textContent === text) $("clipStatus").textContent = "";
          }, 1800);
        }

        async function api(path, options = {}) {
          const res = await fetch(path, options);
          if (!res.ok) throw new Error(await res.text());
          return res.json();
        }

        function render(data) {
          current = data;
          const status = $("status");
          status.classList.toggle("running", data.running);
          status.querySelector("span:last-child").textContent = data.running ? "运行中" : "已停止";
          $("shareDir").textContent = data.share_dir;
          $("sourceDir").textContent = data.source_dir;
          $("settingShareDir").value = data.share_dir;
          $("settingSourceDir").value = data.source_dir;
          $("settingPort").value = data.share_port;
          const firstUrl = data.urls[0];

          $("urls").innerHTML = data.urls.length ? `
            <div class="qr-wrap">
              <div class="qr"><img src="/qr.png?url=${encodeURIComponent(firstUrl)}" alt="下载链接二维码"></div>
              <div class="qr-note">手机连接同一网络后，扫码打开共享下载页。二维码对应：<br><span class="path">${firstUrl}</span></div>
            </div>
            ${data.urls.map((url) => `
              <div class="url-row">
                <div class="url">${url}</div>
                <button data-copy="${url}">复制</button>
                <a class="button-link" href="${url}" target="_blank" rel="noreferrer">打开</a>
              </div>
            `).join("")}
          ` : `<div class="empty">没有检测到局域网 IP</div>`;

          $("files").innerHTML = data.files.length ? data.files.map((file) => `
            <tr>
              <td class="name">${file.directory ? "[dir] " : ""}${escapeHtml(file.name)}</td>
              <td>${formatSize(file.size)}</td>
              <td>${file.modified}</td>
            </tr>
          `).join("") : `<tr><td class="empty" colspan="3">共享目录里还没有文件</td></tr>`;

          document.querySelectorAll("[data-copy]").forEach((btn) => {
            btn.addEventListener("click", async () => {
              await navigator.clipboard.writeText(btn.dataset.copy);
              toast("已复制链接");
            });
          });
        }

        function escapeHtml(text) {
          return text.replace(/[&<>"']/g, (char) => ({
            "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#039;"
          })[char]);
        }

        async function refresh() {
          render(await api("/api/state"));
        }

        async function refreshClipboard() {
          const data = await api("/api/clipboard");
          $("clipText").value = data.text || "";
        }

        async function saveClipboard(text) {
          const data = await api("/api/clipboard", {
            method: "POST",
            headers: { "Content-Type": "application/json; charset=utf-8" },
            body: JSON.stringify({ text })
          });
          $("clipText").value = data.text || "";
        }

        async function clipCommand(name) {
          clipButtons.forEach((button) => button.disabled = true);
          try {
            if (name === "save") {
              await saveClipboard($("clipText").value);
              clipStatus("已保存");
            } else if (name === "refresh") {
              await refreshClipboard();
              clipStatus("已刷新");
            } else if (name === "clear") {
              await saveClipboard("");
              clipStatus("已清空");
            } else if (name === "copy") {
              if (navigator.clipboard && window.isSecureContext) {
                await navigator.clipboard.writeText($("clipText").value);
              } else {
                $("clipText").focus();
                $("clipText").select();
                document.execCommand("copy");
              }
              clipStatus("已复制");
            }
          } catch (error) {
            clipStatus("操作失败");
          } finally {
            clipButtons.forEach((button) => button.disabled = false);
          }
        }

        async function saveSettings() {
          settingButtons.forEach((button) => button.disabled = true);
          $("log").textContent = "保存设置并重启共享中...";
          try {
            const data = await api("/api/settings", {
              method: "POST",
              headers: { "Content-Type": "application/json; charset=utf-8" },
              body: JSON.stringify({
                share_dir: $("settingShareDir").value,
                source_dir: $("settingSourceDir").value,
                share_port: $("settingPort").value
              })
            });
            $("log").textContent = data.output || "设置已保存";
            toast(data.ok ? "设置已保存" : "保存失败");
            await refresh();
            await refreshClipboard();
          } catch (error) {
            $("log").textContent = error.message;
            toast("保存失败");
          } finally {
            settingButtons.forEach((button) => button.disabled = false);
          }
        }

        async function command(name) {
          buttons.forEach((button) => button.disabled = true);
          $("log").textContent = "执行中...";
          try {
            const data = await api(`/api/${name}`, { method: "POST" });
            $("log").textContent = data.output || "完成";
            toast(data.ok ? "完成" : "执行失败");
            if (name === "quitPanel") {
              document.body.innerHTML = '<div class="shell"><main class="panel"><h1>LAN Share 控制面板已退出</h1><p class="sub">文件共享服务不受影响。需要再次管理时，重新双击桌面的“文件共享.app”。</p></main></div>';
              return;
            }
            await refresh();
          } catch (error) {
            $("log").textContent = error.message;
            toast("执行失败");
          } finally {
            buttons.forEach((button) => button.disabled = false);
          }
        }

        document.addEventListener("click", (event) => {
          const action = event.target.closest("button[data-action]")?.dataset.action;
          const clip = event.target.closest("button[data-clip]")?.dataset.clip;
          const setting = event.target.closest("button[data-setting]")?.dataset.setting;
          if (setting === "save") {
            saveSettings();
            return;
          }
          if (clip) {
            clipCommand(clip);
            return;
          }
          if (action) {
            if (action === "refresh") refresh();
            else command(action);
          }
        });

        refresh();
        refreshClipboard();
        setInterval(refresh, 5000);
      </script>
    </body>
    </html>
  HTML
end

server = WEBrick::HTTPServer.new(
  BindAddress: "127.0.0.1",
  Port: APP_PORT,
  AccessLog: [],
  Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN)
)

server.mount_proc("/api/state") do |_request, response|
  json_response(response, state)
end

server.mount_proc("/api/clipboard") do |request, response|
  handle_clipboard(request, response)
end

server.mount_proc("/api/settings") do |request, response|
  handle_settings(request, response)
end

server.mount_proc("/qr.png") do |request, response|
  url = request.query["url"].to_s
  if url.empty?
    response.status = 400
    response["Content-Type"] = "text/plain; charset=utf-8"
    response.body = "missing url"
  else
    response["Content-Type"] = "image/png"
    response["Cache-Control"] = "public, max-age=300"
    response.body = qr_png(url)
  end
rescue StandardError => e
  response.status = 500
  response["Content-Type"] = "text/plain; charset=utf-8"
  response.body = e.message
end

%w[start stop restart sync].each do |command|
  server.mount_proc("/api/#{command}") do |request, response|
    next json_response(response, { ok: false, output: "Method not allowed" }, 405) unless request.request_method == "POST"

    result = run_script(command)
    json_response(response, result)
  end
end

server.mount_proc("/api/openShare") do |request, response|
  next json_response(response, { ok: false, output: "Method not allowed" }, 405) unless request.request_method == "POST"

  dir = share_dir
  FileUtils.mkdir_p(dir)
  system("open", dir)
  json_response(response, { ok: true, output: "Opened #{dir}" })
end

server.mount_proc("/api/quitPanel") do |request, response|
  next json_response(response, { ok: false, output: "Method not allowed" }, 405) unless request.request_method == "POST"

  json_response(response, { ok: true, output: "Control panel is shutting down. File sharing remains available." })
  Thread.new do
    sleep 0.2
    server.shutdown
  end
end

server.mount_proc("/") do |request, response|
  if request.path == "/"
    response["Content-Type"] = "text/html; charset=utf-8"
    response.body = html
  else
    response.status = 404
    response["Content-Type"] = "text/plain; charset=utf-8"
    response.body = "Not found"
  end
end

trap("INT") { server.shutdown }
trap("TERM") { server.shutdown }

puts "LAN Share UI: http://127.0.0.1:#{APP_PORT}"
server.start
