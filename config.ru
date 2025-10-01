# config.ru
# Minimal Rack app with Faye WebSocket signaling and static file serving

require "rack"
require "faye/websocket"
require "json"
require "thread"

PUBLIC_DIR = File.join(__dir__, "public")

# Lowercase all response header names (Rack 3 requires lowercase)
class LowercaseHeaders
  def initialize(app)
    @app = app
  end

  def call(env)
    status, headers, body = @app.call(env)
    fixed = {}
    headers.each { |k, v| fixed[k.to_s.downcase] = v }
    [status, fixed, body]
  end
end

# rooms[room_name] = [sockets...]
rooms = Hash.new { |h, k| h[k] = [] }
mutex = Mutex.new

class WsApp
  def initialize(rooms, mutex)
    @rooms = rooms
    @mutex = mutex
  end

  def call(env)
    if Faye::WebSocket.websocket?(env)
      STDERR.puts "[ws] upgrade path=#{env['PATH_INFO']} conn=#{env['HTTP_CONNECTION']} upgrade=#{env['HTTP_UPGRADE']} hijack=#{!!env['rack.hijack']}"
      ws = Faye::WebSocket.new(env)
      room_id = nil

      ws.on :message do |event|
        STDERR.puts "[ws] msg #{event.data[0..120]}"
        data = JSON.parse(event.data) rescue {}
        if data["cmd"] == "join"
          room_id = (data["room"] || "demo").to_s.strip
          room_id = "demo" if room_id.empty?

          existing = nil
          count = nil
          @mutex.synchronize do
            existing = @rooms[room_id].dup
            @rooms[room_id] << ws
            count = @rooms[room_id].size
          end

          ws.send({ type: "peers", count: count }.to_json)
          existing.each { |s| s.send({ type: "new_peer" }.to_json) }
        else
          next unless room_id
          recipients = nil
          @mutex.synchronize do
            recipients = @rooms[room_id].reject { |s| s.equal?(ws) }
          end
          recipients.each { |s| s.send(event.data) }
        end
      end

      ws.on :close do |_|
        @mutex.synchronize do
          if room_id && @rooms.key?(room_id)
            @rooms[room_id].delete(ws)
            @rooms.delete(room_id) if @rooms[room_id].empty?
          end
        end
      end

      return ws.rack_response
    end

    # If this app is mounted at /ws, any non-upgrade request should get 426
    if env["SCRIPT_NAME"] == "/ws" || env["PATH_INFO"] == "/ws" || env["PATH_INFO"] == "/"
      return [426, { "content-type" => "text/plain", "upgrade" => "websocket" }, ["Expected WebSocket upgrade"]]
    end
    [404, { "content-type" => "text/plain" }, ["Not Found"]]
  end
end

static_app = Rack::Builder.new do
  use Rack::ContentType
  use Rack::Static, root: PUBLIC_DIR, urls: [""], index: "index.html"
  run ->(_env) { [404, { "content-type" => "text/plain" }, ["Not Found"]] }
end

use LowercaseHeaders

run Rack::URLMap.new(
  "/ws" => WsApp.new(rooms, mutex), # WebSocket signaling
  "/"   => static_app               # serve public/index.html and assets
)