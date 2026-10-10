const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

function contentContext(overrides = {}) {
  const document = {
    querySelectorAll: () => [], querySelector: () => null,
    addEventListener() {}, documentElement: {}, title: 'Episode', baseURI: 'https://example.com',
  };
  const context = vm.createContext({
    document, navigator: {}, location: { hostname: 'example.com', href: 'https://example.com' },
    chrome: { runtime: { onMessage: { addListener() {} }, sendMessage: async () => {} } },
    MutationObserver: class { observe() {} },
    setTimeout() {}, clearTimeout() {}, setInterval() {}, addEventListener() {}, URL,
    crypto: require("node:crypto").webcrypto,
    ...overrides,
  });
  vm.runInContext(readFileSync(path.join(__dirname, '../content.js'), 'utf8'), context);
  return context;
}

function media(ranges = [[0, 120]]) {
  return {
    duration: 120, currentTime: 20, playbackRate: 1.5, paused: false, ended: false,
    seekable: { length: ranges.length, start: i => ranges[i][0], end: i => ranges[i][1] },
  };
}

test('seeking clamps to the nearest available range and ignores invalid targets', () => {
  const context = contentContext();
  const player = media([[5, 20], [40, 100]]);
  context.seekMedia(player, 32);
  assert.equal(player.currentTime, 40);
  context.seekMedia(player, -50);
  assert.equal(player.currentTime, 5);
  context.seekMedia(player, 500);
  assert.equal(player.currentTime, 100);
  context.seekMedia(player, NaN);
  assert.equal(player.currentTime, 100);
  const live = { ...player, duration: Infinity };
  context.seekMedia(live, 10);
  assert.equal(live.currentTime, 100);
  const unseekable = media([]);
  context.seekMedia(unseekable, 60);
  assert.equal(unseekable.currentTime, 20);
});

test('snapshots report seeking capability and playback speed', () => {
  const context = contentContext();
  assert.equal(context.buildSnapshot(media()).supports_seeking, true);
  assert.equal(context.buildSnapshot(media()).playback_rate, 1.5);
  assert.equal(context.buildSnapshot(media([])).supports_seeking, false);
  assert.equal(context.buildSnapshot({ ...media(), duration: Infinity }).supports_seeking, false);
});

test('embedded frame commands target one document and tab cleanup ends all sessions', () => {
  const listeners = {};
  const sent = [];
  const native = [];
  const context = vm.createContext({
    navigator: { userAgent: 'Chrome' },
    chrome: {
      runtime: {
        onMessage: { addListener: fn => { listeners.media = fn; } },
        connectNative: () => ({
          onMessage: { addListener() {} }, onDisconnect: { addListener() {} },
          postMessage: message => native.push(message),
        }),
      },
      tabs: {
        sendMessage: async (...args) => { sent.push(args); },
        onRemoved: { addListener: fn => { listeners.removed = fn; } },
        onUpdated: { addListener: fn => { listeners.updated = fn; } },
      },
    },
  });
  // Media routing is independent of optional download initialization.
  const source = readFileSync(path.join(__dirname, '../background.js'), 'utf8');
  vm.runInContext(source.slice(0, source.indexOf('function downloadMessage')), context);
  const report = { kind: 'notchrouter_media', media: { title: 'Episode' } };
  listeners.media(report, { tab: { id: 7 }, frameId: 0, documentId: 'top' });
  listeners.media(report, { tab: { id: 7 }, frameId: 2, documentId: 'embed' });
  const embeddedID = native[1].session_id;
  context.handleNativeMessage({ session_id: embeddedID, command: 'seek', seek_position: 42 });
  assert.equal(sent.length, 1);
  assert.equal(sent[0][0], 7);
  assert.equal(sent[0][1].seek_position, 42);
  assert.equal(sent[0][2].documentId, 'embed');
  listeners.media(report, { tab: { id: 7 }, frameId: 2, documentId: 'replacement' });
  context.handleNativeMessage({ session_id: embeddedID, command: 'play_pause' });
  assert.equal(sent.length, 1, 'commands for the replaced document must be discarded');
  listeners.removed(7);
  assert.equal(native.filter(message => message.kind === 'ended').length, 3);
});


test('artwork transfer omits credentials and bounds unknown-length streams before decoding', async () => {
  let decoded = 0;
  let cancelled = 0;
  let requested;
  let remaining = [new Uint8Array(1024 * 1024), new Uint8Array(1024 * 1024 + 1)];
  const context = contentContext({
    Blob, AbortController, btoa,
    fetch: async (url, options) => {
      requested = options;
      return { ok: true, headers: { get: () => null }, body: { getReader: () => ({
        read: async () => remaining.length ? { value: remaining.shift() } : { done: true },
        cancel: async () => { cancelled++; },
      }) } };
    },
    createImageBitmap: async () => { decoded++; throw new Error('should not decode'); },
  });
  const result = await context.fetchArtworkThumbnail('https://example.com/cover', new AbortController().signal);
  assert.equal(result, null);
  assert.equal(decoded, 0);
  assert.equal(cancelled, 1);
  assert.equal(requested.credentials, 'omit');
  assert.equal(requested.redirect, 'error');
});

test('browser artwork becomes bounded bytes and native requests never receive an artwork URL', async () => {
  let remaining = [new Uint8Array([1, 2, 3])];
  let closed = false;
  const context = contentContext({
    Blob, AbortController, btoa,
    fetch: async () => ({ ok: true, headers: { get: () => '3' }, body: { getReader: () => ({
      read: async () => remaining.length ? { value: remaining.shift() } : { done: true }, cancel: async () => {},
    }) } }),
    createImageBitmap: async () => ({ width: 256, height: 256, close() { closed = true; } }),
    OffscreenCanvas: class {
      getContext() { return { drawImage() {} }; }
      async convertToBlob() { return new Blob([new Uint8Array([4, 5, 6])]); }
    },
  });
  const result = await context.fetchArtworkThumbnail('https://example.com/cover', new AbortController().signal);
  assert.equal(result, 'BAUG');
  assert.equal(closed, true);
  const snapshot = context.buildSnapshot(media());
  assert.equal(snapshot.artwork_url, undefined);
  assert.equal(snapshot.artwork_data, null);
});

test('late artwork responses cannot restore an ended or replaced page image', async () => {
  const completions = [];
  const context = contentContext({ AbortController });
  context.fetchArtworkThumbnail = async () => new Promise(resolve => completions.push(resolve));
  context.updateArtwork('https://example.com/first');
  context.updateArtwork('https://example.com/second');
  completions[0]('old');
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(vm.runInContext('artworkData', context), null);
  context.updateArtwork(null);
  completions[1]('new');
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(vm.runInContext('artworkData', context), null);
});

test('wide artwork is center-cropped to a square instead of stretched', async () => {
  let drawn;
  const context = contentContext({
    Blob, AbortController, btoa,
    fetch: async () => ({ ok: true, headers: { get: () => '1' }, body: { getReader: () => {
      let sent = false;
      return { read: async () => sent ? { done: true } : (sent = true, { value: new Uint8Array([1]) }), cancel: async () => {} };
    } } }),
    createImageBitmap: async () => ({ width: 1600, height: 900, close() {} }),
    OffscreenCanvas: class {
      getContext() { return { drawImage(...args) { drawn = args.slice(1); } }; }
      async convertToBlob() { return new Blob([new Uint8Array([1])]); }
    },
  });
  await context.fetchArtworkThumbnail('https://example.com/wide', new AbortController().signal);
  assert.deepEqual(drawn, [350, 0, 900, 900, 0, 0, 256, 256]);
});

test('failed artwork is retried after backoff and when the browser comes back online', async () => {
  let requests = 0;
  let succeed = false;
  let now = 1_000_000;
  const listeners = {};
  const context = contentContext({
    AbortController,
    addEventListener(name, callback) { listeners[name] = callback; },
  });
  vm.runInContext('Date.now = () => globalThis.__now', context);
  context.__now = now;
  context.fetchArtworkThumbnail = async () => { requests++; return succeed ? 'DATA' : null; };
  context.scheduleSnapshot = () => {};
  const settle = () => new Promise(resolve => setImmediate(resolve));

  context.updateArtwork('https://example.com/cover');
  await settle();
  assert.equal(requests, 1);

  // Repeated snapshots inside the backoff window do not refetch.
  context.__now = now + 5_000;
  context.updateArtwork('https://example.com/cover');
  await settle();
  assert.equal(requests, 1);

  // Connectivity returning retries immediately.
  listeners.online();
  await settle();
  assert.equal(requests, 2);

  // After the (doubled) backoff the same URL is requested again and succeeds.
  succeed = true;
  context.__now = now + 5_000 + 30_000;
  context.updateArtwork('https://example.com/cover');
  await settle();
  assert.equal(requests, 3);
  assert.equal(vm.runInContext('artworkData', context), 'DATA');

  // Once loaded, the same URL is never fetched again.
  context.updateArtwork('https://example.com/cover');
  await settle();
  assert.equal(requests, 3);
});
