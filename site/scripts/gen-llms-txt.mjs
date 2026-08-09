// Generate the machine-readable discovery artifacts from the SAME registry that
// drives the doc mirrors, so the index can never disagree with what is published.
//   public/llms.txt        — llmstxt.org format, for an agent orienting itself
//   public/docs-index.json — the same set, structured, with raw-source URLs
// Both are gitignored build artifacts. Runs via package.json predev/prebuild.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const siteDir = dirname(dirname(fileURLToPath(import.meta.url)));
const repoRoot = dirname(siteDir);
const REGISTRY = JSON.parse(readFileSync(join(siteDir, 'scripts/docs-registry.json'), 'utf8'));
const VERSION = (readFileSync(join(repoRoot, 'build.zig.zon'), 'utf8')
  .match(/\.version = "([^"]+)"/) || [, 'unknown'])[1];

const BASE = 'https://valthon.github.io/zigbase';
const RAW = 'https://raw.githubusercontent.com/valthon/zigbase/main/';

// Pages authored in the site itself: they have no docs/ canonical, so the
// registry cannot know about them, but an agent still needs them listed.
// Kept in sync with the frontmatter of site/src/content/docs/{overview,
// quick-start,tutorial,configuration}.
const SITE_AUTHORED = [
  { slug: 'overview', title: 'Overview', group: 'getting-started', order: 1,
    description: 'What ZigBase is — a single-binary backend and an embeddable Zig framework — and when to reach for it.' },
  { slug: 'quick-start', title: 'Quick start', group: 'getting-started', order: 2,
    description: 'Install ZigBase, create a superuser, start the server, hit the health endpoint, and open the admin UI.' },
  { slug: 'tutorial', title: 'Tutorial', group: 'getting-started', order: 3,
    description: 'Build a backend on ZigBase end to end, your way — every server step shown both from the embedded admin UI and from the terminal — provision collections, set access rules, register a user, upload a file, configure OAuth2, add a custom route and a cron job.' },
  { slug: 'configuration', title: 'Configuration', group: 'guides', order: 3,
    description: 'The full environment-variable reference, the CLI commands, and the configuration precedence rules for the ZigBase server.' },
];

const GROUPS = [
  ['getting-started', 'Getting started'],
  ['guides', 'Guides'],
  ['features', 'Feature guides'],
  ['reference', 'Reference'],
];

const docs = [
  ...REGISTRY.map((e) => ({
    slug: e.mirror.replace(/\.md$/, ''),
    title: e.frontmatter.title,
    description: e.frontmatter.description,
    group: e.frontmatter.group,
    order: e.frontmatter.order,
    canonical: e.canonical,
    raw_url: RAW + e.canonical,
  })),
  ...SITE_AUTHORED.map((e) => ({ ...e, canonical: null, raw_url: null })),
].map((d) => ({ ...d, url: `${BASE}/docs/${d.slug}` }))
  .sort((a, b) => a.group.localeCompare(b.group) || a.order - b.order);

const byGroup = (id) => docs.filter((d) => d.group === id);

// --- llms.txt (llmstxt.org: H1, blockquote summary, then H2 link sections) ---
const lines = [];
lines.push('# ZigBase');
lines.push('');
lines.push(
  '> A single-binary backend for AI-built and human-built apps: REST API, WebSocket realtime, ' +
  'file storage, argon2id + JWT auth, OAuth2, an admin UI, and an embedded SQLite database ' +
  '(PostgreSQL optional). Use it as a backend-in-a-box over REST, or embed it as a Zig 0.16 ' +
  'framework with a comptime schema, hooks, custom routes, and scheduled jobs.',
);
lines.push('');
lines.push(`Version ${VERSION}. Linux and macOS; Windows is served by the Docker image.`);
lines.push('');
lines.push('Two things to know before you write any code against it: **access rules default to');
lines.push('locked** (a blank rule means superusers only — `"@public"` is the only allow-all');
lines.push('value), and **local plain-HTTP dev needs `--insecure-cookies`** or the admin UI');
lines.push('cannot store its auth cookie. Both are explained in the agent entry doc below.');
lines.push('');
lines.push('## Start here');
lines.push('');
lines.push(`- [ZigBase for coding agents](${BASE}/docs/agents): The ~2k-token orientation — the traps that cost the most time, the response shapes you can rely on, and which guide to load for a given task. Read this first.`);
lines.push(`- [Machine-readable docs index](${BASE}/docs-index.json): Every published doc as JSON, with raw-source URLs.`);
lines.push('');
for (const [id, label] of GROUPS) {
  const items = byGroup(id);
  if (!items.length) continue;
  lines.push(`## ${label}`);
  lines.push('');
  for (const d of items) lines.push(`- [${d.title}](${d.url}): ${d.description}`);
  lines.push('');
}
lines.push('## Optional');
lines.push('');
lines.push('- [Source repository](https://github.com/valthon/zigbase): Issues, releases, and the canonical Markdown behind every page above.');
lines.push('');

mkdirSync(join(siteDir, 'public'), { recursive: true });
writeFileSync(join(siteDir, 'public/llms.txt'), lines.join('\n'));
writeFileSync(
  join(siteDir, 'public/docs-index.json'),
  JSON.stringify({
    name: 'zigbase',
    version: VERSION,
    site: BASE,
    llms_txt: `${BASE}/llms.txt`,
    generated_from: 'site/scripts/docs-registry.json',
    groups: Object.fromEntries(GROUPS),
    docs,
  }, null, 2) + '\n',
);
console.log(`gen-llms-txt: public/llms.txt + public/docs-index.json (${docs.length} docs, v${VERSION})`);
