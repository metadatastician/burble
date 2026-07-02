// Burble AI Bridge — extension popup controller.
// Talks to the Burble AI bridge on localhost:6474 (HTTP).

const $ = (id) => document.getElementById(id);

let bridgeUrl = "http://localhost:6474";
let pollTimer = null;

async function checkStatus() {
  try {
    const res = await fetch(`${bridgeUrl}/status`, { signal: AbortSignal.timeout(2000) });
    const data = await res.json();
    $("dot").className = data.connected ? "dot green" : "dot red";
    $("status-text").textContent = data.connected
      ? `Connected — ${data.queued} queued`
      : "Bridge running, not connected to room";
    return true;
  } catch {
    $("dot").className = "dot grey";
    $("status-text").textContent = "Bridge not reachable";
    return false;
  }
}

async function pollMessages() {
  try {
    const res = await fetch(`${bridgeUrl}/recv`, { signal: AbortSignal.timeout(2000) });
    // /recv returns {messages: [...], count: N} (see burble-ai-bridge.js).
    const data = await res.json();
    if (Array.isArray(data.messages)) {
      for (const msg of data.messages) {
        appendMessage("in", msg);
      }
    }
  } catch {
    // Bridge unavailable — status poll will reflect this.
  }
}

function appendMessage(dir, msg) {
  const el = document.createElement("div");
  el.className = `msg msg-${dir}`;
  const prefix = dir === "in" ? "← " : "→ ";
  const text = typeof msg === "string" ? msg : JSON.stringify(msg);
  el.textContent = prefix + text;
  $("messages").appendChild(el);
  $("messages").scrollTop = $("messages").scrollHeight;
}

async function sendMessage(payload) {
  try {
    const body = typeof payload === "string" ? payload : JSON.stringify(payload);
    const parsed = JSON.parse(body);
    const res = await fetch(`${bridgeUrl}/send`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(parsed),
      signal: AbortSignal.timeout(2000)
    });
    const result = await res.json();
    if (result.ok) {
      appendMessage("out", parsed);
    } else {
      appendMessage("out", { error: result.error || "send failed" });
    }
  } catch (e) {
    appendMessage("out", { error: e.message });
  }
}

$("btn-send").addEventListener("click", () => {
  const text = $("send-input").value.trim();
  if (text) {
    sendMessage(text);
    $("send-input").value = "";
  }
});

$("btn-ping").addEventListener("click", () => {
  sendMessage({ type: "ping", from: "extension", ts: Date.now() });
});

$("bridge-url").addEventListener("change", () => {
  bridgeUrl = $("bridge-url").value.trim().replace(/\/$/, "");
  chrome.storage.local.set({ bridgeUrl });
  checkStatus();
});

// Keyboard shortcut: Enter to send.
$("send-input").addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey) {
    e.preventDefault();
    $("btn-send").click();
  }
});

// Restore saved bridge URL.
chrome.storage.local.get("bridgeUrl", (result) => {
  if (result.bridgeUrl) {
    bridgeUrl = result.bridgeUrl;
    $("bridge-url").value = bridgeUrl;
  }
});

// Initial status check + start polling.
checkStatus();
pollTimer = setInterval(() => {
  checkStatus();
  pollMessages();
}, 3000);
