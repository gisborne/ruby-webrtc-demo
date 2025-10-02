#!/usr/bin/env ruby
# frozen_string_literal: true

# Usage: ruby scripts/show_qr.rb
# - Ensures Rack app is running on port 9292 (starts it if needed)
# - Ensures ngrok is running and exposes local port 9292
# - Fetches the public ngrok URL (prefers https) and appends ?imple=ruby
# - Generates a QR code image at public/qr.png
# - Writes public/qr.html embedding the QR and link
# - Opens the HTML with macOS `open`

require 'json'
require 'net/http'
require 'uri'
require 'timeout'
require 'tmpdir'
require 'rbconfig'
require 'fileutils'
require 'socket'

begin
  require 'rqrcode'
  require 'chunky_png'
rescue LoadError
  warn "Missing gems. Please run: bundle install"
  exit 1
end

ROOT = File.expand_path('..', __dir__)
PUBLIC_DIR = File.join(ROOT, 'public')
QR_PNG = File.join(PUBLIC_DIR, 'qr.png')
QR_HTML = File.join(PUBLIC_DIR, 'qr.html')
NGROK_PORT = 9292
NGROK_API = URI('http://127.0.0.1:4040/api/tunnels')

# ---- helpers --------------------------------------------------------------

def app_running?(host: '127.0.0.1', port: 9292)
  Socket.tcp(host, port, connect_timeout: 0.3) { |s| s.close; true }
rescue
  false
end

def ensure_app!
  return if app_running?
  puts '[qr] starting rack app on :9292…'
  log_dir = File.join(Dir.tmpdir, 'ruby-wasm-demo')
  FileUtils.mkdir_p(log_dir)
  out_log = File.join(log_dir, 'rack.out.log')
  err_log = File.join(log_dir, 'rack.err.log')
  # Prefer bundle exec rackup to use Gemfile environment
  pid = Process.spawn({'RACK_ENV'=>'development'}, 'bundle', 'exec', 'rackup', '-p', '9292', chdir: ROOT, out: out_log, err: err_log)
  Process.detach(pid)
  Timeout.timeout(20) do
    until app_running?
      sleep 0.3
    end
  end
rescue Errno::ENOENT
  abort "Couldn't start rack app. Is bundler/rackup installed? Try: bundle install && bundle exec rackup -p 9292"
rescue Timeout::Error
  abort 'Timed out waiting for rack app on http://127.0.0.1:9292. Check rack logs.'
end

def ngrok_running?
  Net::HTTP.start('127.0.0.1', 4040, open_timeout: 0.3, read_timeout: 0.5) do |http|
    req = Net::HTTP::Get.new('/api/tunnels')
    res = http.request(req)
    return res.is_a?(Net::HTTPSuccess)
  end
rescue Errno::ECONNREFUSED, Net::OpenTimeout, Net::ReadTimeout
  false
end

# Start ngrok in the background if not running. Requires `ngrok` in PATH.
# ngrok v3 default web interface remains at 4040.

def ensure_ngrok!
  return if ngrok_running?

  puts '[qr] starting ngrok…'
  log_dir = File.join(Dir.tmpdir, 'ruby-wasm-demo')
  FileUtils.mkdir_p(log_dir)
  out_log = File.join(log_dir, 'ngrok.out.log')
  err_log = File.join(log_dir, 'ngrok.err.log')

  pid = spawn('ngrok', 'http', NGROK_PORT.to_s, out: out_log, err: err_log)
  Process.detach(pid)

  Timeout.timeout(15) do
    until ngrok_running?
      sleep 0.3
    end
  end
rescue Errno::ENOENT
  abort "`ngrok` binary not found in PATH. Install ngrok and try again."
rescue Timeout::Error
  abort 'Timed out waiting for ngrok API at http://127.0.0.1:4040. Check ngrok logs.'
end

# Append or add a query parameter to a base URL string

def with_query_param(url, key, value)
  uri = URI(url)
  params = URI.decode_www_form(uri.query.to_s)
  params << [key, value]
  uri.query = URI.encode_www_form(params)
  uri.to_s
end

# Fetch the public https URL for the http tunnel and append impl=ruby

def fetch_public_url
  res = Net::HTTP.get_response(NGROK_API)
  unless res.is_a?(Net::HTTPSuccess)
    abort "Failed to query ngrok API: #{res.code} #{res.message}"
  end
  data = JSON.parse(res.body)
  tunnels = Array(data['tunnels'])
  # Prefer https public_url for the HTTP tunnel
  https = tunnels.find { |t| t['proto'] == 'https' }&.dig('public_url')
  http  = tunnels.find { |t| t['proto'] == 'http' }&.dig('public_url')
  base = https || http
  abort 'No ngrok tunnels found. Is ngrok exposing the right port?' unless base
  base = base.end_with?('/') ? base : (base + '/')
  with_query_param(base, 'impl', 'ruby')
end

# Generate QR PNG using rqrcode

def write_qr_png(url)
  puts "[qr] generating QR for: #{url}"
  qrcode = RQRCode::QRCode.new(url)
  png = qrcode.as_png(
    bit_depth: 1,
    border_modules: 4,
    color_mode: ChunkyPNG::COLOR_GRAYSCALE,
    color: 'black',
    file: nil,
    fill: 'white',
    module_px_size: 8,
    resize_gte_to: false,
    size: 320
  )
  File.binwrite(QR_PNG, png.to_s)
end


def write_html(url)
  html = <<~HTML
  <!doctype html>
  <html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Connect to Demo</title>
    <style>
      html, body { height: 100%; margin: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; }
      .wrap { min-height: 100%; display: grid; place-items: center; background: #0f172a; color: #e2e8f0; }
      .card { background: #111827; border-radius: 12px; padding: 24px 28px; box-shadow: 0 10px 30px rgba(0,0,0,.35); text-align: center; }
      .card h1 { font-size: 20px; margin: 0 0 12px; }
      .qr { background: #fff; padding: 12px; border-radius: 8px; display: inline-block; }
      .link { margin-top: 12px; font-size: 14px; word-break: break-all; }
      a { color: #93c5fd; text-decoration: none; }
      a:hover { text-decoration: underline; }
    </style>
  </head>
  <body>
    <div class="wrap">
      <div class="card">
        <h1>Scan to open the demo</h1>
        <div class="qr"><img src="./qr.png" alt="QR code" width="320" height="320" /></div>
        <div class="link"><a href="#{url}" target="_blank" rel="noopener">#{url}</a></div>
      </div>
    </div>
  </body>
  </html>
  HTML
  File.write(QR_HTML, html)
end

# ---- run -------------------------------------------------------------------
FileUtils.mkdir_p(PUBLIC_DIR)
ensure_app!
ensure_ngrok!
url = fetch_public_url
write_qr_png(url)
write_html(url)

# Open in the default browser (macOS)
if RbConfig::CONFIG['host_os'] =~ /darwin/i
  system('open', QR_HTML)
else
  # Best-effort fallback for other platforms
  system(ENV['BROWSER'] || 'xdg-open', QR_HTML)
end

puts "[qr] opened #{QR_HTML}"
