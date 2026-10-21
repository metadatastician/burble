// Burble AI Bridge — background service worker.
// Maintains bridge connection status and provides badge updates.
//
// MV3 service workers are evicted after ~30s of inactivity, taking any
// setInterval with them — the previous version polled on an interval that
// simply stopped firing, and the badge froze. chrome.alarms wakes the worker
// back up, so the badge keeps tracking the bridge.

const DEFAULT_BRIDGE = "http://localhost:6474";
const ALARM_NAME = "burble-bridge-poll";
const POLL_MINUTES = 0.5; // the smallest period Chrome allows

async function updateBadge() {
  try {
    const { bridgeUrl } = await chrome.storage.local.get("bridgeUrl");
    const url = bridgeUrl || DEFAULT_BRIDGE;
    const res = await fetch(`${url}/status`, { signal: AbortSignal.timeout(2000) });
    const data = await res.json();

    if (data.connected) {
      chrome.action.setBadgeText({ text: "" });
      chrome.action.setBadgeBackgroundColor({ color: "#3fb950" });
      if (data.queued > 0) {
        chrome.action.setBadgeText({ text: String(data.queued) });
      }
    } else {
      chrome.action.setBadgeText({ text: "!" });
      chrome.action.setBadgeBackgroundColor({ color: "#d29922" });
    }
  } catch {
    chrome.action.setBadgeText({ text: "" });
  }
}

/** Schedule bridge status polling every 30 seconds; Chrome API errors reject the promise. */
async function schedule() {
  // create() with an existing name is a no-op, so this is safe on every wake.
  await chrome.alarms.create(ALARM_NAME, { periodInMinutes: POLL_MINUTES });
}

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === ALARM_NAME) updateBadge();
});

// Re-arm on install/update/browser start as well as every worker wake-up.
chrome.runtime.onInstalled.addListener(() => {
  schedule();
  updateBadge();
});
chrome.runtime.onStartup.addListener(() => {
  schedule();
  updateBadge();
});

schedule();
updateBadge();
