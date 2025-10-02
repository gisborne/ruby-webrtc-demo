# public/ruby/app.rb
# Ruby-in-the-browser WebRTC chat client (DataChannel) using ruby.wasm.
# What this file does:
# - Parses room name from URL hash and connects to the Rack WebSocket signaling server at `/ws`.
# - Creates an RTCPeerConnection (STUN by default; optional TURN via URL params `turn`, `turnUser`, `turnPass`).
# - Negotiates a DataChannel (offer/answer + ICE candidates) and exchanges chat messages.
# - Falls back to plain WebSocket chat automatically if WebRTC fails or times out.
#
# Quick start:
# - Open two tabs to the same `#room` (e.g. /index.html?impl=ruby#demo)
# - Optional TURN-only: add `&forceRelay=1&turn=turn:host:3478&turnUser=USER&turnPass=PASS`.
# - Transport badge shows whether you are using WebRTC (DataChannel) or WebSocket.

require "js"
require "json"

puts "[ruby] app.rb starting"

def checkpoint(tag)
  puts "[ruby] ckpt #{tag}"
end

begin
  checkpoint "start"

  JS = JS unless defined?(JS)

  # Helpers to access DOM from Ruby (avoid unbound method calls; use JS.eval)
  $document = JS.global[:document]

  def dom_by_id(id)
    # Using JS.eval ensures correct binding/context for DOM access
    JS.eval("document.getElementById('#{id}')")
  end

  def set_status(text)
    # Delegate to namespaced UI helper for consistency
    JS.eval("try{ if(window.RubyRTC && window.RubyRTC.ui && typeof RubyRTC.ui.setStatus==='function'){ RubyRTC.ui.setStatus(" + "Ruby: #{text}".to_json + "); } else { var e=document.getElementById('status'); if(e){ e.innerHTML = " + "status: <em>Ruby: #{text}</em>".to_json + "; } } }catch(e){}")
  end

  def append(kind, text)
    # Delegate to namespaced UI helper for consistency
    JS.eval("try{ if(window.RubyRTC && RubyRTC.ui && typeof RubyRTC.ui.append==='function'){ RubyRTC.ui.append(" + kind.to_json + ", " + text.to_json + "); } else { var log=document.getElementById('log'); if(!log) return; var d=document.createElement('div'); d.className=" + kind.to_json + "; d.textContent=" + text.to_json + "; log.appendChild(d); log.scrollTop=log.scrollHeight; } }catch(e){}")
  end

  # --- Room selection --------------------------------------------------------
  # We derive the room from the URL hash (#room). If it is missing, default to "demo".
  # This matches the JavaScript client for consistency.
  checkpoint "room-ok"
  location = JS.global[:location]
  room =
    if location[:hash].to_s.length > 1
      location[:hash].to_s[1..-1]
    else
      "demo"
    end
  room = "demo" if room.nil? || room.strip == ""

  checkpoint "before-roomname"
  # Write roomName via JS to avoid Reflect.set on host objects
  JS.eval("var e=document.getElementById('roomName'); if(e){ e.textContent = #{room.to_json} }")

  checkpoint "after-roomname"
  if location[:hash].to_s == ""
    checkpoint "before-set-hash"
    # Use JS.eval to avoid Reflect.set on special host objects (location)
    JS.eval("location.hash = '##{room}'")
    checkpoint "after-set-hash"
  end

  puts "[ruby] room selected #{room}"

  # --- UI elements -----------------------------------------------------------
  # We keep a few helpers to update status and append chat lines.
  # The transport badge is updated by the JS fallback helpers.
  checkpoint "ui-ok"
  JS.eval("var t=document.getElementById('transport'); if(t){ t.textContent='ruby+webrtc'; t.style.background='#e8ffe8'; t.style.color='#174'; }")

  set_status("initializing…")
  puts "[ruby] after UI setup"
  checkpoint "after-ui-setup"

  # --- ICE/TURN parameters ---------------------------------------------------
  # Read optional TURN parameters from the query string and build a safe config.
  # Also detect `forceRelay=1` to request TURN-only transport when needed (e.g. cellular).
  checkpoint "before-params"
  turn_url  = JS.eval("new URLSearchParams(location.search).get('turn')")
  turn_user = JS.eval("new URLSearchParams(location.search).get('turnUser')")
  turn_pass = JS.eval("new URLSearchParams(location.search).get('turnPass')")
  force_relay = JS.eval("new URLSearchParams(location.search).get('forceRelay')")
  checkpoint "after-params"

  # Coerce to plain Ruby strings (avoid JS handles leaking into to_json)
  tu  = turn_url.nil?  ? nil : turn_url.to_s
  tus = (tu && tu.strip != "") ? tu : nil
  uu  = turn_user.nil? ? nil : turn_user.to_s
  uus = (uu && uu.strip != "") ? uu : nil
  pu  = turn_pass.nil? ? nil : turn_pass.to_s
  pus = (pu && pu.strip != "") ? pu : nil
  checkpoint "after-coerce"

  # Build full JS config string to avoid any Ruby->JS property sets.
  # We prefer simple, explicit strings here since they cross the Ruby<->JS boundary.
  js_pc_cfg = if tus && uus && pus
    "({ iceServers: [ { urls: 'stun:stun.l.google.com:19302' }, { urls: #{tus.to_json}, username: #{uus.to_json}, credential: #{pus.to_json} } ]" +
    (force_relay == "1" ? ", iceTransportPolicy: 'relay'" : "") + " })"
  else
    "({ iceServers: [ { urls: 'stun:stun.l.google.com:19302' } ]" +
    (force_relay == "1" ? ", iceTransportPolicy: 'relay'" : "") + " })"
  end
  checkpoint "built-config"
  # Stash config for later on-demand PC creation from JS.
  JS.eval("try{ window.__ruby_pc_cfg = " + js_pc_cfg + "; }catch(e){}")
  # Provide a safe builder that filters invalid iceServers and always falls back to STUN.
  JS.eval(<<~JS
  (function(){
    const code = `
      (function(){
        function setStatus(t){ var el=document.getElementById('status'); if(el) el.innerHTML='status: <em>'+t+'</em>'; }
        function appendPeer(t){ var log=document.getElementById('log'); if(!log) return; var d=document.createElement('div'); d.className='peer'; d.textContent=t; log.appendChild(d); log.scrollTop=log.scrollHeight; }
        function enableSend(b){ var s=document.getElementById('sendBtn'); var m=document.getElementById('msg'); if(s) s.disabled=!b; if(m) m.disabled=!b; }
        function setTransportLabel(t){ var el=document.getElementById('transport'); if(!el) return; el.textContent=t; el.style.background = (t==='webrtc')? '#e8ffe8':'#ffe8e8'; el.style.color = (t==='webrtc')? '#174':'#711'; }

        var __ruby_transport = 'webrtc';
        var __ruby_connect_timer = null;
        function updateTransport(){ setTransportLabel(__ruby_transport); }
        function clearConnectTimer(){ try{ if(__ruby_connect_timer){ clearTimeout(__ruby_connect_timer); __ruby_connect_timer=null; } }catch(_){} }
        function armConnectTimeout(ms){ clearConnectTimer(); __ruby_connect_timer = setTimeout(function(){ useWsFallback('timeout'); }, (ms||8000)); }

        // WS ensure + queue flush
        window.__ruby_ws_queue = window.__ruby_ws_queue || [];
        window.__ruby_ensure_ws = window.__ruby_ensure_ws || function(){
          try{
            var w=window.__ruby_ws;
            if(!w || w.readyState===3){
              var proto=(location.protocol==='https:')?'wss:':'ws:';
              var url=proto+'//'+location.host+'/ws';
              w=new WebSocket(url);
              window.__ruby_ws=w;
              w.onopen=function(){
                try{ if(window.__ruby_ws_handler){ w.onmessage = window.__ruby_ws_handler; } }catch(_){}
                try{
                  var q = Array.isArray(window.__ruby_ws_queue)? window.__ruby_ws_queue.splice(0): [];
                  for(var i=0;i<q.length;i++){ try{ q[i](w); }catch(_){} }
                }catch(_){}
                try{ RubyOnWsOpen(); }catch(_){}
              };
            } else {
              try{ if(window.__ruby_ws_handler){ w.onmessage = window.__ruby_ws_handler; } }catch(_){}
            }
            return w;
          }catch(_){ return null; }
        };

        function useWsFallback(reason){
          if(__ruby_transport==='ws') return;
          __ruby_transport='ws';
          window.__ruby_force_ws = true;
          try{ if(window.__ruby_dc){ window.__ruby_dc.close(); } }catch(_){}
          try{ if(window.__ruby_pc){ window.__ruby_pc.close(); } }catch(_){}
          setStatus('fallback to websocket' + (reason? ' ('+reason+')':''));
          enableSend(true);
          updateTransport();
          window.__ruby_ensure_ws();
        }

        function renderMsg(e){
          try{
            var v = (e && typeof e === 'object' && 'data' in e) ? e.data : e;
            if (typeof v === 'string') return v;
            if (v && typeof Blob !== 'undefined' && v instanceof Blob){
              var fr = new FileReader();
              fr.onload = function(){ appendPeer('Peer: ' + (fr.result!=null? String(fr.result): '')); };
              try{ fr.readAsText(v); }catch(_){}
              return null;
            }
            if (v && (v.byteLength !== undefined || (v.buffer && v.buffer.byteLength !== undefined))){
              try{ var dec = new TextDecoder(); return dec.decode(v.byteLength !== undefined ? v : v.buffer); }catch(_){}
            }
            return (v==null) ? '' : String(v);
          }catch(_){ return ''; }
        }

        function wireChannel(){
          var ch=window.__ruby_dc; if(!ch) return;
          ch.onopen=function(){ __ruby_transport='webrtc'; updateTransport(); setStatus('connected'); enableSend(true); clearConnectTimer(); };
          ch.onmessage=function(e){ try{ var v=renderMsg(e); if(v!=null){ appendPeer('Peer: '+v); } }catch(_){ appendPeer('Peer: '); } };
          ch.onclose=function(){ if(__ruby_transport==='webrtc'){ setStatus('disconnected'); enableSend(false); } };
        }

        function wirePc(){
          var p=window.__ruby_pc; if(!p) return;
          p.onicecandidate = function(ev){ try{ if(ev && ev.candidate){ RubyOnIceCandidate(ev.candidate); } }catch(e){} };
          p.ondatachannel=function(ev){ try{ window.__ruby_dc = ev.channel; wireChannel(); }catch(e){} };
          p.oniceconnectionstatechange=function(){ try{ var s=p.iceConnectionState; if(s==='failed'){ useWsFallback('ice failed'); } if(s==='connected'||s==='completed'){ setStatus('connected'); } }catch(e){} };
          updateTransport();
        }

        if(!window.RubyRTC) window.RubyRTC = {};
        window.RubyRTC.ui = window.RubyRTC.ui || {};
        window.RubyRTC.util = window.RubyRTC.util || {};
        window.RubyRTC.wirePc = wirePc;
        window.RubyRTC.wireChannel = wireChannel;
        window.RubyRTC.ui.setStatus = setStatus;
        window.RubyRTC.ui.appendPeer = appendPeer;
        window.RubyRTC.ui.append = function(kind, text){ var log=document.getElementById('log'); if(!log) return; var d=document.createElement('div'); d.className=String(kind||''); d.textContent=String(text==null?'':text); log.appendChild(d); log.scrollTop=log.scrollHeight; };
        window.RubyRTC.ui.enableSend = enableSend;
        window.RubyRTC.util.renderMsg = renderMsg;

        window.__ruby_remote_set = false;
        window.__ruby_pending = [];

        window.__ruby_ws_handler = async function(evt){
          var msg={}; try{ msg=JSON.parse(evt.data); }catch(e){};
          var p = window.__ruby_pc;
          if(msg.type==='chat'){
            try{
              var v = (msg && ('text' in msg)) ? msg.text : '';
              if (typeof v === 'undefined' || v === null) v = '';
              var text = (typeof v === 'string') ? v : String(v);
              appendPeer('Peer: ' + text);
            }catch(_){ appendPeer('Peer: '); }
            return;
          }
          if(msg.type==='peers'){ if((msg.count||0)>1){ setStatus('peer present (waiting for new_peer to initiate)'); } else { setStatus('waiting for peer'); } return; }
          if(msg.type==='new_peer'){
            if(!window.__ruby_offer_started){
              try{
                window.__ruby_offer_started=true;
                if(!p){
                  console.warn('[webrtc] no pc (creating)');
                  try{ window.__ruby_pc = p = window.__ruby_build_pc(); if(!p){ console.error('[webrtc] build pc returned null'); return; } wirePc(); }catch(e){ console.error('[webrtc] create pc on-demand failed', e); return; }
                }
                window.__ruby_dc=p.createDataChannel('chat'); wireChannel();
                var off=await p.createOffer(); await p.setLocalDescription(off);
                window.__ruby_send_offer(off, #{room.to_json});
                armConnectTimeout(8000);
              }catch(e){ console.error('[webrtc] offer error', e); }
            }
            return;
          }
          if(msg.type==='offer'){
            try{
              if(!p){
                console.warn('[webrtc] no pc (creating)');
                try{ window.__ruby_pc = p = window.__ruby_build_pc(); if(!p){ console.error('[webrtc] build pc returned null'); return; } wirePc(); }catch(e){ console.error('[webrtc] create pc on-demand failed', e); return; }
              }
              await p.setRemoteDescription(typeof msg.sdp==='string'? {type:'offer', sdp:msg.sdp}: msg.sdp);
              window.__ruby_remote_set=true;
              while(window.__ruby_pending.length){ try{ await p.addIceCandidate(window.__ruby_pending.shift()); }catch(e){ console.error('drain cand', e); } }
              var ans=await p.createAnswer(); await p.setLocalDescription(ans);
              window.__ruby_send_answer(ans, #{room.to_json});
              setStatus('sent answer');
              armConnectTimeout(8000);
            }catch(e){ console.error('[webrtc] answer error', e); }
            return;
          }
          if(msg.type==='answer'){
            try{
              if(!p){
                console.warn('[webrtc] no pc (creating)');
                try{ window.__ruby_pc = p = window.__ruby_build_pc(); if(!p){ console.error('[webrtc] build pc returned null'); return; } wirePc(); }catch(e){ console.error('[webrtc] create pc on-demand failed', e); return; }
              }
              await p.setRemoteDescription(typeof msg.sdp==='string'? {type:'answer', sdp:msg.sdp}: msg.sdp);
              window.__ruby_remote_set=true;
              while(window.__ruby_pending.length){ try{ await p.addIceCandidate(window.__ruby_pending.shift()); }catch(e){ console.error('drain cand', e); } }
              setStatus('got answer (establishing)');
            }catch(e){ console.error('[webrtc] setRemote ans error', e); }
            return;
          }
          if(msg.type==='candidate'){
            try{
              if(!msg.candidate || !msg.candidate.candidate){ return; }
              if(!p){
                console.warn('[webrtc] no pc (creating)');
                try{ window.__ruby_pc = p = window.__ruby_build_pc(); if(!p){ console.error('[webrtc] build pc returned null'); return; } wirePc(); }catch(e){ console.error('[webrtc] create pc on-demand failed', e); return; }
              }
              if(!window.__ruby_remote_set){ window.__ruby_pending.push(msg.candidate); }
              else { await p.addIceCandidate(msg.candidate); }
            }catch(e){ console.error('[webrtc] addIce error', e); }
            return;
          }
        };

        try{ var w=window.__ruby_ws; if(w && w.readyState===1 && window.__ruby_ws_handler){ w.onmessage = window.__ruby_ws_handler; } }catch(e){}
      })();
    `;
    try {
      eval(code + "\\n//# sourceURL=ruby_boot.js");
    } catch (e) {
      console.error("[ruby boot js] parse/runtime error:", e);
      console.log(code);
    }
  })();
JS
)
  # --- RTCPeerConnection creation -------------------------------------------
  # We attempt to create the PC with the prepared config first, then retry without
  # explicit config as a last resort. Any failure is surfaced to the status line.
  checkpoint "before-pc"
  # Build PC via pure JS, store on window.__ruby_pc, and bind 'pc' to it
  begin
    JS.eval("try{ window.__ruby_pc = new RTCPeerConnection" + js_pc_cfg + "; }catch(e){ window.__ruby_pc = null; }")
    pc = JS.global[:__ruby_pc]
    if pc.nil?
      # Retry without config as last resort
      JS.eval("try{ window.__ruby_pc = new RTCPeerConnection(); }catch(e){ window.__ruby_pc = null; }")
      pc = JS.global[:__ruby_pc]
    end
    raise "RTCPeerConnection creation failed" if pc.nil?
    puts "[ruby] pc ready"
  rescue => e
    JS.global[:console][:error].call("[ruby] RTCPeerConnection create failed", e.to_s)
    set_status("failed to create RTCPeerConnection (see console)")
    raise e
  end
  checkpoint "after-pc"
  puts "[ruby] RTCPeerConnection created"

  local_pending_candidates = []
  ws_ready = false

  # --- Ruby callbacks invoked by DataChannel/ICE handlers --------------------
  # These are bound from JS and only contain small UI updates.
  JS.global[:RubyOnDCOpen] = proc do
    set_status("connected")
    JS.eval("var b=document.getElementById('sendBtn'); if(b){ b.disabled=false }")
    JS.eval("var m=document.getElementById('msg'); if(m){ m.disabled=false }")
  end
  JS.global[:RubyOnDCMessage] = proc do |data|
    append("peer", "Peer: #{data}")
  end
  JS.global[:RubyOnDCClose] = proc do
    set_status("disconnected")
    JS.eval("var b=document.getElementById('sendBtn'); if(b){ b.disabled=true }")
    JS.eval("var m=document.getElementById('msg'); if(m){ m.disabled=true }")
  end

  # --- Attach PC event handlers (delegates to JS wiring) ---------------------
  # The JS side wires `onicecandidate`, `ondatachannel`, and `oniceconnectionstatechange`.
  # Ruby callbacks above are invoked for small UI updates only.
  attach_pc_handlers = proc do
    # Ruby callbacks
    JS.global[:RubyOnIceCandidate] = proc do |cand|
      if !cand.nil?
        begin
          cobj = {
            candidate: (cand[:candidate].to_s rescue nil),
            sdpMid: (cand[:sdpMid].to_s rescue nil),
            sdpMLineIndex: (cand[:sdpMLineIndex].to_i rescue nil),
            usernameFragment: (cand[:usernameFragment].to_s rescue nil)
          }
          # Only queue real candidates (skip null end-of-candidates)
          if cobj[:candidate] && cobj[:candidate] != ""
            local_pending_candidates << cobj
          end
        rescue => e
          puts "[ruby] onicecandidate build error: #{e.to_s}"
        end
        if ws_ready
          begin
            c = local_pending_candidates.shift
            while c
              # c is a plain Ruby hash
              JS.eval("window.__ruby_send_candidate(" + c.to_json + ", " + room.to_json + ")")
              c = local_pending_candidates.shift
            end
          rescue => e
            puts "[ruby] flush local cand warn: #{e.to_s}"
          end
        end
      end
    end

    JS.global[:RubyOnDataChannel] = proc do
      # JS will wire handlers directly; nothing required here
    end

    JS.global[:RubyOnIceState] = proc do |state|
      s = state.to_s
      puts "iceConnectionState= #{s}"
      if s == "connected" || s == "completed"
        set_status("connected")
      elsif s == "failed"
        set_status("ICE failed (Ruby)")
      end
    end

    # Delegate actual PC/DC wiring to the single JS implementation
    JS.eval("try{ wirePc(); }catch(e){}")
  end

  # --- WebSocket signaling ---------------------------------------------------
  # We connect to the Rack server at `/ws`. Incoming messages are handled by
  # `window.__ruby_ws_handler` and drive the WebRTC state machine.
  checkpoint "before-ws"
  ws_proto = (location[:protocol].to_s == "https:") ? "wss:" : "ws:"
  ws_url = "#{ws_proto}//#{location[:host].to_s}/ws"

  begin
    # Create WS via JS and store on window to avoid bridge apply/ctor issues
    JS.eval("try{ window.__ruby_ws = new WebSocket(#{ws_url.to_json}); }catch(e){ window.__ruby_ws = null; }")
    ws = JS.global[:__ruby_ws]
    if ws.nil?
      raise "WebSocket creation failed"
    end
    checkpoint "after-ws"
    puts "[ruby] WS created #{ws_url}"
    JS.eval("try{ console.log('[ws] created, readyState=', (window.__ruby_ws && window.__ruby_ws.readyState)); }catch(e){}")
    # Normalize on* properties in some environments
    JS.eval("if(window.__ruby_ws){ try{ window.__ruby_ws.onmessage = window.__ruby_ws.onmessage || null; }catch(e){} }")
    # Ensure onopen binds RubyOpen and onmessage handler immediately
    JS.eval(
      "try{\n" +
      "  if(window.__ruby_ws){\n" +
      "    window.__ruby_ws.onopen = function(){ try{ console.log('[ws] onopen'); RubyOnWsOpen(); }catch(e){} try{ if(window.__ruby_ws_handler){ console.log('[ws] binding onmessage handler'); window.__ruby_ws.onmessage = window.__ruby_ws_handler; console.log('[ws] onmessage bound'); } }catch(e){} console.log('[ws] readyState after onopen=', window.__ruby_ws && window.__ruby_ws.readyState); };\n" +
      "  }\n" +
      "}\n" +
      "catch(e){}"
    )
    # If the socket is already open, invoke immediately and bind handler now
    JS.eval(
      "try{\n" +
      "  var w=window.__ruby_ws;\n" +
      "  if(w && w.readyState===1){\n" +
      "    try{ console.log('[ws] already open -> invoking RubyOnWsOpen'); RubyOnWsOpen(); }catch(e){}\n" +
      "    try{ if(window.__ruby_ws_handler){ console.log('[ws] binding onmessage handler (already open)'); w.onmessage = window.__ruby_ws_handler; console.log('[ws] onmessage bound (already open)'); } }catch(e){}\n" +
      "  }\n" +
      "}\n" +
      "catch(e){}"
    )
    # Define a safe JS-side sender to avoid Ruby->JS function calls
    JS.eval("window.__ruby_send = function(s){ try{ if(window.__ruby_ws){ window.__ruby_ws.send(s); } }catch(e){} }")
  rescue => e
    JS.global[:console][:error].call("[ruby] WS constructor failed", ws_url, e.to_s)
    set_status("failed to create WebSocket (see console)")
  end

  # After WS is created: perform a soft readiness check and update status if slow.
  JS.global[:RubyWsTimeoutCheck] = proc do
    ready = ws[:readyState].to_i rescue -1
    unless ready == 1 # OPEN
      puts "[ruby] WS not open after 3s, readyState=#{ready}"
      set_status("still initializing… (waiting for signaling)")
    end
  end
  JS.eval("try{ setTimeout(function(){ RubyWsTimeoutCheck(); }, 3000); }catch(e){}")

  # --- Signaling send helpers ------------------------------------------------
  # Small helpers to JSON-encode and send offer/answer/candidate/chat messages.
  JS.eval(
    "(function(){\n" +
    "  // Buffered WS sends: if WS not open, queue and ensure it's (re)created\n" +
    "  window.__ruby_ws_queue = window.__ruby_ws_queue || [];\n" +
    "  function __ruby_ws_send_or_queue(fn){ try{ var w=window.__ruby_ws; if(w && w.readyState===1){ fn(w); } else { window.__ruby_ws_queue.push(fn); try{ if(typeof window.__ruby_ensure_ws==='function'){ window.__ruby_ensure_ws(); } }catch(_){} } }catch(_){ } }\n" +
    "  window.__ruby_send_obj = function(o){ __ruby_ws_send_or_queue(function(w){ try{ w.send(JSON.stringify(o)); }catch(_){ } }); };\n" +
    "  window.__ruby_send_offer = function(off, room){ __ruby_ws_send_or_queue(function(w){ try{ w.send(JSON.stringify({ room: room, type: 'offer', sdp: off })); }catch(_){ } }); };\n" +
    "  window.__ruby_send_answer = function(ans, room){ __ruby_ws_send_or_queue(function(w){ try{ w.send(JSON.stringify({ room: room, type: 'answer', sdp: ans })); }catch(_){ } }); };\n" +
    "  window.__ruby_send_candidate = function(cand, room){ __ruby_ws_send_or_queue(function(w){ try{ w.send(JSON.stringify({ room: room, type: 'candidate', candidate: cand })); }catch(_){ } }); };\n" +
    "  window.__ruby_send_chat = function(room, text){ __ruby_ws_send_or_queue(function(w){ try{ w.send(JSON.stringify({ room: room, type: 'chat', text: text })); }catch(_){ } }); };\n" +
    "})();"
  )

  # Wire WS events via JS property assignment, invoking Ruby procs.
  JS.global[:RubyOnWsOpen] = proc do
    set_status("signaling open")

    # Send join with primitives via JS-side stringify
    JS.eval("if(window.RubyRTC&&window.RubyRTC.send){ window.RubyRTC.send.obj(" + { cmd: "join", room: room }.to_json + ") } else if(window.__ruby_send_obj){ window.__ruby_send_obj(" + { cmd: "join", room: room }.to_json + ") }")
    # flush any local candidates
    begin
      cand = local_pending_candidates.shift
      while cand
        JS.eval("if(window.RubyRTC&&window.RubyRTC.send){ window.RubyRTC.send.candidate(" + cand.to_json + ", " + room.to_json + ") } else if(window.__ruby_send_candidate){ window.__ruby_send_candidate(" + cand.to_json + ", " + room.to_json + ") }")
        cand = local_pending_candidates.shift
      end
    rescue => e
      puts "[ruby] flush local cand warn: #{e}"
    end
    # Attach PC handlers now that signaling is ready
    attach_pc_handlers.call
  end

  # If WS exists and we (re)open it, flush any queued sends then bind handler
  JS.eval(
    "(function(){\n" +
    "  // Robust ensureWs(): create WS if missing/closed, wire handler, flush queue, and call RubyOnWsOpen\n" +
    "  if(!window.__ruby_ensure_ws){ window.__ruby_ensure_ws = function(){ try{ var w=window.__ruby_ws; if(!w || w.readyState===3){ var proto=(location.protocol==='https:')?'wss:':'ws:'; var url=proto+'//'+location.host+'/ws'; w=new WebSocket(url); window.__ruby_ws=w; w.onopen=function(){ try{ if(window.__ruby_ws_handler){ w.onmessage = window.__ruby_ws_handler; } }catch(_){1} try{ if(Array.isArray(window.__ruby_ws_queue)){ var q=window.__ruby_ws_queue.splice(0); for(var i=0;i<q.length;i++){ try{ q[i](w); }catch(_){} } } }catch(_){} try{ RubyOnWsOpen(); }catch(_){} }; } else { try{ if(window.__ruby_ws_handler){ w.onmessage = window.__ruby_ws_handler; } }catch(_){1} } return w; }catch(_){ return null; } }; }\n" +
    "  // If WS already open when handler is defined, bind and flush queued sends\n" +
    "  try{ var w=window.__ruby_ws; if(w && w.readyState===1){ if(window.__ruby_ws_handler){ w.onmessage = window.__ruby_ws_handler; } if(Array.isArray(window.__ruby_ws_queue) && window.__ruby_ws_queue.length){ var q=window.__ruby_ws_queue.splice(0); for(var i=0;i<q.length;i++){ try{ q[i](w); }catch(_){} } } } }catch(_){1}}\n" +
    ")();"
  )
  # Re-introduce RubyRTC.send namespace and unified message path (DC first, WS fallback)
  JS.eval(
    "(function(){\n" +
    "  if(!window.RubyRTC) window.RubyRTC = {};\n" +
    "  var S = window.RubyRTC.send || (window.RubyRTC.send = {});\n" +
    "  // Delegate to existing low-level helpers (defined above)\n" +
    "  S.obj = function(o){ try{ if(window.__ruby_send_obj) window.__ruby_send_obj(o); }catch(_){} };\n" +
    "  S.offer = function(off, room){ try{ if(window.__ruby_send_offer) window.__ruby_send_offer(off, room); }catch(_){} };\n" +
    "  S.answer = function(ans, room){ try{ if(window.__ruby_send_answer) window.__ruby_send_answer(ans, room); }catch(_){} };\n" +
    "  S.candidate = function(cand, room){ try{ if(window.__ruby_send_candidate) window.__ruby_send_candidate(cand, room); }catch(_){} };\n" +
    "  S.chat = function(room, text){ try{ if(window.__ruby_send_chat) window.__ruby_send_chat(room, text); }catch(_){} };\n" +
    "  // Unified sender: prefer DataChannel when open; otherwise use WS chat\n" +
    "  S.message = function(room, text){\n" +
    "    try{ var v = (text==null? '': String(text));\n" +
    "      if (window.__ruby_force_ws){ try{ S.chat(room, v); return; }catch(_){} }\n" +
    "      var ch = window.__ruby_dc;\n" +
    "      if (ch && ch.readyState === 'open') { try{ ch.send(v); }catch(_){} }\n" +
    "      else { try{ S.chat(room, v); }catch(_){} }\n" +
    "    }catch(_){1}\n" +
    "  };\n" +
    "})();"
  )

  # Wire WS events via JS property assignment, invoking Ruby procs.
  JS.global[:RubyOnWsClose] = proc do
    set_status("signaling closed")
  end

  JS.global[:RubyOnWsError] = proc do
    set_status("signaling error (see console)")
  end

  # Assign handlers in JS
  JS.eval(
    "try{\n" +
    "  var w=window.__ruby_ws;\n" +
    "  if(w){ w.onclose = function(){ RubyOnWsClose(); }; }\n" +
    "  if(w){ w.onerror = function(){ RubyOnWsError(); }; }\n" +
    "}\n" +
    "catch(e){}"
  )

  # Callback invoked from JS after offer is sent.
  JS.global[:RubyOnOfferSent] = proc do
    set_status("sent offer (waiting for answer)")
  end

  # --- Chat form handler -----------------------------------------------------
  # We keep all DOM reads/sends in JS for reliability across the Ruby<->JS bridge.
  # Sending prefers DataChannel when open, otherwise falls back to WebSocket chat.
  JS.global[:RubyOnChatSubmit] = proc do
    # Do everything in JS to guarantee correct string coercion and avoid 'undefined'
    JS.eval(
      "(function(){\n" +
      "  var m = document.getElementById('msg');\n" +
      "  var v = m ? m.value : '';\n" +
      "  if (typeof v === 'undefined' || v === null) v = '';\n" +
      "  v = String(v).trim();\n" +
      "  if (!v) return;\n" +
      "  try{ if(window.RubyRTC && window.RubyRTC.send && typeof window.RubyRTC.send.message==='function'){ window.RubyRTC.send.message(" + room.to_json + ", v); } }catch(_){}\n" +
      "  try { var log=document.getElementById('log'); if(log){ var d=document.createElement('div'); d.className='me'; d.textContent='Me: ' + v; log.appendChild(d); log.scrollTop=log.scrollHeight; } } catch(_) {}\n" +
      "  try { if (m) m.value = ''; } catch(_) {}\n" +
      "})();"
    )
  end
  JS.eval("try{var f=document.getElementById('chatForm'); if(f){ f.addEventListener('submit', function(ev){ ev.preventDefault(); RubyOnChatSubmit(); }); }}catch(e){}")

  JS.eval(<<~JS)
  (function(){
    function setStatus(t){ var el=document.getElementById('status'); if(el) el.innerHTML='status: <em>'+t+'</em>'; }
    function appendPeer(t){ var log=document.getElementById('log'); if(!log) return; var d=document.createElement('div'); d.className='peer'; d.textContent=t; log.appendChild(d); log.scrollTop=log.scrollHeight; }
    function enableSend(b){ var s=document.getElementById('sendBtn'); var m=document.getElementById('msg'); if(s) s.disabled=!b; if(m) m.disabled=!b; }
    function setTransportLabel(t){ var el=document.getElementById('transport'); if(!el) return; el.textContent=t; el.style.background = (t==='webrtc')? '#e8ffe8':'#ffe8e8'; el.style.color = (t==='webrtc')? '#174':'#711'; }

    var __ruby_transport = 'webrtc';
    var __ruby_connect_timer = null;
    function updateTransport(){ setTransportLabel(__ruby_transport); }
    function clearConnectTimer(){ try{ if(__ruby_connect_timer){ clearTimeout(__ruby_connect_timer); __ruby_connect_timer=null; } }catch(_){} }
    function armConnectTimeout(ms){ clearConnectTimer(); __ruby_connect_timer = setTimeout(function(){ useWsFallback('timeout'); }, (ms||8000)); }

    // WS ensure + queue flush
    window.__ruby_ws_queue = window.__ruby_ws_queue || [];
    window.__ruby_ensure_ws = window.__ruby_ensure_ws || function(){
      try{
        var w=window.__ruby_ws;
        if(!w || w.readyState===3){
          var proto=(location.protocol==='https:')?'wss:':'ws:';
          var url=proto+'//'+location.host+'/ws';
          w=new WebSocket(url);
          window.__ruby_ws=w;
          w.onopen=function(){
            try{ if(window.__ruby_ws_handler){ w.onmessage = window.__ruby_ws_handler; } }catch(_){}
            try{
              var q = Array.isArray(window.__ruby_ws_queue)? window.__ruby_ws_queue.splice(0): [];
              for(var i=0;i<q.length;i++){ try{ q[i](w); }catch(_){} }
            }catch(_){}
            try{ RubyOnWsOpen(); }catch(_){}
          };
        } else {
          try{ if(window.__ruby_ws_handler){ w.onmessage = window.__ruby_ws_handler; } }catch(_){}
        }
        return w;
      }catch(_){ return null; }
    };

    function useWsFallback(reason){
      if(__ruby_transport==='ws') return;
      __ruby_transport='ws';
      window.__ruby_force_ws = true;
      try{ if(window.__ruby_dc){ window.__ruby_dc.close(); } }catch(_){}
      try{ if(window.__ruby_pc){ window.__ruby_pc.close(); } }catch(_){}
      setStatus('fallback to websocket' + (reason? ' ('+reason+')':''));
      enableSend(true);
      updateTransport();
      window.__ruby_ensure_ws();
    }

    function renderMsg(e){
      try{
        var v = (e && typeof e === 'object' && 'data' in e) ? e.data : e;
        if (typeof v === 'string') return v;
        if (v && typeof Blob !== 'undefined' && v instanceof Blob){
          var fr = new FileReader();
          fr.onload = function(){ appendPeer('Peer: ' + (fr.result!=null? String(fr.result): '')); };
          try{ fr.readAsText(v); }catch(_){}
          return null;
        }
        if (v && (v.byteLength !== undefined || (v.buffer && v.buffer.byteLength !== undefined))){
          try{ var dec = new TextDecoder(); return dec.decode(v.byteLength !== undefined ? v : v.buffer); }catch(_){}
        }
        return (v==null) ? '' : String(v);
      }catch(_){ return ''; }
    }

    function wireChannel(){
      var ch=window.__ruby_dc; if(!ch) return;
      ch.onopen=function(){ __ruby_transport='webrtc'; updateTransport(); setStatus('connected'); enableSend(true); clearConnectTimer(); };
      ch.onmessage=function(e){ try{ var v=renderMsg(e); if(v!=null){ appendPeer('Peer: '+v); } }catch(_){ appendPeer('Peer: '); } };
      ch.onclose=function(){ if(__ruby_transport==='webrtc'){ setStatus('disconnected'); enableSend(false); } };
    }

    function wirePc(){
      var p=window.__ruby_pc; if(!p) return;
      p.onicecandidate = function(ev){ try{ if(ev && ev.candidate){ RubyOnIceCandidate(ev.candidate); } }catch(e){} };
      p.ondatachannel=function(ev){ try{ window.__ruby_dc = ev.channel; wireChannel(); }catch(e){} };
      p.oniceconnectionstatechange=function(){ try{ var s=p.iceConnectionState; if(s==='failed'){ useWsFallback('ice failed'); } if(s==='connected'||s==='completed'){ setStatus('connected'); } }catch(e){} };
      updateTransport();
    }

    if(!window.RubyRTC) window.RubyRTC = {};
    window.RubyRTC.ui = window.RubyRTC.ui || {};
    window.RubyRTC.util = window.RubyRTC.util || {};
    window.RubyRTC.wirePc = wirePc;
    window.RubyRTC.wireChannel = wireChannel;
    window.RubyRTC.ui.setStatus = setStatus;
    window.RubyRTC.ui.appendPeer = appendPeer;
    window.RubyRTC.ui.append = function(kind, text){ var log=document.getElementById('log'); if(!log) return; var d=document.createElement('div'); d.className=String(kind||''); d.textContent=String(text==null?'':text); log.appendChild(d); log.scrollTop=log.scrollHeight; };
    window.RubyRTC.ui.enableSend = enableSend;
    window.RubyRTC.util.renderMsg = renderMsg;

    window.__ruby_remote_set = false;
    window.__ruby_pending = [];

    window.__ruby_ws_handler = async function(evt){
      var msg={}; try{ msg=JSON.parse(evt.data); }catch(e){};
      var p = window.__ruby_pc;
      if(msg.type==='chat'){
        try{
          var v = (msg && ('text' in msg)) ? msg.text : '';
          if (typeof v === 'undefined' || v === null) v = '';
          var text = (typeof v === 'string') ? v : String(v);
          appendPeer('Peer: ' + text);
        }catch(_){ appendPeer('Peer: '); }
        return;
      }
      if(msg.type==='peers'){ if((msg.count||0)>1){ setStatus('peer present (waiting for new_peer to initiate)'); } else { setStatus('waiting for peer'); } return; }
      if(msg.type==='new_peer'){
        if(!window.__ruby_offer_started){
          try{
            window.__ruby_offer_started=true;
            if(!p){
              console.warn('[webrtc] no pc (creating)');
              try{ window.__ruby_pc = p = window.__ruby_build_pc(); if(!p){ console.error('[webrtc] build pc returned null'); return; } wirePc(); }catch(e){ console.error('[webrtc] create pc on-demand failed', e); return; }
            }
            window.__ruby_dc=p.createDataChannel('chat'); wireChannel();
            var off=await p.createOffer(); await p.setLocalDescription(off);
            window.__ruby_send_offer(off, #{room.to_json});
            armConnectTimeout(8000);
          }catch(e){ console.error('[webrtc] offer error', e); }
        }
        return;
      }
      if(msg.type==='offer'){
        try{
          if(!p){
            console.warn('[webrtc] no pc (creating)');
            try{ window.__ruby_pc = p = window.__ruby_build_pc(); if(!p){ console.error('[webrtc] build pc returned null'); return; } wirePc(); }catch(e){ console.error('[webrtc] create pc on-demand failed', e); return; }
          }
          await p.setRemoteDescription(typeof msg.sdp==='string'? {type:'offer', sdp:msg.sdp}: msg.sdp);
          window.__ruby_remote_set=true;
          while(window.__ruby_pending.length){ try{ await p.addIceCandidate(window.__ruby_pending.shift()); }catch(e){ console.error('drain cand', e); } }
          var ans=await p.createAnswer(); await p.setLocalDescription(ans);
          window.__ruby_send_answer(ans, #{room.to_json});
          setStatus('sent answer');
          armConnectTimeout(8000);
        }catch(e){ console.error('[webrtc] answer error', e); }
        return;
      }
      if(msg.type==='answer'){
        try{
          if(!p){
            console.warn('[webrtc] no pc (creating)');
            try{ window.__ruby_pc = p = window.__ruby_build_pc(); if(!p){ console.error('[webrtc] build pc returned null'); return; } wirePc(); }catch(e){ console.error('[webrtc] create pc on-demand failed', e); return; }
          }
          await p.setRemoteDescription(typeof msg.sdp==='string'? {type:'answer', sdp:msg.sdp}: msg.sdp);
          window.__ruby_remote_set=true;
          while(window.__ruby_pending.length){ try{ await p.addIceCandidate(window.__ruby_pending.shift()); }catch(e){ console.error('drain cand', e); } }
          setStatus('got answer (establishing)');
        }catch(e){ console.error('[webrtc] setRemote ans error', e); }
        return;
      }
      if(msg.type==='candidate'){
        try{
          if(!msg.candidate || !msg.candidate.candidate){ return; }
          if(!p){
            console.warn('[webrtc] no pc (creating)');
            try{ window.__ruby_pc = p = window.__ruby_build_pc(); if(!p){ console.error('[webrtc] build pc returned null'); return; } wirePc(); }catch(e){ console.error('[webrtc] create pc on-demand failed', e); return; }
          }
          if(!window.__ruby_remote_set){ window.__ruby_pending.push(msg.candidate); }
          else { await p.addIceCandidate(msg.candidate); }
        }catch(e){ console.error('[webrtc] addIce error', e); }
        return;
      }
    };

    try{ var w=window.__ruby_ws; if(w && w.readyState===1 && window.__ruby_ws_handler){ w.onmessage = window.__ruby_ws_handler; } }catch(e){}
  })();
JS


  # Ensure room is available to JS without relying on Ruby interpolation later.
  JS.eval("try{ window.__ruby_room = " + room.to_json + "; }catch(e){}")

  # Reintroduce a safe PC builder accessible as window.__ruby_build_pc (used by ws handler)
  JS.eval(
    "(function(){\n" +
    "  if(!window.__ruby_build_pc){\n" +
    "    window.__ruby_build_pc = function(){\n" +
    "      try{\n" +
    "        var out = { iceServers: [{ urls: 'stun:stun.l.google.com:19302' }] };\n" +
    "        try{\n" +
    "          var cfg = window.__ruby_pc_cfg;\n" +
    "          if(cfg && cfg.iceServers && Array.isArray(cfg.iceServers)){\n" +
    "            for(var i=0;i<cfg.iceServers.length;i++){\n" +
    "              var s = cfg.iceServers[i]; if(!s) continue; var u = s.urls;\n" +
    "              if(typeof u==='string' && /^(stun|turn):/i.test(u)){\n" +
    "                var entry = { urls: u };\n" +
    "                if(/^turn:/i.test(u)){\n" +
    "                  if(typeof s.username==='string' && s.username && typeof s.credential==='string' && s.credential){\n" +
    "                    entry.username = s.username; entry.credential = s.credential;\n" +
    "                  } else { continue; }\n" +
    "                }\n" +
    "                out.iceServers.push(entry);\n" +
    "              }\n" +
    "            }\n" +
    "          }\n" +
    "        }catch(_){ }\n" +
    "        return new RTCPeerConnection(out);\n" +
    "      }catch(e){\n" +
    "        try{ return new RTCPeerConnection({ iceServers: [{ urls: 'stun:stun.l.google.com:19302' }] }); }catch(e2){ console.error('[webrtc] build pc failed', e2); return null; }\n" +
    "      }\n" +
    "    };\n" +
    "  }\n" +
    "})();"
  )

  # Deterministic WS fallback on RTCPeerConnection failure/disconnect
  JS.eval(<<~JS)
  (function(){
    try{
      var p = window.__ruby_pc;
      if (!p) return;
      var flipped = false;
      function forceWs(reason){
        if (flipped) return; flipped = true;
        try{ if(window.__ruby_dc){ try{ window.__ruby_dc.close(); }catch(_){} } }catch(_){ }
        try{ if(window.__ruby_pc){ try{ window.__ruby_pc.close(); }catch(_){} } }catch(_){ }
        try{ window.__ruby_force_ws = true; }catch(_){ }
        try{ if(typeof window.__ruby_ensure_ws==='function'){ window.__ruby_ensure_ws(); } }catch(_){ }
        try{
          var el = document.getElementById('transport'); if(el){ el.textContent='ws'; el.style.background='#ffe8e8'; el.style.color='#711'; }
          var s=document.getElementById('sendBtn'); var m=document.getElementById('msg'); if(s) s.disabled=false; if(m) m.disabled=false;
          var status=document.getElementById('status'); if(status) status.innerHTML='status: <em>fallback to websocket' + (reason? ' ('+reason+')':'' ) + '</em>';
        }catch(_){ }
      }
      p.onconnectionstatechange = function(){
        try{
          var st = p.connectionState;
          if (st==='failed' || st==='disconnected' || st==='closed') { setTimeout(function(){ forceWs(st); }, 800); }
        }catch(_){ }
      };
    }catch(_){ }
  })();
  //# sourceURL=rtc_fallback_hook.js
  JS


rescue => e
  # Surface full backtrace to console and status/log so the user can diagnose issues.
  msg = e.full_message(highlight: false)
  puts msg
  JS.global[:console][:error].call("[ruby] unhandled error", msg)
  begin
    el = JS.eval("document.getElementById('status')")
    el[:innerHTML] = "status: <em>ruby error</em>"
    log = JS.eval("document.getElementById('log')")
    pre = JS.eval("document.createElement('pre')")
    pre[:textContent] = msg
    log[:appendChild].call(pre)
  rescue
    # ignore secondary failures
  end
end