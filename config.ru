# frozen_string_literal: true

# config.ru
# Rack app serving a simple WebRTC chat demo:
# - Static files from `public/` at `/` (index.html, JS, Ruby WASM assets)
# - WebSocket signaling server at `/ws` (rooms with up to 2 peers)
#
# Signaling messages:
# - Client -> server: { cmd: 'join', room }
# - Server -> client: { type: 'peers', count }
# - Server -> existing peers: { type: 'new_peer' }
# - Peer <-> peer via server relay (broadcast to other peer):
#     { type: 'offer' | 'answer' | 'candidate' | 'chat', ... }
# - On third join: { type: 'room_full', max: 2 } and socket is closed.

require "rack"
require "faye/websocket"
require "json"

PUBLIC_DIR = File.join(__dir__, "public")

# Ensure correct MIME type for .wasm
Rack::Mime::MIME_TYPES['.wasm'] = 'application/wasm'

# Lowercase all response header names (Rack 3 requires lowercase)
class LowercaseHeaders
  # Middleware to lower-case header names for more predictable access in Rack
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

# In-memory room registry (demo only; process-local)
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
      # Upgrade to WebSocket for signaling
      STDERR.puts "[ws] upgrade path=#{env['PATH_INFO']} conn=#{env['HTTP_CONNECTION']} upgrade=#{env['HTTP_UPGRADE']} hijack=#{!!env['rack.hijack']}"
      ws = Faye::WebSocket.new(env)
      room_id = nil

      ws.on :message do |event|
        # Parse incoming JSON once; ignore invalid payloads
        STDERR.puts "[ws] msg #{event.data[0..120]}"
        @rooms ||= {}
        data = event.data
        begin
          msg = JSON.parse(data)
        rescue
          msg = nil
        end

        if msg.is_a?(Hash) && msg["cmd"] == "join"
          # New client joins a room (created on-demand)
          room_id = (msg["room"] || "demo").to_s.strip
          room_id = "demo" if room_id.empty?

          room_peers = (@rooms[room_id] ||= [])
          # snapshot of peers before adding the new one
          peers_before = room_peers.dup

          # Enforce a 1:1 room for this demo. Third and later clients are rejected.
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
          # Notify existing peers that a new peer has arrived (they become caller)
          peers_before.each { |s| s.send({ type: "new_peer" }.to_json) }

          # Add the joining socket to the room and remember its room id
          room_peers << ws
          ws.instance_variable_set(:@room, room_id)
        elsif msg.is_a?(Hash) && %w[offer answer candidate chat].include?(msg["type"])
          # Relay WebRTC/Chat messages to the other peer(s) in the same room
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
        # Remove closed socket from its room
        @mutex.synchronize do
          if room_id && @rooms.key?(room_id)
            @rooms[room_id].delete(ws)
            @rooms.delete(room_id) if @rooms[room_id].empty?
          end
        end
      end

      return ws.rack_response
    end

    # Non-upgrade HTTP requests to /ws get 426; other paths 404. Static files are
    # handled below by the Rack::Static app mounted at "/".
    # If this app is mounted at /ws, any non-upgrade request should get 426
    if env["SCRIPT_NAME"] == "/ws" || env["PATH_INFO"] == "/ws" || env["PATH_INFO"] == "/"
      return [426, { "content-type" => "text/plain", "upgrade" => "websocket" }, ["Expected WebSocket upgrade"]]
    end
    [404, { "content-type" => "text/plain" }, ["Not Found"]]
  end
end

# Serve static demo files from /public at the root path
static_app = Rack::Builder.new do
  use Rack::ContentType
  use Rack::Static, root: PUBLIC_DIR, urls: [""], index: "index.html"
  run ->(_env) { [404, { "content-type" => "text/plain" }, ["Not Found"]] }
end

use LowercaseHeaders

# Mount signaling at /ws and static site at /
run Rack::URLMap.new(
  "/ws" => WsApp.new(rooms, mutex), # WebSocket signaling
  "/"   => static_app               # serve public/index.html and assets
)