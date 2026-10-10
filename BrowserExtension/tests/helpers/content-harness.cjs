const { readFileSync } = require('node:fs');
const { webcrypto } = require('node:crypto');
const vm = require('node:vm');
const path = require('node:path');

function eventTarget(target = {}) {
  const listeners = new Map();
  target.addEventListener = (name, callback) => {
    const callbacks = listeners.get(name) ?? [];
    callbacks.push(callback);
    listeners.set(name, callbacks);
  };
  target.dispatch = name => { for (const callback of listeners.get(name) ?? []) callback(); };
  return target;
}

function element(tag = 'div', children = []) {
  return eventTarget({
    nodeType: 1, tag, children, isConnected: true, scans: 0, queries: 0,
    matches(selector) { return selector.split(',').map(s => s.trim()).includes(this.tag); },
    contains(node) { return this.children.some(child => child === node || child.contains(node)); },
    querySelectorAll(selector) {
      this.queries++;
      if (selector === '*') this.scans++;
      const descendants = this.querySelectorAllForTest();
      return selector === '*' ? descendants : descendants.filter(child => child.matches(selector));
    },
    querySelectorAllForTest() { return this.children.flatMap(child => [child, ...child.querySelectorAllForTest()]); },
    getAttribute() { return null; },
    getBoundingClientRect() { return { left: 0, top: 0, right: 200, bottom: 100 }; },
  });
}

function player() {
  return Object.assign(element('video'), {
    readyState: 2, ended: false, paused: false, duration: 120, currentTime: 20,
    playbackRate: 1, seekable: { length: 1, start: () => 0, end: () => 120 },
  });
}

function runContent(children = [], options = {}) {
  const document = Object.assign(element('document', children), {
    nodeType: 9, hidden: options.hidden ?? false,
    title: 'Test media', baseURI: 'https://example.com', querySelector: () => null,
  });
  const window = eventTarget();
  const observers = new Map();
  const timers = new Map();
  const sent = [];
  let onCommand;
  let timerID = 0;
  let now = 0;
  let callbacks = 0;
  function schedule(callback, duration = 0, repeats = false) {
    const id = ++timerID;
    timers.set(id, { callback, duration, repeats, due: now + duration });
    return id;
  }
  const context = vm.createContext({
    document, navigator: {}, location: { hostname: 'example.com', href: 'https://example.com' },
    innerWidth: 800, innerHeight: 600, crypto: webcrypto, URL,
    Date: class extends Date { static now() { return 1_000_000 + now; } },
    addEventListener: window.addEventListener,
    browser: { runtime: {
      onMessage: { addListener: fn => { onCommand = fn; } },
      sendMessage: async message => { sent.push(message); },
    } },
    MutationObserver: class {
      constructor(callback) { this.callback = callback; }
      observe(root) { this.root = root; observers.set(root, this.callback); }
      disconnect() { observers.delete(this.root); }
    },
    setTimeout: (callback, duration) => schedule(callback, duration),
    clearTimeout: id => timers.delete(id),
    setInterval: (callback, duration) => schedule(callback, duration, true),
    clearInterval: id => timers.delete(id),
  });
  vm.runInContext(readFileSync(options.source ?? path.join(__dirname, '../../content.js'), 'utf8'), context);
  function advance(milliseconds) {
    const end = now + milliseconds;
    let iterations = 0;
    while (true) {
      const next = [...timers].sort((a, b) => a[1].due - b[1].due)[0];
      if (!next || next[1].due > end) break;
      if (++iterations > 100_000) throw new Error('Timer loop did not settle');
      const [id, timer] = next;
      now = timer.due;
      timers.delete(id);
      if (timer.repeats) timers.set(id, { ...timer, due: now + timer.duration });
      callbacks++;
      timer.callback();
    }
    now = end;
  }
  return {
    context, document, window, observers, timers, sent, advance,
    get callbacks() { return callbacks; },
    command: message => onCommand(message),
    setHidden(hidden) { document.hidden = hidden; document.dispatch('visibilitychange'); },
  };
}

module.exports = { element, player, runContent };
