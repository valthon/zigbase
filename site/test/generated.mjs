import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const site = new URL('..', import.meta.url).pathname;
const generated = () => [
  ...readdirSync(join(site, 'content', 'docs')).sort().map((name) => join('content', 'docs', name)),
  ...readdirSync(join(site, 'content', 'examples')).sort().map((name) => join('content', 'examples', name)),
  ...['llms.txt', 'docs-index.json', 'sitemap.xml', 'robots.txt'].map((name) => join('assets', name)),
];
const digest = () => createHash('sha256')
  .update(generated().map((path) => `${path}\0${readFileSync(join(site, path))}`).join('\0'))
  .digest('hex');
const generate = () => execFileSync(process.execPath,
  ['--experimental-strip-types', 'scripts/gen-content.ts'], { cwd: site, stdio: 'inherit' });

generate();
const first = digest();
generate();
const second = digest();
if (first !== second) throw new Error(`generated site content drifted: ${first} != ${second}`);
console.log(`PASS: deterministic generated content ${second}`);
