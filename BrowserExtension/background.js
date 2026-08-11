const HOST_NAME = "com.notchrouter.browser_media";

let nativePort = null;
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
  const sessionID = `chromium:${tabId}`;
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
