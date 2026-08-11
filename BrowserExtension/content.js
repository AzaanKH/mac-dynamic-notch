const MEDIA_EVENTS = [
  "play",
  "playing",
  "pause",
  "ended",
  "emptied",
  "loadedmetadata",
  "durationchange",
  "seeked",
];

let activeMedia = null;
let lastPlayingMedia = null;
let lastPayload = "";
let lastSentAt = 0;
let reportedMedia = false;
let sendTimer = null;
const observedMedia = new WeakSet();

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

function mediaElements() {
  return [...document.querySelectorAll("audio, video")].filter((media) => {
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
    const element = document.querySelector(selector);
    if (element && !element.disabled && element.getAttribute("aria-disabled") !== "true") {
      return element;
    }
  }

  const pattern = direction === "next"
    ? /^(next|skip)\s+(track|video|episode|song)(?:\s*\(.+\))?$/i
    : /^(previous|back)\s+(track|video|episode|song)(?:\s*\(.+\))?$/i;

  return [...document.querySelectorAll("button, [role='button']")].find((element) => {
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

  return {
    title,
    artist,
    album,
    site_name: siteName,
    page_url: location.href,
    artwork_url: absoluteHTTPURL(
      artwork || metaContent(["meta[property='og:image']", "meta[name='twitter:image']"])
    ),
    is_playing: !media.paused && !media.ended,
    duration: Number.isFinite(media.duration) ? Math.max(0, media.duration) : 0,
    position: Number.isFinite(media.currentTime) ? Math.max(0, media.currentTime) : 0,
    supports_previous: Boolean(matchingButton("previous"))
      || (Number.isFinite(media.duration) && media.currentTime > 3),
    supports_next: Boolean(matchingButton("next")),
  };
}

function sendSnapshot(force = false) {
  activeMedia = chooseMedia();
  if (!activeMedia) {
    if (reportedMedia) {
      chrome.runtime.sendMessage({ kind: "notchrouter_media_ended" }).catch(() => {});
      reportedMedia = false;
      lastPayload = "";
    }
    return;
  }
  const snapshot = buildSnapshot(activeMedia);
  const comparison = JSON.stringify({
    ...snapshot,
    position: Math.floor(snapshot.position),
  });
  if (!force && comparison === lastPayload && Date.now() - lastSentAt < 5000) return;
  lastPayload = comparison;
  lastSentAt = Date.now();
  reportedMedia = true;
  chrome.runtime.sendMessage({
    kind: "notchrouter_media",
    media: snapshot,
  }).catch(() => {});
}

function scheduleSnapshot(force = false) {
  clearTimeout(sendTimer);
  sendTimer = setTimeout(() => sendSnapshot(force), 100);
}

function observeMedia(media) {
  if (observedMedia.has(media)) return;
  observedMedia.add(media);
  for (const eventName of MEDIA_EVENTS) {
    media.addEventListener(eventName, () => scheduleSnapshot(true), { passive: true });
  }
}

function discoverMedia() {
  for (const media of document.querySelectorAll("audio, video")) observeMedia(media);
  scheduleSnapshot();
}

chrome.runtime.onMessage.addListener((message) => {
  if (!message || message.kind !== "notchrouter_command") return;
  const media = chooseMedia();
  if (!media) return;

  if (message.command === "play_pause") {
    if (media.paused) media.play().catch(() => {});
    else media.pause();
  } else if (message.command === "previous") {
    const button = matchingButton("previous");
    if (button) button.click();
    else if (Number.isFinite(media.duration) && media.currentTime > 3) media.currentTime = 0;
  } else if (message.command === "next") {
    matchingButton("next")?.click();
  }
  setTimeout(() => sendSnapshot(true), 150);
});

new MutationObserver(discoverMedia).observe(document.documentElement, {
  childList: true,
  subtree: true,
});

discoverMedia();
setInterval(() => sendSnapshot(), 1000);
