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
# WebSocket fallback overview (quick alternative to TURN)
# - Preferred transport is WebRTC DataChannel. When the RTCPeerConnection
#   fails/disconnects/closes (or ICE fails), we flip to WS by:
#   1) setting window.__ruby_force_ws = true
#   2) closing DC/PC and calling window.__ruby_ensure_ws()
#   3) updating the UI transport badge and enabling input
# - In fallback, chat is relayed via the signaling server at /ws (see config.ru),
#   sending { room, type: 'chat', text } and broadcasting to the other peer in the same room (1:1).
# - This is a pragmatic safety net. In production, prefer a properly configured TURN
#   server to achieve P2P connectivity; keep WS only for control/text as last resort.

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