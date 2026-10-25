const {chromium} = require('playwright');
const path = require('node:path');
const {pathToFileURL} = require('node:url');

(async () => {
  const browser = await chromium.launch({headless: true, ...(process.env.CHROME_BIN ? {executablePath: process.env.CHROME_BIN} : {})});
  try {
    const root = path.resolve(__dirname, '../..');
    const page = await browser.newPage({deviceScaleFactor: 1});
    const outputs = [
      ['hero', 'banner.png', 1600, 1000],
      ['social', 'social-preview.png', 1280, 640],
      ['notes', 'feature-notes.png', 1600, 900],
      ['library', 'feature-library.png', 1600, 900],
      ['dark', 'feature-dark.png', 1600, 900],
    ];
    for (const [art, file, width, height] of outputs) {
      await page.setViewportSize({width, height});
      const url = pathToFileURL(path.join(__dirname, 'visuals.html')); url.searchParams.set('art', art);
      await page.goto(url.href);
      await page.evaluate(async () => {
        await document.fonts.ready;
        await Promise.all([...document.images].map(img => img.decode()));
      });
      await page.locator('#art').screenshot({path: path.join(root, 'docs/media', file)});
      console.log(file, width, height);
    }
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
