const extensionAPI = typeof browser !== "undefined" ? browser : chrome;
const documentSessionID = crypto.randomUUID();
const MEDIA_EVENTS = [
  "play",
  "playing",
  "pause",
  "ended",
  "emptied",
  "loadedmetadata",
  "durationchange",
  "seeked",
  "ratechange",
];

let activeMedia = null;
let lastPlayingMedia = null;
let lastPayload = "";
let lastSentAt = 0;
let reportedMedia = false;
let sendTimer = null;
const observedMedia = new WeakSet();
const knownMedia = new Set();
const rootObservers = new Map();
const pendingSubtrees = new Set();
let discoveryTimer = null;
let pendingForce = false;
let heartbeatTimer = null;
let reconciliationTimer = null;
let commandTimer = null;
let isPageActive = true;

function pruneDiscovery() {
  for (const media of knownMedia) {
    if (!media.isConnected) knownMedia.delete(media);
  }
  for (const [root, observer] of rootObservers) {
    if (root !== document && !root.host?.isConnected) {
      observer.disconnect();
      rootObservers.delete(root);
    }
  }
}

function observeRoot(root) {
  if (rootObservers.has(root)) return;
  const observer = new MutationObserver((records) => {
    if (!isPageActive) return;
    for (const record of records) {
      for (const node of record.addedNodes) {
        if (node.nodeType === 1) pendingSubtrees.add(node);
      }
    }
    if (discoveryTimer !== null) return;
    discoveryTimer = setTimeout(() => {
      discoveryTimer = null;
      const subtrees = new Set(pendingSubtrees);
      pendingSubtrees.clear();
      for (const node of subtrees) {
        let ancestor = node.parentNode;
        while (ancestor && !subtrees.has(ancestor)) ancestor = ancestor.parentNode || ancestor.host;
        if (node.isConnected && !ancestor) discoverSubtree(node);
      }
      pruneDiscovery();
      if (knownMedia.size || reportedMedia) scheduleSnapshot();
    }, 100);
  });
  observer.observe(root, { childList: true, subtree: true });
  rootObservers.set(root, observer);
}

function discoverSubtree(root) {
  if (root === document || root.host) observeRoot(root);
  function visit(element) {
    if (element.matches?.("audio, video")) {
      knownMedia.add(element);
      observeMedia(element);
    }
    if (element.shadowRoot) discoverSubtree(element.shadowRoot);
  }
  if (root.nodeType === 1) visit(root);
  for (const element of root.querySelectorAll("*")) visit(element);
}

function metaContent(selectors) {
  for (const selector of selectors) {
    const value = document.querySelector(selector)?.content?.trim();
    if (value) return value;
  }
  return "";
}

function cleanDocumentTitle() {
  return document.title
    .replace(/^\(\d+\)\s*/, "")
    .replace(/\s[-–—|]\s(?:YouTube|Vimeo|Twitch|SoundCloud|Spotify).*$/i, "")
    .trim();
}

function mediaSessionMetadata() {
  try {
    return navigator.mediaSession?.metadata || null;
  } catch (_error) {
    return null;
  }
}

// Controls are queried only within roots already found by incremental discovery.
function queryMediaRoots(selector) {
  return [...rootObservers.keys()].flatMap(root => [...root.querySelectorAll(selector)]);
}

function mediaElements() {
  pruneDiscovery();
  return [...knownMedia].filter((media) => {
    return !media.ended
      && media.readyState > 0
      && (media.duration > 0 || media.duration === Infinity);
  });
}

function visibleArea(element) {
  const rect = element.getBoundingClientRect();
  const width = Math.max(0, Math.min(rect.right, innerWidth) - Math.max(rect.left, 0));
  const height = Math.max(0, Math.min(rect.bottom, innerHeight) - Math.max(rect.top, 0));
  return width * height;
}

function chooseMedia() {
  const elements = mediaElements();
  const playing = elements.filter((media) => !media.paused && !media.ended);
  if (playing.length) {
    lastPlayingMedia = playing.sort((a, b) => visibleArea(b) - visibleArea(a))[0];
    return lastPlayingMedia;
  }
  if (lastPlayingMedia && elements.includes(lastPlayingMedia)) return lastPlayingMedia;
  return elements.sort((a, b) => visibleArea(b) - visibleArea(a))[0] || null;
}

function matchingButton(direction) {
  const knownSelectors = direction === "next"
    ? [
      ".ytp-next-button",
      "[data-testid='control-button-skip-forward']",
      ".skipControl__next",
    ]
    : [
      ".ytp-prev-button",
      "[data-testid='control-button-skip-back']",
      ".skipControl__previous",
    ];
  for (const selector of knownSelectors) {
    const element = queryMediaRoots(selector)[0];
    if (element && !element.disabled && element.getAttribute("aria-disabled") !== "true") {
      return element;
    }
  }

  const pattern = direction === "next"
    ? /^(next|skip)\s+(track|video|episode|song)(?:\s*\(.+\))?$/i
    : /^(previous|back)\s+(track|video|episode|song)(?:\s*\(.+\))?$/i;

  return queryMediaRoots("button, [role='button']").find((element) => {
    if (element.disabled || element.getAttribute("aria-disabled") === "true") return false;
    const label = (
      element.getAttribute("aria-label") ||
      element.getAttribute("title") ||
      element.textContent ||
      ""
    ).trim();
    return pattern.test(label);
  }) || null;
}

function absoluteHTTPURL(value) {
  if (!value) return null;
  try {
    const url = new URL(value, document.baseURI);
    return url.protocol === "http:" || url.protocol === "https:" ? url.href : null;
  } catch (_error) {
    return null;
  }
}

let artworkRequestURL = null;
let artworkData = null;
let artworkAbort = null;
let artworkFailures = 0;
let artworkRetryAt = 0;

// Fetch in the content script so browser CORS and local-network restrictions apply.
// Native code receives only a bounded thumbnail, never an address to fetch.
async function fetchArtworkThumbnail(url, signal) {
  const response = await fetch(url, { credentials: "omit", redirect: "error", signal });
  const limit = 2 * 1024 * 1024;
  if (!response.ok || !response.body) return null;
  if (Number(response.headers.get("content-length")) > limit) {
    await response.body.cancel();
    return null;
  }
  const reader = response.body.getReader();
  const chunks = [];
  let count = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      count += value.byteLength;
      if (count > limit) return null;
      chunks.push(value);
    }
  } finally { await reader.cancel(); }
  if (signal.aborted) return null;
  const bitmap = await createImageBitmap(new Blob(chunks));
  try {
    if (bitmap.width * bitmap.height > 16_000_000) return null;
    // Center-crop to a square, as the notch displays covers, so wide video
    // thumbnails are cropped instead of stretched.
    const side = Math.min(bitmap.width, bitmap.height);
    const canvas = new OffscreenCanvas(256, 256);
    canvas.getContext("2d").drawImage(
      bitmap, (bitmap.width - side) / 2, (bitmap.height - side) / 2, side, side, 0, 0, 256, 256,
    );
    const thumbnail = await canvas.convertToBlob({ type: "image/jpeg", quality: 0.75 });
    if (thumbnail.size > 32768 || signal.aborted) return null;
    const bytes = new Uint8Array(await thumbnail.arrayBuffer());
    return btoa(String.fromCharCode(...bytes));
  } finally { bitmap.close(); }
}

function artworkRetryDelay(failures) {
  return Math.min(15000 * 2 ** (failures - 1), 600000);
}

function updateArtwork(url, { force = false } = {}) {
  if (url === artworkRequestURL) {
    // Snapshots repeat the same image. Retry only a failed request, once its
    // backoff has elapsed (or immediately when connectivity returns).
    if (!url || artworkData || artworkAbort || (!force && Date.now() < artworkRetryAt)) return;
  } else {
    artworkAbort?.abort();
    artworkAbort = null;
    artworkRequestURL = url;
    artworkData = null;
    artworkFailures = 0;
    artworkRetryAt = 0;
    if (!url) return;
  }
  const controller = new AbortController();
  artworkAbort = controller;
  const deadline = setTimeout(() => controller.abort(), 10000);
  fetchArtworkThumbnail(url, controller.signal).catch(() => null).then(data => {
    // A newer image or an ended page replaced this request.
    if (artworkRequestURL !== url || artworkAbort !== controller) return;
    artworkAbort = null;
    if (data) {
      artworkData = data;
      artworkFailures = 0;
      scheduleSnapshot(true);
      return;
    }
    artworkFailures += 1;
    artworkRetryAt = Date.now() + artworkRetryDelay(artworkFailures);
  }).finally(() => clearTimeout(deadline));
}

addEventListener("online", () => updateArtwork(artworkRequestURL, { force: true }));

function buildSnapshot(media) {
  const metadata = mediaSessionMetadata();
  const artwork = metadata?.artwork?.at(-1)?.src;
  const siteName = metaContent(["meta[property='og:site_name']", "meta[name='application-name']"])
    || location.hostname.replace(/^www\./, "");
  const title = metadata?.title?.trim()
    || metaContent(["meta[property='og:title']", "meta[name='twitter:title']"])
    || cleanDocumentTitle()
    || "Browser media";
  const artist = metadata?.artist?.trim()
    || metaContent(["meta[name='author']", "meta[property='music:musician']"])
    || siteName;
  const album = metadata?.album?.trim()
    || metaContent(["meta[property='music:album']"])
    || siteName;

  updateArtwork(absoluteHTTPURL(
    artwork || metaContent(["meta[property='og:image']", "meta[name='twitter:image']"])
  ));
  return {
    title: title.slice(0, 500),
    artist: artist.slice(0, 300),
    album: album.slice(0, 300),
    site_name: siteName.slice(0, 120),
    page_url: location.href.slice(0, 4096),
    artwork_data: artworkData,
    is_playing: !media.paused && !media.ended,
    duration: Number.isFinite(media.duration) ? Math.max(0, media.duration) : 0,
    position: Number.isFinite(media.currentTime) ? Math.max(0, media.currentTime) : 0,
    supports_previous: Boolean(matchingButton("previous"))
      || (Number.isFinite(media.duration) && media.currentTime > 3),
    supports_next: Boolean(matchingButton("next")),
    supports_seeking: Number.isFinite(media.duration) && media.duration > 0 && media.seekable.length > 0,
    playback_rate: Number.isFinite(media.playbackRate) ? media.playbackRate : 1,
    is_background: Boolean(document.hidden),
  };
}

function sendSnapshot(force = false) {
  if (!isPageActive) return;
  activeMedia = chooseMedia();
  scheduleHeartbeat();
  if (!activeMedia) {
    updateArtwork(null);
    if (reportedMedia) {
      extensionAPI.runtime.sendMessage({ kind: "notchrouter_media_ended", document_session_id: documentSessionID }).catch(() => {});
      reportedMedia = false;
      lastPayload = "";
    }
    return;
  }
  observeMedia(activeMedia);
  const snapshot = buildSnapshot(activeMedia);
  const comparison = JSON.stringify({
    ...snapshot,
    position: Math.floor(snapshot.position),
  });
  if (!force && comparison === lastPayload && Date.now() - lastSentAt < 5000) return;
  lastPayload = comparison;
  lastSentAt = Date.now();
  reportedMedia = true;
  extensionAPI.runtime.sendMessage({
    kind: "notchrouter_media",
    document_session_id: documentSessionID,
    media: snapshot,
  }).catch(() => {});
}

function scheduleSnapshot(force = false) {
  if (!isPageActive) return;
  pendingForce ||= force;
  if (sendTimer !== null) return;
  sendTimer = setTimeout(() => {
    sendTimer = null;
    const shouldForce = pendingForce;
    pendingForce = false;
    sendSnapshot(shouldForce);
  }, 100);
}

function observeMedia(media) {
  if (observedMedia.has(media)) return;
  observedMedia.add(media);
  for (const eventName of MEDIA_EVENTS) {
    media.addEventListener(eventName, () => scheduleSnapshot(true), { passive: true });
  }
}

function discoverMedia() {
  if (!isPageActive) return;
  discoverSubtree(document);
  pruneDiscovery();
  if (knownMedia.size || reportedMedia) scheduleSnapshot();
}

function scheduleHeartbeat() {
  clearTimeout(heartbeatTimer);
  heartbeatTimer = null;
  if (!isPageActive || !activeMedia) return;
  // Paused and background players still heartbeat below the native session expiry.
  // Media events and commands publish immediately through the short debounce.
  const delay = document.hidden || activeMedia.paused ? 5000 : 1000;
  heartbeatTimer = setTimeout(() => {
    heartbeatTimer = null;
    sendSnapshot();
  }, delay);
}

function scheduleReconciliation() {
  clearTimeout(reconciliationTimer);
  reconciliationTimer = null;
  if (!isPageActive) return;
  // attachShadow() on an existing host does not emit a DOM mutation. Keep a
  // fallback scan, but give background pages without user interaction more time.
  reconciliationTimer = setTimeout(() => {
    reconciliationTimer = null;
    discoverMedia();
    scheduleReconciliation();
  }, document.hidden ? 60000 : 10000);
}

function suspendPage() {
  isPageActive = false;
  for (const timer of [heartbeatTimer, reconciliationTimer, commandTimer, sendTimer, discoveryTimer]) {
    clearTimeout(timer);
  }
  heartbeatTimer = reconciliationTimer = commandTimer = sendTimer = discoveryTimer = null;
  pendingForce = false;
  pendingSubtrees.clear();
  for (const observer of rootObservers.values()) observer.disconnect();
  rootObservers.clear();
  knownMedia.clear();
  activeMedia = lastPlayingMedia = null;
  updateArtwork(null);
  if (reportedMedia) {
    extensionAPI.runtime.sendMessage({ kind: "notchrouter_media_ended", document_session_id: documentSessionID }).catch(() => {});
  }
  reportedMedia = false;
  lastPayload = "";
}

function seekMedia(media, position) {
  if (!Number.isFinite(position) || !Number.isFinite(media.duration) || media.duration <= 0) return;
  const ranges = media.seekable;
  if (!ranges.length) return;
  const requested = Math.min(media.duration, Math.max(0, position));
  let target = ranges.start(0);
  let distance = Infinity;
  for (let index = 0; index < ranges.length; index++) {
    const candidate = Math.min(ranges.end(index), Math.max(ranges.start(index), requested));
    if (Math.abs(candidate - requested) < distance) {
      target = candidate;
      distance = Math.abs(candidate - requested);
    }
  }
  try { media.currentTime = target; } catch (_error) {}
}

extensionAPI.runtime.onMessage.addListener((message) => {
  if (!isPageActive) return;
  if (!message || message.kind !== "notchrouter_command") return;
  if (message.document_session_id && message.document_session_id !== documentSessionID) return;
  const media = chooseMedia();
  if (!media) return;

  if (message.command === "play_pause") {
    if (media.paused) media.play().catch(() => {});
    else media.pause();
  } else if (message.command === "previous") {
    const button = matchingButton("previous");
    if (button) button.click();
    else if (Number.isFinite(media.duration) && media.currentTime > 3) media.currentTime = 0;
  } else if (message.command === "seek") {
    seekMedia(media, message.seek_position);
  } else if (message.command === "next") {
    matchingButton("next")?.click();
  }
  clearTimeout(commandTimer);
  commandTimer = setTimeout(() => {
    commandTimer = null;
    sendSnapshot(true);
  }, 150);
});

discoverMedia();
scheduleReconciliation();
document.addEventListener("visibilitychange", () => {
  if (!isPageActive) return;
  if (!document.hidden) discoverMedia();
  scheduleSnapshot(true);
  scheduleReconciliation();
});
addEventListener("pagehide", suspendPage);
addEventListener("pageshow", () => {
  if (isPageActive) return;
  isPageActive = true;
  discoverMedia();
  scheduleReconciliation();
});
