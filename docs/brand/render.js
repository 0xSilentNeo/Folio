const { chromium } = require('playwright');
const fs = require('fs');
const { LEAF } = require('./leaf.js');
const variants = {
  primary: { bg: ['#F6F2EC', '#E2DCD3'], page: ['#F3EEE7', '#E6DFD5'], pageShadow: 'rgba(60,45,30,0.22)', leaf: ['#121314', '#2E2F31', '#5A5A5B'], edge: 'rgba(255,255,255,0.55)', leafShadow: 'rgba(30,20,10,0.35)' },
  dark:    { bg: ['#25272B', '#0E0F11'], page: ['#202226', '#16171A'], pageShadow: 'rgba(0,0,0,0.55)', leaf: ['#F2EDE6', '#D9D3CB', '#B5AEA5'], edge: 'rgba(255,255,255,0.6)', leafShadow: 'rgba(0,0,0,0.6)' },
  tinted:  { bg: ['#000000', '#000000'], page: ['#1E1E1E', '#141414'], pageShadow: 'rgba(0,0,0,0.6)', leaf: ['#FFFFFF', '#E6E6E6', '#BDBDBD'], edge: 'rgba(255,255,255,0.7)', leafShadow: 'rgba(0,0,0,0.6)' },
  mono:    { bg: ['#FFFFFF', '#F1F1F1'], page: ['#F7F7F7', '#ECECEC'], pageShadow: 'rgba(0,0,0,0.18)', leaf: ['#000000', '#1C1C1C', '#3A3A3A'], edge: 'rgba(255,255,255,0.5)', leafShadow: 'rgba(0,0,0,0.35)' },
};
function svg(v, size, opts = {}) {
  const s = size / 100;
  const waves = opts.waves ? `
    <g opacity="0.9" filter="url(#blur)">
      <path d="M -10 70 C 20 55, 45 80, 110 50 L 110 110 L -10 110 Z" fill="url(#w1)"/>
      <path d="M -10 40 C 30 25, 55 60, 110 30 L 110 45 C 60 72, 30 40, -10 55 Z" fill="url(#w2)"/>
    </g>` : '';
  const page = opts.noPage ? '' : `<rect x="29" y="22.6" width="51" height="54.8" rx="9.5" fill="url(#pg)" filter="url(#pshadow)"/>
      <rect x="29" y="22.6" width="51" height="54.8" rx="9.5" fill="none" stroke="rgba(255,255,255,0.35)" stroke-width="0.35"/>`;
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 100 100">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="${v.bg[0]}"/><stop offset="1" stop-color="${v.bg[1]}"/></linearGradient>
    <linearGradient id="pg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="${v.page[0]}"/><stop offset="1" stop-color="${v.page[1]}"/></linearGradient>
    <linearGradient id="lf" x1="0.15" y1="0.3" x2="0.75" y2="0.75"><stop offset="0" stop-color="${v.leaf[0]}"/><stop offset="0.55" stop-color="${v.leaf[1]}"/><stop offset="1" stop-color="${v.leaf[2]}"/></linearGradient>
    <linearGradient id="w1" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#3a3a3c"/><stop offset="1" stop-color="#101012"/></linearGradient>
    <linearGradient id="w2" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#2a2a2c"/><stop offset="0.5" stop-color="#4a4a4d"/><stop offset="1" stop-color="#18181a"/></linearGradient>
    <filter id="pshadow" x="-30%" y="-30%" width="160%" height="160%"><feDropShadow dx="0.6" dy="1.4" stdDeviation="1.8" flood-color="${v.pageShadow}"/></filter>
    <filter id="lshadow" x="-30%" y="-30%" width="160%" height="160%"><feDropShadow dx="1.6" dy="1.8" stdDeviation="1.6" flood-color="${v.leafShadow}"/></filter>
    <filter id="blur"><feGaussianBlur stdDeviation="2.2"/></filter>
  </defs>
  <rect width="100" height="100" fill="url(#bg)"/>
  ${waves}
  ${page}
  <path d="${LEAF}" fill="url(#lf)" filter="url(#lshadow)"/>
  <path d="M 70 12.5 C 70.5 30, 66 45, 55 57 C 45 68, 34 73, 27 83" fill="none" stroke="${v.edge}" stroke-width="0.45" stroke-linecap="round"/>
</svg>`;
}
(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1024, height: 1024 }, deviceScaleFactor: 1 });
  const out = process.argv[2] || 'out';
  fs.mkdirSync(out, { recursive: true });
  const jobs = [
    ['icon-1024', variants.primary, {}],
    ['icon-dark-1024', variants.dark, {}],
    ['icon-tinted-1024', variants.tinted, {}],
    ['icon-mono-1024', variants.mono, {}],
    ['icon-alt-1024', { ...variants.dark, bg: ['#1A1B1E', '#050506'], leaf: ['#3C3D40', '#1D1E21', '#6B6B6E'], edge: 'rgba(255,255,255,0.45)', page: ['#141517', '#0E0F10'] }, { waves: true, noPage: true }],
  ];
  for (const [name, v, opts] of jobs) {
    await page.setContent(`<html><body style="margin:0">${svg(v, 1024, opts)}</body></html>`);
    await page.screenshot({ path: `${out}/${name}.png`, clip: { x: 0, y: 0, width: 1024, height: 1024 }, omitBackground: false });
  }
  await browser.close();
})();
