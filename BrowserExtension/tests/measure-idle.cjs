// Deterministic work counts, not browser CPU or energy measurements.
// An optional content.js path allows comparison against a saved baseline.
const { element, player, runContent } = require('./helpers/content-harness.cjs');

for (const scenario of ['empty-visible', 'empty-hidden', 'paused-hidden', 'playing-visible']) {
  const media = scenario.startsWith('empty') ? [] : [player()];
  if (scenario.startsWith('paused')) media[0].paused = true;
  const page = runContent([...media, ...Array.from({ length: 1000 }, () => element())], {
    hidden: scenario.endsWith('hidden'), source: process.argv[2],
  });
  page.advance(200);
  const before = { callbacks: page.callbacks, scans: page.document.scans,
    queries: page.document.queries, messages: page.sent.length };
  page.advance(60_000);
  console.log(JSON.stringify({ scenario, simulatedSeconds: 60, elements: 1000,
    timerCallbacks: page.callbacks - before.callbacks,
    fullDocumentScans: page.document.scans - before.scans,
    selectorQueries: page.document.queries - before.queries,
    messages: page.sent.length - before.messages,
  }));
}
