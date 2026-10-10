const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

const { element, player, runContent } = require('./helpers/content-harness.cjs');

test('media heartbeats reuse discovery without scanning every page element', () => {
  const media = player();
  const page = runContent([media, ...Array.from({ length: 1000 }, () => element())]);
  page.advance(100);
  assert.equal(page.document.scans, 1);
  page.advance(8000);
  assert.equal(page.document.scans, 1);
  assert.equal(page.sent[0].kind, 'notchrouter_media');
  assert.ok(page.sent[0].document_session_id);
});

test('mutation bursts scan only added subtrees and discover shadow-root media', () => {
  const page = runContent();
  page.advance(100);
  const media = player();
  const nestedHost = element('nested-player');
  const nestedShadow = Object.assign(element('shadow', [media]), { nodeType: 11, host: nestedHost });
  nestedHost.shadowRoot = nestedShadow;
  const shadow = Object.assign(element('shadow', [nestedHost]), { nodeType: 11 });
  const host = element('custom-player');
  shadow.host = host;
  host.shadowRoot = shadow;
  page.document.children.push(host);
  const notify = page.observers.get(page.document);
  for (let mutation = 0; mutation < 100; mutation++) notify([{ addedNodes: [host] }]);
  assert.equal(page.timers.size, 2, 'one discovery debounce plus the fallback reconciliation');
  page.advance(100);
  page.advance(100);
  assert.equal(page.document.scans, 1, 'mutations do not rescan the document');
  assert.equal(host.scans, 1);
  assert.equal(shadow.scans, 1);
  assert.equal(page.sent.at(-1).kind, 'notchrouter_media');
  assert.ok(page.observers.has(shadow));

  host.isConnected = false;
  nestedHost.isConnected = false;
  media.isConnected = false;
  page.document.children = [];
  page.advance(1000);
  assert.equal(page.sent.at(-1).kind, 'notchrouter_media_ended');
  assert.ok(!page.observers.has(shadow), 'removed shadow roots release their observers');
});

test('periodic reconciliation finds shadow roots attached to existing hosts', () => {
  const host = element('custom-player');
  const page = runContent([host]);
  const shadow = Object.assign(element('shadow', [player()]), { nodeType: 11, host });
  host.shadowRoot = shadow;
  page.advance(10000);
  page.advance(100);
  assert.equal(page.sent.at(-1).kind, 'notchrouter_media');
});

test('commands addressed to a replaced Firefox document are ignored', () => {
  const media = player();
  const page = runContent([media]);
  page.advance(100);
  page.command({ kind: 'notchrouter_command', command: 'seek', seek_position: 80, document_session_id: 'old-document' });
  assert.equal(media.currentTime, 20);
  page.command({ kind: 'notchrouter_command', command: 'seek', seek_position: 80,
    document_session_id: page.sent[0].document_session_id });
  assert.equal(media.currentTime, 80);
});

test('empty pages have no media polling and hidden reconciliation backs off', () => {
  const visible = runContent([element()]);
  visible.advance(60_000);
  assert.equal(visible.sent.length, 0);
  assert.ok(visible.callbacks <= 6, 'empty visible frames only reconcile late shadow roots');
  const hidden = runContent([element()], { hidden: true });
  hidden.advance(60_000);
  assert.equal(hidden.sent.length, 0);
  assert.equal(hidden.callbacks, 1);

  const media = player();
  hidden.document.children.push(media);
  hidden.observers.get(hidden.document)([{ addedNodes: [media] }]);
  hidden.advance(200);
  assert.equal(hidden.sent.at(-1).media.is_playing, true, 'new media is discovered promptly in hidden tabs');
});

test('paused and hidden media heartbeat slowly but play, seek and visibility changes stay responsive', () => {
  const media = player();
  media.paused = true;
  const page = runContent([media]);
  page.advance(100);
  let count = page.callbacks;
  page.advance(4000);
  assert.equal(page.callbacks, count, 'paused media has no one-second polling');
  page.advance(1000);
  assert.equal(page.sent.length, 2, 'paused media remains connected');

  media.paused = false;
  media.dispatch('play');
  page.advance(100);
  assert.equal(page.sent.at(-1).media.is_playing, true);
  media.currentTime = 30;
  page.advance(1000);
  assert.equal(page.sent.at(-1).media.position, 30);

  page.setHidden(true);
  page.advance(100);
  count = page.callbacks;
  page.advance(4000);
  assert.equal(page.callbacks, count);
  page.command({ kind: 'notchrouter_command', command: 'seek', seek_position: 80 });
  page.advance(150);
  assert.equal(page.sent.at(-1).media.position, 80, 'commands do not wait for a heartbeat');
  const sent = page.sent.length;
  page.advance(5000);
  assert.ok(page.sent.length > sent, 'hidden playback stays connected');

  page.setHidden(false);
  page.advance(100);
  media.currentTime = 81;
  page.advance(1000);
  assert.equal(page.sent.at(-1).media.position, 81);
});

test('foregrounding discovers a late shadow player immediately', () => {
  const host = element('custom-player');
  const page = runContent([host], { hidden: true });
  host.shadowRoot = Object.assign(element('shadow', [player()]), { nodeType: 11, host });
  page.advance(5000);
  assert.equal(page.sent.length, 0);
  page.setHidden(false);
  page.advance(100);
  assert.equal(page.sent.at(-1).kind, 'notchrouter_media');
});

test('pagehide releases timers and observers and pageshow restores media after back navigation', () => {
  const media = player();
  const page = runContent([media]);
  page.advance(100);
  page.command({ kind: 'notchrouter_command', command: 'seek', seek_position: 80 });
  page.window.dispatch('pagehide');
  assert.equal(page.sent.at(-1).kind, 'notchrouter_media_ended');
  assert.equal(page.timers.size, 0);
  assert.equal(page.observers.size, 0);
  const count = page.callbacks;
  media.dispatch('pause');
  page.advance(60_000);
  assert.equal(page.callbacks, count);
  page.window.dispatch('pageshow');
  page.advance(100);
  assert.equal(page.sent.at(-1).kind, 'notchrouter_media');
  assert.ok(page.observers.has(page.document));
  media.paused = true;
  media.dispatch('pause');
  page.advance(100);
  assert.equal(page.sent.at(-1).media.is_playing, false);
});

test('ending the last player removes its heartbeat', () => {
  const media = player();
  const page = runContent([media]);
  page.advance(100);
  media.ended = true;
  media.dispatch('ended');
  page.advance(100);
  assert.equal(page.sent.at(-1).kind, 'notchrouter_media_ended');
  const count = page.callbacks;
  page.advance(5000);
  assert.equal(page.callbacks, count);
});

test('Firefox startup works without download permission and registers listeners after opt-in', async () => {
  const listeners = {};
  const storage = {};
  const nativeMessages = [];
  let gesture = false;
  let requestedDuringGesture = false;
  const event = name => ({ addListener: callback => { listeners[name] = callback; } });
  const api = {
    runtime: { getBrowserInfo: async () => ({ name: 'Firefox' }),
      onMessage: event('message'), connectNative: () => ({
      onMessage: event('native'), onDisconnect: event('disconnect'), postMessage: message => nativeMessages.push(message),
    }) },
    tabs: { onRemoved: event('removed'), onUpdated: event('updated'), sendMessage: async () => {} },
    action: { onClicked: event('clicked'), setBadgeText: async () => {},
      setBadgeBackgroundColor: async () => {}, setTitle: async () => {} },
    storage: { local: { get: async () => storage, set: async values => Object.assign(storage, values) } },
    permissions: { onRemoved: event('permissionRemoved'), contains: async () => false,
      remove: async () => true, request: async options => {
        requestedDuringGesture = gesture;
        assert.deepEqual(Array.from(options.data_collection), ['websiteActivity']);
        return true;
      } },
  };
  const context = vm.createContext({
    browser: api, navigator: { userAgent: 'Firefox/151' }, URL,
    setInterval: () => 1, clearInterval() {},
  });
  vm.runInContext(readFileSync(path.join(__dirname, '../background.js'), 'utf8'), context);
  await vm.runInContext('downloadsReady', context);
  assert.equal(listeners.created, undefined);
  api.downloads = { onCreated: event('created'), onChanged: event('changed'), onErased: event('erased'), search: async () => [] };
  gesture = true;
  const enabling = listeners.clicked();
  gesture = false;
  await enabling;
  assert.equal(requestedDuringGesture, true);
  assert.equal(storage.downloadsEnabled, true);
  assert.equal(typeof listeners.created, 'function');
  let finishSearch;
  api.downloads.search = () => new Promise(resolve => { finishSearch = resolve; });
  const pendingHeartbeat = context.sendDownloadHeartbeat();
  await listeners.clicked();
  assert.equal(storage.downloadsEnabled, false);
  finishSearch([{ id: 1, filename: 'private.txt', state: 'in_progress' }]);
  await pendingHeartbeat;
  assert.equal(nativeMessages.filter(message => message.kind === 'download_update').length, 0);
  assert.equal(nativeMessages.at(-1).kind, 'downloads_disabled');
});
