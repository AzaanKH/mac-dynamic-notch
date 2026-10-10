const extensionAPI = typeof browser !== "undefined" ? browser : chrome;
const downloadPermissions = {
  permissions: ["downloads"],
  ...(typeof extensionAPI.runtime.getBrowserInfo === "function"
    ? { data_collection: ["websiteActivity"] } : {}),
};
const HOST_NAME = "com.notchrouter.browser_media";

let nativePort = null;
let downloadsEnabled = false;
let downloadHeartbeatTimer = null;
let downloadHeartbeatInFlight = false;
let downloadGeneration = 0;
const sessionTabs = new Map();
const tabSessions = new Map();

function browserName() {
  const agent = navigator.userAgent;
  if (agent.includes("Zen/")) return "Zen";
  if (agent.includes("Firefox/")) return "Firefox";
  if (agent.includes("Edg/")) return "Microsoft Edge";
  if (navigator.brave || agent.includes("Brave")) return "Brave";
  if (agent.includes("Chromium")) return "Chromium";
  return "Google Chrome";
}

function connectNativeHost() {
  if (nativePort) return nativePort;

  try {
    nativePort = extensionAPI.runtime.connectNative(HOST_NAME);
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
  const target = sessionTabs.get(message.session_id);
  if (!target) return;
  extensionAPI.tabs.sendMessage(target.tabId, {
    kind: "notchrouter_command",
    document_session_id: target.scriptDocumentID,
    command: message.command,
    seek_position: message.seek_position,
  }, target.documentId ? { documentId: target.documentId } : { frameId: target.frameId }).catch(() => {});
}

function endSession(sessionID) {
  if (!sessionID) return;
  postToNativeHost({
    kind: "ended",
    session_id: sessionID,
    browser_name: browserName(),
  });
  const target = sessionTabs.get(sessionID);
  if (target) {
    const sessions = tabSessions.get(target.tabId);
    sessions?.delete(sessionID);
    if (!sessions?.size) tabSessions.delete(target.tabId);
  }
  sessionTabs.delete(sessionID);
}

extensionAPI.runtime.onMessage.addListener((message, sender) => {
  if (!message || !sender.tab) return;

  const tabId = sender.tab.id;
  const frameId = sender.frameId ?? 0;
  const documentId = sender.documentId;
  const scriptDocumentID = typeof message.document_session_id === "string"
    && message.document_session_id.length <= 100 ? message.document_session_id : undefined;
  const sessionID = `${browserName()}:${tabId}:${frameId}:${documentId ?? scriptDocumentID ?? "legacy"}`;
  if (message.kind === "notchrouter_media_ended") {
    endSession(sessionID);
    return;
  }
  if (message.kind !== "notchrouter_media") return;
  for (const id of tabSessions.get(tabId) ?? []) {
    if (id !== sessionID && sessionTabs.get(id)?.frameId === frameId) endSession(id);
  }
  const sessions = tabSessions.get(tabId) ?? new Set();
  sessions.add(sessionID);
  tabSessions.set(tabId, sessions);
  sessionTabs.set(sessionID, { tabId, frameId, documentId, scriptDocumentID });
  postToNativeHost({
    ...message.media,
    kind: "update",
    session_id: sessionID,
    browser_name: browserName(),
  });
});

function endTabSessions(tabId) {
  for (const id of [...(tabSessions.get(tabId) ?? [])]) endSession(id);
}

extensionAPI.tabs.onRemoved.addListener(endTabSessions);

extensionAPI.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (changeInfo.status === "loading") endTabSessions(tabId);
});

function downloadMessage(item) {
  const filename = item.filename || "";
  const pathComponents = filename.split(/[\\/]/);
  const displayName = pathComponents[pathComponents.length - 1] || null;
  let sourceHost = null;
  try {
    sourceHost = new URL(item.finalUrl || item.url).hostname || null;
  } catch (_error) {}

  return {
    kind: "download_update",
    download_id: item.id,
    browser_name: browserName(),
    display_name: displayName,
    source_host: sourceHost,
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
  const generation = downloadGeneration;
  try {
    const matches = await extensionAPI.downloads.search({ id: downloadID });
    if (!downloadsEnabled || generation !== downloadGeneration) return;
    if (matches[0]) postToNativeHost(downloadMessage(matches[0]));
  } catch (_error) {}
}

async function syncRecentDownloads() {
  if (!downloadsEnabled) return;
  const generation = downloadGeneration;
  try {
    const items = await extensionAPI.downloads.search({
      limit: 20,
      orderBy: ["-startTime"],
    });
    if (!downloadsEnabled || generation !== downloadGeneration) return;
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
        await extensionAPI.downloads.pause(command.download_id);
        break;
      case "resume":
        await extensionAPI.downloads.resume(command.download_id);
        break;
      case "cancel":
        await extensionAPI.downloads.cancel(command.download_id);
        break;
      case "reveal":
        extensionAPI.downloads.show(command.download_id);
        break;
      default:
        return;
    }
    await publishDownload(command.download_id);
  } catch (_error) {}
}

async function sendDownloadHeartbeat() {
  if (!downloadsEnabled || downloadHeartbeatInFlight) return;
  downloadHeartbeatInFlight = true;
  const generation = downloadGeneration;
  try {
    const activeItems = await extensionAPI.downloads.search({ state: "in_progress" });
    if (!downloadsEnabled || generation !== downloadGeneration) return;
    for (const item of activeItems) postToNativeHost(downloadMessage(item));
  } catch (_error) {
    // The heartbeat still tells the app that the opted-in bridge is available.
  } finally {
    downloadHeartbeatInFlight = false;
  }
  if (!downloadsEnabled || generation !== downloadGeneration) return;
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
  await extensionAPI.action.setBadgeText({ text: downloadsEnabled ? "ON" : "" });
  await extensionAPI.action.setBadgeBackgroundColor({ color: "#2F80ED" });
  await extensionAPI.action.setTitle({
    title: downloadsEnabled
      ? "NotchRouter downloads are on — click to turn off"
      : "Enable NotchRouter download progress",
  });
}

async function setDownloadsEnabled(enabled) {
  downloadGeneration++;
  downloadsEnabled = enabled;
  if (enabled) registerDownloadListeners();
  await extensionAPI.storage.local.set({ downloadsEnabled: enabled });
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
  const stored = await extensionAPI.storage.local.get("downloadsEnabled");
  const hasPermission = await extensionAPI.permissions.contains(downloadPermissions);
  downloadsEnabled = stored.downloadsEnabled === true && hasPermission;
  if (!downloadsEnabled && stored.downloadsEnabled) {
    await extensionAPI.storage.local.set({ downloadsEnabled: false });
    postToNativeHost({
      kind: "downloads_disabled",
      download_id: 0,
      browser_name: browserName(),
    });
  }
  if (downloadsEnabled) registerDownloadListeners();
  setDownloadHeartbeatEnabled(downloadsEnabled);
  await updateDownloadAction();
  if (downloadsEnabled) await syncRecentDownloads();
}

extensionAPI.action.onClicked.addListener(async () => {
  if (downloadsEnabled) {
    await extensionAPI.permissions.remove(downloadPermissions);
    await setDownloadsEnabled(false);
    return;
  }
  const granted = await extensionAPI.permissions.request(downloadPermissions);
  if (granted) {
    await downloadsReady;
    await setDownloadsEnabled(true);
  }
});

extensionAPI.permissions.onRemoved.addListener((permissions) => {
  downloadsReady.then(() => {
    if (permissions.permissions?.includes("downloads")
      || permissions.data_collection?.includes("websiteActivity")) {
      setDownloadsEnabled(false);
    }
  });
});

let downloadListenersRegistered = false;
function registerDownloadListeners() {
  if (downloadListenersRegistered || !extensionAPI.downloads) return;
  downloadListenersRegistered = true;
  extensionAPI.downloads.onCreated.addListener((item) => {
    downloadsReady.then(() => {
      if (downloadsEnabled) postToNativeHost(downloadMessage(item));
    });
  });

  extensionAPI.downloads.onChanged.addListener((delta) => {
    downloadsReady.then(() => {
      if (downloadsEnabled) publishDownload(delta.id);
    });
  });

  extensionAPI.downloads.onErased.addListener((downloadID) => {
    downloadsReady.then(() => {
      if (!downloadsEnabled) return;
      postToNativeHost({
        kind: "download_removed",
        download_id: downloadID,
        browser_name: browserName(),
      });
    });
  });
}

registerDownloadListeners();
const downloadsReady = initializeDownloads();
