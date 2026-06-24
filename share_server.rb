#!/usr/bin/env ruby
# frozen_string_literal: true

require "cgi"
require "fileutils"
require "json"
require "tempfile"
require "time"
require "uri"
require "webrick"

SHARE_DIR = ENV.fetch("LAN_SHARE_DIR", File.expand_path("~/Public/share"))
PORT = Integer(ENV.fetch("LAN_SHARE_PORT", "8000"))
CLIPBOARD_FILE = File.join(SHARE_DIR, ".lan-share-clipboard.txt")
MAX_CLIPBOARD_BYTES = 64 * 1024

def safe_relative_path(raw_path)
  path = raw_path.to_s.force_encoding("UTF-8").scrub
  path = path.tr("\\", "/")
  parts = path.split("/").reject { |part| part.empty? || part == "." || part == ".." }
  parts.join("/")
end

def safe_path(relative_path)
  relative = safe_relative_path(relative_path)
  root = File.expand_path(SHARE_DIR)
  path = File.expand_path(File.join(root, relative))
  return nil unless path == root || path.start_with?(root + File::SEPARATOR)

  path
end

def query_param(request, key)
  pair = URI.decode_www_form(request.query_string.to_s).find { |name, _value| name == key }
  pair && pair[1]
end

def file_rows(current_path = "")
  return [] unless Dir.exist?(SHARE_DIR)

  directory = safe_path(current_path)
  return [] unless directory && File.directory?(directory)

  current = safe_relative_path(current_path)
  Dir.children(directory).sort.map do |raw_name|
    name = raw_name.dup.force_encoding("UTF-8")
    next if name == ".lan-share-clipboard.txt"

    relative = [current, name].reject(&:empty?).join("/")
    path = File.join(directory, name)
    stat = File.stat(path)
    next if name == "." || name == ".."

    {
      name: name,
      href: stat.directory? ? "/?path=#{URI.encode_www_form_component(relative)}" : "/download/#{URI.encode_www_form_component(relative)}",
      folder_download_href: stat.directory? ? "/download-folder/#{URI.encode_www_form_component(relative)}" : nil,
      directory: stat.directory?,
      size: stat.directory? ? "-" : format_size(stat.size),
      modified: stat.mtime.strftime("%Y-%m-%d %H:%M")
    }
  rescue Errno::ENOENT
    nil
  end.compact
end

def clipboard_text
  return "" unless File.file?(CLIPBOARD_FILE)

  File.binread(CLIPBOARD_FILE).force_encoding("UTF-8").scrub
end

def save_clipboard_text(text)
  text = text.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
  text = text.byteslice(0, MAX_CLIPBOARD_BYTES).to_s.force_encoding("UTF-8").scrub
  File.write(CLIPBOARD_FILE, text)
  text
end

def json_response(response, payload, status = 200)
  response.status = status
  response["Content-Type"] = "application/json; charset=utf-8"
  response.body = payload.to_json
end

def format_size(bytes)
  units = %w[B KB MB GB]
  value = bytes.to_f
  unit = 0
  while value >= 1024 && unit < units.length - 1
    value /= 1024
    unit += 1
  end
  unit.zero? ? "#{value.to_i} #{units[unit]}" : format("%.1f %s", value, units[unit])
end

def page_html(current_path = "")
  current = safe_relative_path(current_path)
  current_dir = safe_path(current)
  rows = file_rows(current)
  display_path = [SHARE_DIR, current].reject(&:empty?).join("/")
  parent = File.dirname(current)
  parent = "" if parent == "."
  nav = current.empty? ? "" : "<a class=\"back\" href=\"/?path=#{URI.encode_www_form_component(parent)}\">返回上一级</a>"
  list = if rows.empty?
           message = current_dir && File.directory?(current_dir) ? "这个文件夹里还没有文件" : "文件夹不存在"
           "<tr><td colspan=\"3\" class=\"empty\">#{message}</td></tr>"
         else
           rows.map do |file|
             name = CGI.escapeHTML(file[:name])
             prefix = file[:directory] ? "[dir] " : ""
             action = file[:folder_download_href] ? " <a class=\"folder-download\" href=\"#{file[:folder_download_href]}\">下载</a>" : ""
             "<tr><td class=\"name\"><a href=\"#{file[:href]}\">#{prefix}#{name}</a>#{action}</td><td>#{file[:size]}</td><td>#{file[:modified]}</td></tr>"
           end.join
         end

  <<~HTML
    <!doctype html>
    <html lang="zh-CN">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>LAN Share Files</title>
      <style>
        body { margin: 0; background: #f5f7fb; color: #202124; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
        main { max-width: 900px; margin: 0 auto; padding: 24px 16px 36px; }
        header { display: flex; justify-content: space-between; gap: 12px; align-items: flex-end; margin-bottom: 16px; }
        h1 { margin: 0; font-size: 24px; }
        .path { color: #5f6368; font-size: 13px; overflow-wrap: anywhere; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
        .panel { background: #fff; border: 1px solid #d8dde6; border-radius: 8px; overflow: hidden; margin-bottom: 16px; }
        .clip { padding: 14px; }
        .clip-head { display: flex; justify-content: space-between; align-items: center; gap: 12px; margin-bottom: 10px; }
        .clip-title { font-size: 17px; font-weight: 650; }
        .upload-box { padding: 14px; }
        .back { display: inline-flex; align-items: center; min-height: 32px; margin-top: 8px; font-size: 14px; }
        textarea { width: 100%; min-height: 118px; resize: vertical; border: 1px solid #d8dde6; border-radius: 6px; padding: 10px; font: 14px ui-monospace, SFMono-Regular, Menlo, monospace; line-height: 1.5; }
        .clip-actions { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 10px; }
        button { appearance: none; border: 1px solid #d8dde6; border-radius: 6px; background: #fff; color: #202124; min-height: 38px; padding: 8px 12px; font: inherit; cursor: pointer; }
        button.primary { background: #1a73e8; border-color: #1a73e8; color: #fff; }
        button:disabled { opacity: .58; cursor: progress; }
        .toast { color: #188038; min-height: 20px; font-size: 13px; }
        table { width: 100%; border-collapse: collapse; }
        th, td { padding: 12px 14px; border-bottom: 1px solid #d8dde6; text-align: left; vertical-align: top; }
        th { color: #5f6368; font-size: 12px; font-weight: 600; }
        tr:last-child td { border-bottom: 0; }
        .name { width: 58%; overflow-wrap: anywhere; }
        .folder-download { display: inline-flex; align-items: center; min-height: 28px; margin-left: 10px; font-size: 13px; }
        a { color: #1a73e8; text-decoration: none; }
        a:hover { text-decoration: underline; }
        .empty { color: #5f6368; text-align: center; padding: 28px; }
        @media (max-width: 640px) {
          header { display: block; }
          .clip-head { display: block; }
          th:nth-child(2), td:nth-child(2) { display: none; }
          th, td { padding: 11px 10px; }
          .name { width: auto; }
        }
      </style>
    </head>
    <body>
      <main>
        <header>
          <div>
            <h1>LAN Share Files</h1>
            <div class="path">#{CGI.escapeHTML(display_path)}</div>
            #{nav}
          </div>
        </header>
        <section class="panel clip">
          <div class="clip-head">
            <div class="clip-title">共享剪切板</div>
            <div id="clipStatus" class="toast"></div>
          </div>
          <textarea id="clipText" placeholder="在这里粘贴文字，点保存；另一台设备刷新后点复制。">#{CGI.escapeHTML(clipboard_text)}</textarea>
          <div class="clip-actions">
            <button class="primary" id="saveClip">保存文字</button>
            <button id="copyClip">复制文字</button>
            <button id="refreshClip">刷新</button>
            <button id="clearClip">清空</button>
          </div>
        </section>
        <section class="panel upload-box">
          <div class="clip-head">
            <div class="clip-title">上传文件</div>
            <div id="uploadStatus" class="toast"></div>
          </div>
          <input id="uploadFiles" type="file" multiple>
          <div class="clip-actions">
            <button class="primary" id="uploadButton">上传到共享文件夹</button>
          </div>
        </section>
        <section class="panel">
          <table>
            <thead><tr><th>文件名</th><th>大小</th><th>修改时间</th></tr></thead>
            <tbody>#{list}</tbody>
          </table>
        </section>
      </main>
      <script>
        const currentPath = #{current.to_json};
        const textBox = document.getElementById("clipText");
        const statusBox = document.getElementById("clipStatus");
        const uploadStatus = document.getElementById("uploadStatus");
        const buttons = [...document.querySelectorAll("button")];

        function setStatus(text) {
          statusBox.textContent = text;
          setTimeout(() => {
            if (statusBox.textContent === text) statusBox.textContent = "";
          }, 1800);
        }

        async function api(path, options = {}) {
          const res = await fetch(path, options);
          if (!res.ok) throw new Error(await res.text());
          return res.json();
        }

        async function withBusy(task) {
          buttons.forEach((button) => button.disabled = true);
          try {
            await task();
          } catch (error) {
            setStatus("操作失败");
          } finally {
            buttons.forEach((button) => button.disabled = false);
          }
        }

        document.getElementById("saveClip").addEventListener("click", () => withBusy(async () => {
          const data = await api("/api/clipboard", {
            method: "POST",
            headers: { "Content-Type": "application/json; charset=utf-8" },
            body: JSON.stringify({ text: textBox.value })
          });
          textBox.value = data.text;
          setStatus("已保存");
        }));

        document.getElementById("refreshClip").addEventListener("click", () => withBusy(async () => {
          const data = await api("/api/clipboard");
          textBox.value = data.text;
          setStatus("已刷新");
        }));

        document.getElementById("clearClip").addEventListener("click", () => withBusy(async () => {
          const data = await api("/api/clipboard", {
            method: "POST",
            headers: { "Content-Type": "application/json; charset=utf-8" },
            body: JSON.stringify({ text: "" })
          });
          textBox.value = data.text;
          setStatus("已清空");
        }));

        document.getElementById("copyClip").addEventListener("click", () => withBusy(async () => {
          if (navigator.clipboard && window.isSecureContext) {
            await navigator.clipboard.writeText(textBox.value);
          } else {
            textBox.focus();
            textBox.select();
            document.execCommand("copy");
          }
          setStatus("已复制");
        }));

        document.getElementById("uploadButton").addEventListener("click", () => withBusy(async () => {
          const input = document.getElementById("uploadFiles");
          if (!input.files.length) {
            uploadStatus.textContent = "请先选择文件";
            return;
          }
          const form = new FormData();
          for (const file of input.files) form.append("files", file, file.name);
          uploadStatus.textContent = "上传中...";
          const uploadUrl = `/upload?path=${encodeURIComponent(currentPath)}`;
          const data = await api(uploadUrl, { method: "POST", body: form });
          uploadStatus.textContent = `已上传 ${data.files.length} 个文件`;
          setTimeout(() => location.reload(), 700);
        }));
      </script>
    </body>
    </html>
  HTML
end

def handle_clipboard(request, response)
  case request.request_method
  when "GET"
    json_response(response, { text: clipboard_text })
  when "POST"
    raw = request.body.to_s.force_encoding("UTF-8")
    data = raw.empty? ? {} : JSON.parse(raw)
    text = save_clipboard_text(data["text"])
    json_response(response, { text: text })
  else
    json_response(response, { error: "Method not allowed" }, 405)
  end
rescue JSON::ParserError
  json_response(response, { error: "Invalid JSON" }, 400)
end

def safe_filename(name)
  name = File.basename(name.to_s.dup.force_encoding("UTF-8").scrub("_"))
  name = name.gsub(/[\/\\:\*\?\"\<\>\|]/, "_").strip
  name.empty? ? "upload.bin" : name
end

def unique_upload_path(directory, filename)
  base = File.basename(filename, ".*")
  ext = File.extname(filename)
  path = File.join(directory, filename)
  index = 1
  while File.exist?(path)
    path = File.join(directory, "#{base} (#{index})#{ext}")
    index += 1
  end
  path
end

def handle_upload(request, response)
  upload_dir = safe_path(query_param(request, "path"))
  unless upload_dir && File.directory?(upload_dir)
    return json_response(response, { error: "Upload folder not found" }, 404)
  end

  content_type = request["content-type"].to_s
  unless content_type =~ /boundary=(?:"([^"]+)"|([^;]+))/
    return json_response(response, { error: "Missing multipart boundary" }, 400)
  end

  boundary = Regexp.escape("--#{$1 || $2}")
  body = request.body.to_s.b
  saved = []
  body.split(/#{boundary}(?:--)?\r\n/).each do |part|
    next unless part.include?("filename=")
    header, content = part.split("\r\n\r\n", 2)
    next unless header && content
    next unless header =~ /filename="([^"]*)"/

    filename = safe_filename(CGI.unescapeHTML($1))
    content = content.sub(/\r\n\z/, "")
    path = unique_upload_path(upload_dir, filename)
    File.binwrite(path, content.b)
    saved << File.basename(path)
  end
  json_response(response, { files: saved })
end

def send_file_response(request, response)
  encoded = request.path.sub(%r{\A/download/}, "")
  name = URI.decode_www_form_component(encoded)
  path = safe_path(name)

  unless path
    response.status = 403
    response.body = "Forbidden"
    return
  end

  unless File.file?(path)
    response.status = 404
    response.body = "Not found"
    return
  end

  response["Content-Type"] = WEBrick::HTTPUtils.mime_type(path, WEBrick::HTTPUtils::DefaultMimeTypes)
  response["Content-Disposition"] = %(attachment; filename="#{CGI.escape(name)}"; filename*=UTF-8''#{URI.encode_www_form_component(name)})
  response.body = File.binread(path)
end

def send_folder_response(request, response)
  encoded = request.path.sub(%r{\A/download-folder/}, "")
  name = safe_relative_path(URI.decode_www_form_component(encoded))
  path = safe_path(name)

  unless path && File.directory?(path)
    response.status = 404
    response.body = "Not found"
    return
  end

  zip_name = "#{File.basename(path)}.zip"
  Tempfile.create(["lan-share-folder-", ".zip"]) do |zip|
    zip.close
    FileUtils.rm_f(zip.path)
    py_zip = <<~PY
      import os
      import sys
      import zipfile

      source, target = sys.argv[1], sys.argv[2]
      root_name = os.path.basename(source.rstrip(os.sep))
      with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as archive:
          archive.write(source, root_name)
          for current, dirs, files in os.walk(source):
              dirs.sort()
              files.sort()
              for dirname in dirs:
                  full_path = os.path.join(current, dirname)
                  rel_path = os.path.relpath(full_path, os.path.dirname(source))
                  archive.write(full_path, rel_path)
              for filename in files:
                  full_path = os.path.join(current, filename)
                  rel_path = os.path.relpath(full_path, os.path.dirname(source))
                  archive.write(full_path, rel_path)
    PY
    ok = system("python3", "-c", py_zip, path, zip.path)
    ok ||= system("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", path, zip.path)
    unless ok && File.file?(zip.path)
      response.status = 500
      response.body = "Failed to create zip"
      return
    end

    response["Content-Type"] = "application/zip"
    response["Content-Disposition"] = %(attachment; filename="#{CGI.escape(zip_name)}"; filename*=UTF-8''#{URI.encode_www_form_component(zip_name)})
    response.body = File.binread(zip.path)
  ensure
    FileUtils.rm_f(zip.path)
  end
end

FileUtils.mkdir_p(SHARE_DIR)

server = WEBrick::HTTPServer.new(
  BindAddress: "0.0.0.0",
  Port: PORT,
  AccessLog: [],
  Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN)
)

server.mount_proc("/") do |request, response|
  if request.path.start_with?("/download/")
    send_file_response(request, response)
  elsif request.path.start_with?("/download-folder/")
    send_folder_response(request, response)
  elsif request.path == "/upload" && request.request_method == "POST"
    handle_upload(request, response)
  elsif request.path == "/api/clipboard"
    handle_clipboard(request, response)
  else
    response["Content-Type"] = "text/html; charset=utf-8"
    response.body = page_html(query_param(request, "path"))
  end
end

trap("INT") { server.shutdown }
trap("TERM") { server.shutdown }

puts "LAN Share files: http://0.0.0.0:#{PORT}"
server.start
