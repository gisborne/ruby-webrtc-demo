// --- Simple room selection via URL hash or prompt ---
const room = (location.hash && location.hash.slice(1)) || prompt("Room name?", "demo") || "demo";
document.getElementById("roomName").textContent = room;
if (!location.hash) location.hash = "#" + room;

// --- WebSocket for signaling ---
const wsProtocol = (location.protocol === "https:") ? "wss:" : "ws:";
const ws = new WebSocket(`${wsProtocol}//${location.host}/ws`);

// --- WebRTC setup ---
const params = new URLSearchParams(location.search);
const forceWs = params.get("transport") === "ws"; // force WS-only mode
const iceServers = [{ urls: "stun:stun.l.google.com:19302" }];
const turnUrl = params.get("turn");
const turnUser = params.get("turnUser");
const turnPass = params.get("turnPass");
const forceRelay = params.get("forceRelay") === "1"; // TURN-only when set
if (turnUrl && turnUser && turnPass) {
  iceServers.push({ urls: turnUrl, username: turnUser, credential: turnPass });
}
const pc = new RTCPeerConnection({
  iceServers,
  iceTransportPolicy: forceRelay ? "relay" : "all",
});

let dc;           // RTCDataChannel
let isCaller = false;
let remoteSet = false;
const pendingCandidates = [];
let transport = forceWs ? "ws" : "webrtc"; // current transport
let connectTimer = null;
const transportEl = document.getElementById("transport");
function updateTransport() {
  if (!transportEl) return;
  transportEl.textContent = transport;
  transportEl.style.background = transport === "webrtc" ? "#e8ffe8" : "#ffe8e8";
  transportEl.style.color = transport === "webrtc" ? "#174" : "#711";
}
updateTransport();

const log = document.getElementById("log");
const statusEl = document.getElementById("status");
const sendBtn = document.getElementById("sendBtn");
const msgInput = document.getElementById("msg");

function append(kind, text) {
  const p = document.createElement("div");
  p.className = kind;
  p.textContent = text;
  log.appendChild(p);
  log.scrollTop = log.scrollHeight;
}

function setStatus(text) {
  statusEl.innerHTML = "status: <em>" + text + "</em>";
}

function enableSend(enabled) {
  sendBtn.disabled = !enabled;
  msgInput.disabled = !enabled;
}

function useWsFallback(reason = "") {
  if (transport === "ws") return;
  transport = "ws";
  try { dc && dc.close && dc.close(); } catch {}
  try { pc && pc.close && pc.close(); } catch {}
  if (connectTimer) { clearTimeout(connectTimer); connectTimer = null; }
  setStatus("fallback to websocket" + (reason ? ` (${reason})` : ""));
  enableSend(true);
  updateTransport();
}

function armConnectTimeout(ms = 8000) {
  if (connectTimer) clearTimeout(connectTimer);
  connectTimer = setTimeout(() => useWsFallback("timeout"), ms);
}

// ICE -> signal to peer
pc.onicecandidate = (event) => {
  if (event.candidate) {
    console.log("local ICE candidate:", event.candidate.type, event.candidate.protocol, event.candidate.address, event.candidate.port);
    ws.send(JSON.stringify({
      room,
      type: "candidate",
      candidate: event.candidate
    }));
  }
};

pc.onicegatheringstatechange = () => {
  console.log("iceGatheringState=", pc.iceGatheringState);
};

// Answerer will receive the data channel created by caller
pc.ondatachannel = (event) => {
  dc = event.channel;
  wireChannel();
};

function wireChannel() {
  dc.onopen = () => {
    setStatus("connected");
    enableSend(true);
    if (connectTimer) { clearTimeout(connectTimer); connectTimer = null; }
    updateTransport();
  };
  dc.onmessage = (event) => append("peer", "Peer: " + event.data);
  dc.onclose = () => {
    if (transport === "webrtc") {
      setStatus("disconnected");
      enableSend(false);
    }
  };
}

pc.oniceconnectionstatechange = () => {
  console.log("iceConnectionState=", pc.iceConnectionState);
  if (pc.iceConnectionState === "failed") useWsFallback("ice failed");
  if (pc.iceConnectionState === "connected" || pc.iceConnectionState === "completed") setStatus("connected");
  updateTransport();
};

ws.onopen = () => {
  // Join the signaling room
  ws.send(JSON.stringify({ cmd: "join", room }));
  if (forceWs) {
    setStatus("websocket mode");
    enableSend(true);
    updateTransport();
  }
};

ws.onerror = (e) => {
  console.error("WS error", e);
  setStatus("signaling error (see console)");
};

ws.onclose = (e) => {
  console.warn("WS closed", e.code, e.reason);
  setStatus("signaling closed");
};

ws.onmessage = async (evt) => {
  const msg = JSON.parse(evt.data);

  if (msg.type === "chat") {
    append("peer", "Peer: " + msg.text);
    return;
  }

  if (msg.type === "peers") {
    // Never create offer on initial peers info; wait for someone to join
    if (msg.count > 1) {
      setStatus(transport === "webrtc" ? "peer present (waiting for new_peer to initiate)" : "peer present (ws mode)");
    } else {
      setStatus(transport === "webrtc" ? "waiting for peer" : "waiting for peer (ws mode)");
    }
  }

  if (msg.type === "new_peer") {
    if (transport === "webrtc" && !isCaller) {
      isCaller = true;
      dc = pc.createDataChannel("chat");
      wireChannel();

      const offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      ws.send(JSON.stringify({ room, type: "offer", sdp: offer }));
      setStatus("sent offer (waiting for answer)");
      armConnectTimeout();
    }
  }

  if (msg.type === "offer") {
    if (transport === "webrtc") {
      await pc.setRemoteDescription(msg.sdp);
      remoteSet = true;
      // drain queued candidates
      while (pendingCandidates.length) {
        try { await pc.addIceCandidate(pendingCandidates.shift()); } catch (e) { console.error("drain cand", e); }
      }
      const answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      ws.send(JSON.stringify({ room, type: "answer", sdp: answer }));
      setStatus("sent answer");
      armConnectTimeout();
    }
  }

  if (msg.type === "answer") {
    if (transport === "webrtc") {
      await pc.setRemoteDescription(msg.sdp);
      remoteSet = true;
      while (pendingCandidates.length) {
        try { await pc.addIceCandidate(pendingCandidates.shift()); } catch (e) { console.error("drain cand", e); }
      }
      setStatus("got answer (establishing)");
      armConnectTimeout();
    }
  }

  if (msg.type === "candidate") {
    try {
      if (transport === "webrtc") {
        if (!remoteSet) {
          pendingCandidates.push(msg.candidate);
        } else {
          await pc.addIceCandidate(msg.candidate);
        }
      }
    } catch (e) {
      console.error("Error adding ICE candidate", e);
    }
  }
};

// Chat UI
document.getElementById("chatForm").addEventListener("submit", (e) => {
  e.preventDefault();
  const text = msgInput.value.trim();
  if (!text) return;
  if (transport === "webrtc") {
    if (!dc || dc.readyState !== "open") return;
    dc.send(text);
  } else {
    ws.send(JSON.stringify({ room, type: "chat", text }));
  }
  append("me", "Me: " + text);
  msgInput.value = "";
});

// Nice-to-have: let Enter focus the input immediately
msgInput.focus();
