import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';

const out = new URL('../zig-out/site/', import.meta.url).pathname;
const fail = (message) => { throw new Error(message); };
const read = (path) => readFileSync(join(out, path), 'utf8');

const required = [
  'index.html', 'compare/index.html', 'download/index.html', 'docs/index.html',
  'docs/overview/index.html', 'docs/quick-start/index.html', 'docs/tutorial/index.html',
  'docs/api/index.html', 'examples/index.html', 'examples/blog/index.html',
  'examples/golfsim/index.html', 'examples/plugins/index.html', 'llms.txt',
  'docs-index.json', 'sitemap.xml', 'robots.txt',
];
for (const path of required) if (!existsSync(join(out, path))) fail(`missing ${path}`);

const htmlFiles = [];
function walk(dir) {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) walk(path);
    else if (name.endsWith('.html')) htmlFiles.push(path);
  }
}
walk(out);
if (htmlFiles.length < 36) fail(`expected at least 36 pages, found ${htmlFiles.length}`);

for (const path of htmlFiles) {
  const html = readFileSync(path, 'utf8');
  const label = relative(out, path);
  if (!/<main\b/.test(html) || !/<h1\b/.test(html)) fail(`${label}: missing main or h1`);
  if (!/<meta name="description" content="[^"]+"/.test(html)) fail(`${label}: empty description`);
  if (!/<link rel="canonical" href="https:\/\/valthon\.github\.io\/zigbase\//.test(html)) fail(`${label}: bad canonical URL`);
  if (!/<meta property="og:image" content="https:\/\//.test(html)) fail(`${label}: og:image is not absolute`);
  if (/data-astro|astro:page-load|\/_astro\//i.test(html)) fail(`${label}: stale framework artifact`);
  const mainStart = html.indexOf('<main');
  const mainEnd = html.indexOf('</main>');
  if (mainStart >= 0) {
    const main = html.slice(mainStart, mainEnd > mainStart ? mainEnd : html.length);
    let level = null;
    for (const match of main.matchAll(/<h([1-6])\b/g)) {
      const heading = Number(match[1]);
      if (level !== null && heading > level + 1) fail(`${label}: heading order skips h${level + 1} -> h${heading}`);
      level = heading;
    }
  }
  for (const match of html.matchAll(/(?:href|src)="(\/zigbase\/[^"#?]*)/g)) {
    const urlPath = match[1].slice('/zigbase/'.length);
    if (!urlPath) continue;
    const candidate = join(out, urlPath);
    if (!existsSync(candidate) && !existsSync(join(candidate, 'index.html'))) fail(`${label}: dangling ${match[1]}`);
  }
}

const home = read('index.html');
const repoVersion = readFileSync(join(out, '..', '..', '..', 'build.zig.zon'), 'utf8')
  .match(/\.version\s*=\s*"([^"]+)"/)?.[1];
if (!repoVersion || !home.includes(`v${repoVersion}`) || !read('download/index.html').includes(`v${repoVersion}`)) {
  fail(`published version drifted from build.zig.zon (${repoVersion ?? 'unknown'})`);
}
for (const phrase of ['single binary', 'SQLite', 'Postgres', 'Ready out of the box', 'Real apps', 'TypeScript SDK']) {
  if (!home.includes(phrase)) fail(`landing page lost: ${phrase}`);
}
if (!home.includes('application/ld+json')) fail('landing page missing JSON-LD');
const docs = read('docs/api/index.html');
for (const marker of ['id="docs-filter"', 'class="docs-sidebar"', 'class="docs-toc"', 'aria-current']) {
  if (!docs.includes(marker)) fail(`docs shell missing ${marker}`);
}
const cssFiles = readdirSync(out).filter((name) => name.endsWith('.css'));
const css = cssFiles.map((name) => read(name)).join('\n');
for (const marker of [':focus-visible', 'prefers-reduced-motion', '@media(max-width:48rem)']) {
  if (!css.includes(marker)) fail(`accessibility/responsive CSS missing ${marker}`);
}
if (!read('robots.txt').includes('https://valthon.github.io/zigbase/sitemap.xml')) fail('robots sitemap URL drifted');
if (!read('sitemap.xml').includes(`${htmlFiles.length > 0 ? 'https://valthon.github.io/zigbase/docs/api/' : ''}`)) fail('sitemap missing API route');
const index = JSON.parse(read('docs-index.json'));
if (index.docs.length !== 42) fail(`docs index expected 42 docs, found ${index.docs.length}`);
if (!read('docs/resumable-uploads/index.html').includes('Commit retries and uncertain outcomes')) {
  fail('resumable upload limitations were not published');
}
const thumbnails = read('docs/thumbnails/index.html');
for (const contract of ['Resource tuning', 'max_pixels', 'thumbnail_busy', 'ImageMagick', 'must-revalidate', 'ZIGBASE_IMAGEMAGICK_EXECUTABLE']) {
  if (!thumbnails.includes(contract)) fail(`thumbnail contract missing from published page: ${contract}`);
}
if (!read('docs/framework/index.html').includes('image-thumbnails')) {
  fail('thumbnail opt-in build flag missing from framework reference');
}
for (const path of ['docs/resumable-uploads/index.html', 'docs-index.json', 'llms.txt']) {
  const content = read(path);
  if (!content.includes('SQLite/local restart persistence') || content.includes('not restart-durable streaming')) {
    fail(`${path}: resumable upload durability metadata is stale`);
  }
}
if (!read('docs/two-factor-design/index.html').includes('Compile-time and runtime configuration')) {
  fail('two-factor documentation was not published');
}
console.log(`PASS: ${htmlFiles.length} pages, metadata, links, discovery, accessibility contracts`);
