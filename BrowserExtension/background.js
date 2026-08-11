const HOST_NAME = "com.notchrouter.browser_media";

let nativePort = null;
let downloadsEnabled = false;
let downloadHeartbeatTimer = null;
const sessionTabs = new Map();
const tabSessions = new Map();

function browserName() {
  const agent = navigator.userAgent;
  if (agent.includes("Edg/")) return "Microsoft Edge";
  if (navigator.brave || agent.includes("Brave")) return "Brave";
  if (agent.includes("Chromium")) return "Chromium";
  return "Google Chrome";
}

function connectNativeHost() {
  if (nativePort) return nativePort;

  try {
    nativePort = chrome.runtime.connectNative(HOST_NAME);
    nativePort.onMessage.addListener(handleNativeMessage);
    nativePort.onDisconnect.addListener(() => {
      nativePort = null;
    });
  } catch (_error) {
    nativePort = null;
  }
  return nativePort;
}

function postToNativeHost(message) {
  const port = connectNativeHost();
  if (!port) return;
  try {
    port.postMessage(message);
  } catch (_error) {
    nativePort = null;
  }
}

function handleNativeMessage(message) {
  if (message?.command?.download_id !== undefined) {
    applyDownloadCommand(message.command);
    return;
  }
  if (!message || !message.command || !message.session_id) return;
  const tabId = sessionTabs.get(message.session_id);
  if (tabId === undefined) return;
  chrome.tabs.sendMessage(tabId, {
    kind: "notchrouter_command",
    command: message.command,
  }).catch(() => {});
}

function endSession(sessionID) {
  if (!sessionID) return;
  postToNativeHost({
    kind: "ended",
    session_id: sessionID,
    browser_name: browserName(),
  });
  const tabId = sessionTabs.get(sessionID);
  if (tabId !== undefined) tabSessions.delete(tabId);
  sessionTabs.delete(sessionID);
}

chrome.runtime.onMessage.addListener((message, sender) => {
  if (!message || !sender.tab) return;

  const tabId = sender.tab.id;
  const sessionID = `${browserName()}:${tabId}`;
  if (message.kind === "notchrouter_media_ended") {
    endSession(sessionID);
    return;
  }
  if (message.kind !== "notchrouter_media") return;
  const previousSession = tabSessions.get(tabId);
  if (previousSession && previousSession !== sessionID) endSession(previousSession);

  tabSessions.set(tabId, sessionID);
  sessionTabs.set(sessionID, tabId);
  postToNativeHost({
    ...message.media,
    kind: "update",
    session_id: sessionID,
    browser_name: browserName(),
  });
});

chrome.tabs.onRemoved.addListener((tabId) => {
  endSession(tabSessions.get(tabId));
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (changeInfo.status === "loading") endSession(tabSessions.get(tabId));
});

function downloadMessage(item) {
  return {
    kind: "download_update",
    download_id: item.id,
    browser_name: browserName(),
    filename: item.filename || null,
    source_url: item.finalUrl || item.url || null,
    bytes_received: item.bytesReceived ?? 0,
    total_bytes: item.totalBytes ?? -1,
    estimated_end_time: item.estimatedEndTime || null,
    state: item.state,
    is_paused: item.paused ?? false,
    can_resume: item.canResume ?? false,
    error: item.error || null,
  };
}

async function publishDownload(downloadID) {
  if (!downloadsEnabled) return;
  try {
    const matches = await chrome.downloads.search({ id: downloadID });
    if (matches[0]) postToNativeHost(downloadMessage(matches[0]));
  } catch (_error) {}
}

async function syncRecentDownloads() {
  if (!downloadsEnabled) return;
  try {
    const items = await chrome.downloads.search({
      limit: 20,
      orderBy: ["-startTime"],
    });
    for (const item of items.reverse()) {
      postToNativeHost(downloadMessage(item));
    }
  } catch (_error) {}
}

async function applyDownloadCommand(command) {
  if (!downloadsEnabled || !command) return;
  try {
    switch (command.action) {
      case "pause":
        await chrome.downloads.pause(command.download_id);
        break;
      case "resume":
        await chrome.downloads.resume(command.download_id);
        break;
      case "cancel":
        await chrome.downloads.cancel(command.download_id);
        break;
      case "reveal":
        chrome.downloads.show(command.download_id);
        break;
      default:
        return;
    }
    await publishDownload(command.download_id);
  } catch (_error) {}
}

async function sendDownloadHeartbeat() {
  if (!downloadsEnabled) return;
  try {
    const activeItems = await chrome.downloads.search({ state: "in_progress" });
    for (const item of activeItems) {
      postToNativeHost(downloadMessage(item));
    }
  } catch (_error) {}
  postToNativeHost({
    kind: "downloads_heartbeat",
    download_id: 0,
    browser_name: browserName(),
  });
}

function setDownloadHeartbeatEnabled(enabled) {
  if (downloadHeartbeatTimer) {
    clearInterval(downloadHeartbeatTimer);
    downloadHeartbeatTimer = null;
  }
  if (enabled) {
    connectNativeHost();
    downloadHeartbeatTimer = setInterval(sendDownloadHeartbeat, 2000);
    sendDownloadHeartbeat();
  }
}

async function updateDownloadAction() {
  await chrome.action.setBadgeText({ text: downloadsEnabled ? "ON" : "" });
  await chrome.action.setBadgeBackgroundColor({ color: "#2F80ED" });
  await chrome.action.setTitle({
    title: downloadsEnabled
      ? "NotchRouter downloads are on — click to turn off"
      : "Enable NotchRouter download progress",
  });
}

async function setDownloadsEnabled(enabled) {
  downloadsEnabled = enabled;
  await chrome.storage.local.set({ downloadsEnabled: enabled });
  setDownloadHeartbeatEnabled(enabled);
  if (!enabled) {
    postToNativeHost({
      kind: "downloads_disabled",
      download_id: 0,
      browser_name: browserName(),
    });
  }
  await updateDownloadAction();
  if (enabled) await syncRecentDownloads();
}

async function initializeDownloads() {
  const stored = await chrome.storage.local.get("downloadsEnabled");
  const hasPermission = await chrome.permissions.contains({
    permissions: ["downloads"],
  });
  downloadsEnabled = stored.downloadsEnabled === true && hasPermission;
  if (!downloadsEnabled && stored.downloadsEnabled) {
    await chrome.storage.local.set({ downloadsEnabled: false });
    postToNativeHost({
      kind: "downloads_disabled",
      download_id: 0,
      browser_name: browserName(),
    });
  }
  setDownloadHeartbeatEnabled(downloadsEnabled);
  await updateDownloadAction();
  if (downloadsEnabled) await syncRecentDownloads();
}

chrome.action.onClicked.addListener(async () => {
  await downloadsReady;
  if (downloadsEnabled) {
    await chrome.permissions.remove({ permissions: ["downloads"] });
    await setDownloadsEnabled(false);
    return;
  }
  const granted = await chrome.permissions.request({
    permissions: ["downloads"],
  });
  if (granted) await setDownloadsEnabled(true);
});

chrome.permissions.onRemoved.addListener((permissions) => {
  downloadsReady.then(() => {
    if (permissions.permissions?.includes("downloads")) {
      setDownloadsEnabled(false);
    }
  });
});

chrome.downloads.onCreated.addListener((item) => {
  downloadsReady.then(() => {
    if (downloadsEnabled) postToNativeHost(downloadMessage(item));
  });
});

chrome.downloads.onChanged.addListener((delta) => {
  downloadsReady.then(() => {
    if (downloadsEnabled) publishDownload(delta.id);
  });
});

chrome.downloads.onErased.addListener((downloadID) => {
  downloadsReady.then(() => {
    if (!downloadsEnabled) return;
    postToNativeHost({
      kind: "download_removed",
      download_id: downloadID,
      browser_name: browserName(),
    });
  });
});

const downloadsReady = initializeDownloads();
