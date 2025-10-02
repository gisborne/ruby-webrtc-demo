# public/ruby/app.rb
# Ruby-in-the-browser client with WebRTC DataChannel (mirrors public/app.js)
# - Reads room from URL hash/prompt
# - Connects to signaling WebSocket
# - Sets up RTCPeerConnection with STUN (+ optional TURN via URL params)
# - Handles offer/answer/candidates + DataChannel
# - Leaves WS chat handler in place for compatibility

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
    html = "status: <em>Ruby: #{text}</em>"
    JS.eval("var e=document.getElementById('status'); if(e){ e.innerHTML = #{html.to_json} }")
  end

  def append(kind, text)
    # Use pure JS to avoid Ruby->JS property writes on host objects
    JS.eval(
      "(function(){\n" +
      "  try{ var log=document.getElementById('log'); if(!log) return;\n" +
      "    var d=document.createElement('div'); d.className=" + kind.to_json + "; d.textContent=" + text.to_json + ";\n" +
      "    log.appendChild(d); log.scrollTop=log.scrollHeight; }catch(e){}\n" +
      "})();"
    )
  end

  # Room selection (defensive: avoid prompt() to prevent JS bridge errors)
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

  # UI elements
  checkpoint "ui-ok"
  send_btn = dom_by_id("sendBtn")
  msg_input = dom_by_id("msg")
  JS.eval("var t=document.getElementById('transport'); if(t){ t.textContent='ruby+webrtc'; t.style.background='#e8ffe8'; t.style.color='#174'; }")

  set_status("initializing…")
  puts "[ruby] after UI setup"
  checkpoint "after-ui-setup"

  # Build ICE servers from URL params (supports TURN)
  checkpoint "before-params"
  turn_url  = JS.eval("new URLSearchParams(location.search).get('turn')")
  turn_user = JS.eval("new URLSearchParams(location.search).get('turnUser')")
  turn_pass = JS.eval("new URLSearchParams(location.search).get('turnPass')")
  checkpoint "after-params"

  # Coerce to plain Ruby strings (avoid JS handles leaking into to_json)
  tu  = turn_url.nil?  ? nil : turn_url.to_s
  tus = (tu && tu.strip != "") ? tu : nil
  uu  = turn_user.nil? ? nil : turn_user.to_s
  uus = (uu && uu.strip != "") ? uu : nil
  pu  = turn_pass.nil? ? nil : turn_pass.to_s
  pus = (pu && pu.strip != "") ? pu : nil
  checkpoint "after-coerce"

  # Build full JS config string to avoid any Ruby->JS property sets
  js_pc_cfg = if tus && uus && pus
    "({ iceServers: [ { urls: 'stun:stun.l.google.com:19302' }, { urls: #{tus.to_json}, username: #{uus.to_json}, credential: #{pus.to_json} } ] })"
  else
    "({ iceServers: [ { urls: 'stun:stun.l.google.com:19302' } ] })"
  end
  checkpoint "built-config"
  # Stash config for later on-demand PC creation from JS
  JS.eval("try{ window.__ruby_pc_cfg = " + js_pc_cfg + "; }catch(e){}");
  # Provide a safe builder that filters invalid iceServers and always falls back to STUN
  JS.eval(
    "(function(){\n" +
    "  window.__ruby_build_pc = function(){\n" +
    "    // Build a minimal, sanitized config to avoid 'undefined URL' issues\n" +
    "    try{\n" +
    "      var out = { iceServers: [{ urls: 'stun:stun.l.google.com:19302' }] };\n" +
    "      // Optionally merge a single TURN server if present and valid in cfg\n" +
    "      try{\n" +
    "        var cfg = window.__ruby_pc_cfg;\n" +
    "        if(cfg && typeof cfg === 'object' && Array.isArray(cfg.iceServers)){\n" +
    "          for(var i=0;i<cfg.iceServers.length;i++){\n" +
    "            var s = cfg.iceServers[i];\n" +
    "            if(!s) continue;\n" +
    "            var u = s.urls;\n" +
    "            if(typeof u === 'string' && u && /^(stun|turn):/i.test(u)){\n" +
    "              var entry = { urls: u };\n" +
    "              if(/^turn:/i.test(u)){\n" +
    "                if(typeof s.username === 'string' && s.username && typeof s.credential === 'string' && s.credential){\n" +
    "                  entry.username = s.username; entry.credential = s.credential;\n" +
    "                } else { continue; }\n" +
    "              }\n" +
    "              out.iceServers.push(entry);\n" +
    "            }\n" +
    "          }\n" +
    "        }\n" +
    "      }catch(e){}\n" +
    "      return new RTCPeerConnection(out);\n" +
    "    }catch(e){\n" +
    "      console.error('[webrtc] build pc failed, using fallback', e);\n" +
    "      try { return new RTCPeerConnection({ iceServers: [{ urls: 'stun:stun.l.google.com:19302' }] }); } catch(e2){ console.error('[webrtc] fallback RTCPeerConnection failed', e2); return null; }\n" +
    "    }\n" +
    "  };\n" +
    "})();"
  )
  # Create RTCPeerConnection
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

  dc = nil
  is_caller = false
  remote_set = false
  pending_candidates = []
  local_pending_candidates = []
  ws_ready = false

  # Ruby callbacks invoked by JS-side DataChannel handlers
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

  # PC handlers via JS on* with Ruby callbacks (no addEventListener)
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

  # WebSocket signaling
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

  # After ws is created: use JS-side setTimeout to avoid Ruby->JS function calls
  JS.global[:RubyWsTimeoutCheck] = proc do
    ready = ws[:readyState].to_i rescue -1
    unless ready == 1 # OPEN
      puts "[ruby] WS not open after 3s, readyState=#{ready}"
      set_status("still initializing… (waiting for signaling)")
    end
  end
  JS.eval("try{ setTimeout(function(){ RubyWsTimeoutCheck(); }, 3000); }catch(e){}")

  # Define a reusable JS onmessage handler and bind it when WS opens
  JS.eval(
    "(function(){\n" +
    "  function setStatus(t){ var el=document.getElementById('status'); if(el) el.innerHTML='status: <em>'+t+'</em>'; }\n" +
    "  function appendPeer(t){ var log=document.getElementById('log'); if(!log) return; var d=document.createElement('div'); d.className='peer'; d.textContent=t; log.appendChild(d); log.scrollTop=log.scrollHeight; }\n" +
    "  function enableSend(b){ var s=document.getElementById('sendBtn'); var m=document.getElementById('msg'); if(s) s.disabled=!b; if(m) m.disabled=!b; }\n" +
    "  function renderMsg(e){\n" +
    "    try{\n" +
    "      var v = (e && typeof e === 'object' && 'data' in e) ? e.data : e;\n" +
    "      if (typeof v === 'string') return v;\n" +
    "      if (v && typeof Blob !== 'undefined' && v instanceof Blob){\n" +
    "        var fr = new FileReader();\n" +
    "        fr.onload = function(){ appendPeer('Peer: ' + (fr.result!=null? String(fr.result): '')); };\n" +
    "        try{ fr.readAsText(v); }catch(_){}\n" +
    "        return null;\n" +
    "      }\n" +
    "      if (v && (v.byteLength !== undefined || (v.buffer && v.buffer.byteLength !== undefined))){\n" +
    "        try{ var dec = new TextDecoder(); return dec.decode(v.byteLength !== undefined ? v : v.buffer); }catch(_){}\n" +
    "      }\n" +
    "      return (v==null) ? '' : String(v);\n" +
    "    }catch(_){ return ''; }\n" +
    "  }\n" +
    "  function wireChannel(){ var ch=window.__ruby_dc; if(!ch) return; ch.onopen=function(){ setStatus('connected'); enableSend(true); }; ch.onmessage=function(e2){ try{ var v=renderMsg(e2); if(v!=null){ appendPeer('Peer: '+v); } }catch(_){ appendPeer('Peer: '); } }; ch.onclose=function(){ setStatus('disconnected'); enableSend(false); }; }\n" +
    "  function wirePc(){ var p=window.__ruby_pc; if(!p) return; p.onicecandidate = function(ev){ try{ if(ev && ev.candidate){ RubyOnIceCandidate(ev.candidate); } }catch(e){} }; p.ondatachannel=function(ev){ try{ window.__ruby_dc = ev.channel; wireChannel(); }catch(e){} }; p.oniceconnectionstatechange=function(){ try{ RubyOnIceState(p.iceConnectionState); }catch(e){} }; }\n" +
    "  window.__ruby_remote_set = false;\n" +
    "  window.__ruby_pending = [];\n" +
    "  window.__ruby_ws_handler = async function(evt){\n" +
    "    var msg={}; try{ msg=JSON.parse(evt.data); }catch(e){};\n" +
    "    var p = window.__ruby_pc;\n" +
    "    if(msg.type==='chat'){\n" +
    "      try{\n" +
    "        var v = (msg && ('text' in msg)) ? msg.text : '';\n" +
    "        if (typeof v === 'undefined' || v === null) v = '';\n" +
    "        var text = (typeof v === 'string') ? v : String(v);\n" +
    "        appendPeer('Peer: ' + text);\n" +
    "      }catch(_){ appendPeer('Peer: '); }\n" +
    "      return;\n" +
    "    }\n" +
    "    if(msg.type==='peers'){ if((msg.count||0)>1){ setStatus('peer present (waiting for new_peer to initiate)'); } else { setStatus('waiting for peer'); } return; }\n" +
    "    if(msg.type==='new_peer'){ if(!window.__ruby_offer_started){ try{ window.__ruby_offer_started=true; if(!p){ console.warn('[webrtc] no pc (creating)'); try{ window.__ruby_pc = p = window.__ruby_build_pc(); if(!p){ console.error('[webrtc] build pc returned null'); return; } wirePc(); }catch(e){ console.error('[webrtc] create pc on-demand failed', e); return; } } window.__ruby_dc=p.createDataChannel('chat'); wireChannel(); console.log('[webrtc] creating offer (new_peer)'); var off=await p.createOffer(); await p.setLocalDescription(off); console.log('[ws] sending offer'); window.__ruby_send_offer(off, " + room.to_json + "); }catch(e){ console.error('[webrtc] offer error', e); } } return; }\n" +
    "    if(msg.type==='offer'){ try{ if(!p){ console.warn('[webrtc] no pc (creating)'); try{ window.__ruby_pc = p = window.__ruby_build_pc(); if(!p){ console.error('[webrtc] build pc returned null'); return; } wirePc(); }catch(e){ console.error('[webrtc] create pc on-demand failed', e); return; } } console.log('[webrtc] setRemoteDescription offer'); await p.setRemoteDescription(typeof msg.sdp==='string'? {type:'offer', sdp:msg.sdp}: msg.sdp); window.__ruby_remote_set=true; while(window.__ruby_pending.length){ try{ await p.addIceCandidate(window.__ruby_pending.shift()); }catch(e){ console.error('drain cand', e); } } var ans=await p.createAnswer(); await p.setLocalDescription(ans); console.log('[ws] sending answer'); window.__ruby_send_answer(ans, " + room.to_json + "); setStatus('sent answer'); }catch(e){ console.error('[webrtc] answer error', e); } return; }\n" +
    "    if(msg.type==='answer'){ try{ if(!p){ console.warn('[webrtc] no pc (creating)'); try{ window.__ruby_pc = p = window.__ruby_build_pc(); if(!p){ console.error('[webrtc] build pc returned null'); return; } wirePc(); }catch(e){ console.error('[webrtc] create pc on-demand failed', e); return; } } console.log('[webrtc] setRemoteDescription answer'); await p.setRemoteDescription(typeof msg.sdp==='string'? {type:'answer', sdp:msg.sdp}: msg.sdp); window.__ruby_remote_set=true; while(window.__ruby_pending.length){ try{ await p.addIceCandidate(window.__ruby_pending.shift()); }catch(e){ console.error('drain cand', e); } } setStatus('got answer (establishing)'); }catch(e){ console.error('[webrtc] setRemote ans error', e); } return; }\n" +
    "    if(msg.type==='candidate'){ try{ if(!msg.candidate || !msg.candidate.candidate){ console.log('[webrtc] ignore bad candidate', msg && msg.candidate); return; } if(!p){ console.warn('[webrtc] no pc (creating)'); try{ window.__ruby_pc = p = window.__ruby_build_pc(); if(!p){ console.error('[webrtc] build pc returned null'); return; } wirePc(); }catch(e){ console.error('[webrtc] create pc on-demand failed', e); return; } } console.log('[webrtc] addIce', msg.candidate && msg.candidate.candidate); if(!window.__ruby_remote_set){ window.__ruby_pending.push(msg.candidate); } else { await p.addIceCandidate(msg.candidate); } }catch(e){ console.error('[webrtc] addIce error', e); } return; }\n" +
    "  };\n" +
    "  // If WS already open when handler is defined, bind now\n" +
    "  try{ var w=window.__ruby_ws; if(w && w.readyState===1 && window.__ruby_ws_handler){ w.onmessage = window.__ruby_ws_handler; console.log('[ws] onmessage bound (post-define)'); } }catch(e){}\n" +
    "})();"
  )

  # Step 1: Minimal namespacing – unify send path behind RubyRTC.send.message
  JS.eval(
    "(function(){\n" +
    "  if(!window.RubyRTC) window.RubyRTC = {};\n" +
    "  var S = window.RubyRTC.send || (window.RubyRTC.send = {});\n" +
    "  S.message = function(room, text){\n" +
    "    try{\n" +
    "      var v = (text==null? '': String(text));\n" +
    "      var ch = window.__ruby_dc;\n" +
    "      if (ch && ch.readyState === 'open') { try{ ch.send(v); }catch(_){} }\n" +
    "      else { try{ if(window.__ruby_send_chat){ window.__ruby_send_chat(room, v); } }catch(_){} }\n" +
    "    }catch(_){}\n" +
    "  };\n" +
    "})();"
  )

  # JS helpers for signaling sends
  JS.eval(
    "(function(){\n" +
    "  window.__ruby_send_obj = function(o){ try{ if(window.__ruby_ws){ window.__ruby_ws.send(JSON.stringify(o)); } }catch(e){} };\n" +
    "  window.__ruby_send_offer = function(off, room){ try{ if(window.__ruby_ws){ var payload = { room: room, type: 'offer', sdp: off }; window.__ruby_ws.send(JSON.stringify(payload)); } }catch(e){} };\n" +
    "  window.__ruby_send_answer = function(ans, room){ try{ if(window.__ruby_ws){ var payload = { room: room, type: 'answer', sdp: ans }; window.__ruby_ws.send(JSON.stringify(payload)); } }catch(e){} };\n" +
    "  window.__ruby_send_candidate = function(cand, room){ try{ if(window.__ruby_ws){ window.__ruby_ws.send(JSON.stringify({ room: room, type: 'candidate', candidate: cand })); } }catch(e){} };\n" +
    "  window.__ruby_send_chat = function(room, text){ try{ if(window.__ruby_ws){ window.__ruby_ws.send(JSON.stringify({ room: room, type: 'chat', text: text })); } }catch(e){} };\n" +
    "})();"
  )

  # Wire WS events via JS property assignment, invoking Ruby procs
  JS.global[:RubyOnWsOpen] = proc do
    set_status("signaling open")
    JS.eval("console.log('[ws] onopen -> sending join')")
    ws_ready = true
    # Send join with primitives via JS-side stringify
    JS.eval("window.__ruby_send_obj(" + { cmd: "join", room: room }.to_json + ")")
    # flush any local candidates
    begin
      cand = local_pending_candidates.shift
      while cand
        JS.eval("console.log('[ws] sending cand')")
        JS.eval("window.__ruby_send_candidate(" + cand.to_json + ", " + room.to_json + ")")
        cand = local_pending_candidates.shift
      end
    rescue => e
      puts "[ruby] flush local cand warn: #{e.to_s}"
    end
    # Attach PC handlers now that signaling is ready
    attach_pc_handlers.call
  end

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

  # Callback invoked from JS after offer is sent
  JS.global[:RubyOnOfferSent] = proc do
    set_status("sent offer (waiting for answer)")
  end

  # Chat form handler: bind via JS to avoid Ruby-side addEventListener
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

rescue => e
  # Surface full backtrace to console and status/log
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