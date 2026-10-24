const { chromium } = require('playwright');
const { LEAF } = require('./leaf.js');
const fs = require('fs');
const kinds = { light: ['#121314', '#2E2F31', '#5A5A5B', 'rgba(255,255,255,0.5)'], dark: ['#F2EDE6', '#D9D3CB', '#B5AEA5', 'rgba(255,255,255,0.6)'] };
(async () => {
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: 400, height: 400 } });
  fs.mkdirSync('mark', { recursive: true });
  for (const [k, c] of Object.entries(kinds)) for (const scale of [1, 2, 3]) {
    const px = 96 * scale;
    await p.setContent(`<html><body style="margin:0;background:transparent"><svg xmlns="http://www.w3.org/2000/svg" width="${px}" height="${px}" viewBox="0 0 100 100">
      <defs><linearGradient id="lf" x1="0.15" y1="0.3" x2="0.75" y2="0.75"><stop offset="0" stop-color="${c[0]}"/><stop offset="0.55" stop-color="${c[1]}"/><stop offset="1" stop-color="${c[2]}"/></linearGradient></defs>
      <path d="${LEAF}" fill="url(#lf)"/>
      <path d="M 70 12.5 C 70.5 30, 66 45, 55 57 C 45 68, 34 73, 27 83" fill="none" stroke="${c[3]}" stroke-width="0.45" stroke-linecap="round"/></svg></body></html>`);
    await p.screenshot({ path: `mark/launch-${k}@${scale}x.png`, clip: { x: 0, y: 0, width: px, height: px }, omitBackground: true });
  }
  await b.close();
})();
