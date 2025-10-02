# config.ru
# Minimal Rack app with Faye WebSocket signaling and static file serving

require "rack"
require "faye/websocket"
require "json"
require "thread"

PUBLIC_DIR = File.join(__dir__, "public")

# Ensure correct MIME type for .wasm
Rack::Mime::MIME_TYPES['.wasm'] = 'application/wasm'

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
        @rooms ||= {}
        data = event.data
        begin
          msg = JSON.parse(data)
        rescue
          msg = nil
        end

        if msg.is_a?(Hash) && msg["cmd"] == "join"
          room_id = (msg["room"] || "demo").to_s.strip
          room_id = "demo" if room_id.empty?

          room_peers = (@rooms[room_id] ||= [])
          # snapshot of peers before adding the new one
          peers_before = room_peers.dup

          # Enforce 1:1 rooms: reject third (or more) peers
          if peers_before.length >= 2
            begin
              ws.send({ type: "room_full", max: 2 }.to_json)
            rescue
            end
            begin
              ws.close(1000, "room full")
            rescue
            end
            next
          end

          # send current peer count to the joining client (it will wait if >1)
          ws.send({ type: "peers", count: peers_before.length + 1 }.to_json)
          # notify existing peers that a new peer has arrived (they become caller)
          peers_before.each { |s| s.send({ type: "new_peer" }.to_json) }

          # now add the joining socket to the room and persist room on ws
          room_peers << ws
          ws.instance_variable_set(:@room, room_id)
        elsif msg.is_a?(Hash) && %w[offer answer candidate chat].include?(msg["type"])
          room = ws.instance_variable_get(:@room)
          if room && @rooms[room]
            STDERR.puts "[ws] relay type=#{msg["type"]} room=#{room} peers=#{@rooms[room].length - 1}"
            payload = JSON.dump(msg)
            @rooms[room].each do |peer|
              next if peer.equal?(ws)
              begin
                peer.send(payload)
                STDERR.puts "[ws] -> peer #{peer.object_id}"
              rescue => e
                warn "[ws] relay error: #{e}"
              end
            end
          end
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