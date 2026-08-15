// Deterministic content pipeline for the Zigapagos public site. Canonical
// repository docs and site-authored guides both become generated SuperMD;
// edit their sources, never the emitted content/*.smd mirrors.
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { frontmatter, transformBody } from './md-to-smd.ts';

type Entry = {
  canonical: string;
  mirror: string;
  frontmatter: { title: string; description: string; order: number; group: string };
};

const SITE = dirname(dirname(fileURLToPath(import.meta.url)));
const REPO = dirname(SITE);
const BASE = 'https://valthon.github.io/zigbase';
const RAW = 'https://raw.githubusercontent.com/valthon/zigbase/main/';
const BLOB = 'https://github.com/valthon/zigbase/blob/main/';
const TREE = 'https://github.com/valthon/zigbase/tree/main/';
const REGISTRY: Entry[] = JSON.parse(readFileSync(join(SITE, 'scripts/docs-registry.json'), 'utf8'));

const AUTHORED = [
  { slug: 'overview', title: 'Overview', description: 'What ZigBase is — a single-binary backend and an embeddable Zig framework — and when to reach for it.', group: 'getting-started', order: 1 },
  { slug: 'quick-start', title: 'Quick start', description: 'Install ZigBase, create a superuser, start the server, hit the health endpoint, and open the admin UI.', group: 'getting-started', order: 2 },
  { slug: 'tutorial', title: 'Tutorial', description: 'Build a backend end to end through the embedded admin UI or the terminal: collections, rules, auth, files, OAuth2, a route, and a cron job.', group: 'getting-started', order: 3 },
  { slug: 'configuration', title: 'Configuration', description: 'The full environment-variable reference, CLI commands, and configuration precedence rules for the ZigBase server.', group: 'guides', order: 3 },
] as const;

const EXAMPLES = [
  { slug: 'blog', title: 'Blog', description: 'A minimal app on ZigBase-as-a-library: a slugify hook and a Zigapagos frontend served from a runtime-selected directory.' },
  { slug: 'golfsim', title: 'Golf simulator booking', description: 'A realistic app with hooks, business routes, a DB-touching cron, and a Zigapagos frontend from a comptime static directory.' },
  { slug: 'plugins', title: 'Plugins & comptime config', description: 'The advanced framework surface: plugins, schema, migrations, pool levers, and a Zigapagos frontend embedded in the executable.' },
] as const;

const published = new Map<string, string>([
  ...REGISTRY.map((entry) => [entry.canonical, `docs/${entry.mirror.replace(/\.md$/, '')}`] as const),
  ...REGISTRY.filter((entry) => entry.canonical.startsWith('docs/')).map((entry) =>
    [entry.canonical.replace(/\.md$/, ''), `docs/${entry.mirror.replace(/\.md$/, '')}`] as const),
  ...AUTHORED.map((entry) => [`site/sources/docs/${entry.slug}.md`, `docs/${entry.slug}`] as const),
  ...AUTHORED.map((entry) => [`docs/${entry.slug}.md`, `docs/${entry.slug}`] as const),
  ['known-limitations', 'docs/known-limitations'],
  ['site/sources/examples', 'examples'],
  ...EXAMPLES.map((entry) => [`examples/${entry.slug}`, `examples/${entry.slug}`] as const),
  ...EXAMPLES.map((entry) => [`site/sources/examples/${entry.slug}`, `examples/${entry.slug}`] as const),
]);

function stripBanner(body: string): string {
  return body.replace(/(^|\n)> 📖 This documentation is also published[^\n]*(\n>[^\n]*)*\n?/, '$1');
}

function normalizeCanonicalSyntax(body: string, canonicalPath: string): string {
  const anchorAliases: Record<string, string> = {
    'auth-methods-pluggable': 'auth-methods-overview',
    'captcha-verification-ctxverifycaptcha': 'ctxverifycaptcha--captcha-verification-140',
    'encryption-at-rest': 'encryption-at-rest-encrypted',
    'who-may-subscribe-realtime---cansubscribe--fn': 'who-may-subscribe-realtime---cansubscribe--fn-',
  };
  let output = body
    .replace(/<a id="spa-fallback"><\/a>/g, '\n\n#### SPA fallback\n')
    .replace(/(^\s*>?\s*`{3,})jsonc\s*$/gm, '$1json')
    .replace(/(^\s*>?\s*`{3,})(?:text|txt|dart)\s*$/gm, '$1');
  if (canonicalPath.startsWith('docs/')) {
    output = output.replace(/\]\(docs\/([a-z0-9-]+\.md(?:#[^)]+)?)\)/g, '](./$1)');
  }
  for (const [from, to] of Object.entries(anchorAliases)) {
    const escaped = from.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    output = output
      .replace(new RegExp(`#${escaped}(?=[)\\s"'])`, 'g'), `#${to}`)
      .replaceAll(`.ref("${from}")`, `.ref("${to}")`);
  }
  return output;
}

function stripYaml(body: string): string {
  return body.replace(/^---\r?\n[\s\S]*?\r?\n---\r?\n/, '');
}

function imageToken(file: string, alt: string): string {
  return `ZBIMAGE_${Buffer.from(file).toString('hex')}_${Buffer.from(alt).toString('hex')}`;
}

function restoreImages(body: string): string {
  return body.replace(/^(\s*)ZBIMAGE_([0-9a-f]+)_([0-9a-f]+)$/gm, (_match, indent, fileHex, altHex) => {
    const file = Buffer.from(fileHex, 'hex').toString();
    const alt = Buffer.from(altHex, 'hex').toString();
    const safeLabel = alt.replaceAll('[', '\\[').replaceAll(']', '\\]');
    return `${indent}[${safeLabel}](<$image.siteAsset("screenshots/${file}").alt(${JSON.stringify(alt)})>)`;
  });
}

function sourceImages(body: string): string {
  return body.replace(/!\[([^\]]*)\]\(\.\.\/\.\.\/assets\/screenshots\/([^)]+)\)/g,
    (_match, alt, file) => imageToken(file, alt));
}

function authoredLinks(body: string): string {
  return body
    .replace(/\]\(\.\.\/download\)/g, ']($link.page("download"))')
    .replace(/\]\(\.\.\/docs\/([a-z0-9-]+)(#[^)]+)?\)/g, (_m, slug, hash = '') =>
      `]($link.page("docs/${slug}")${hash ? `.ref(${JSON.stringify(hash.slice(1))})` : ''})`)
    .replace(/\]\(\.\/([a-z0-9-]+)(#[^)]+)?\)/g, (_m, slug, hash = '') =>
      `]($link.page("docs/${slug}")${hash ? `.ref(${JSON.stringify(hash.slice(1))})` : ''})`)
    .replace(/<a id="([^"]+)"><\/a>/g, (_m, id) => `[]($heading.id(${JSON.stringify(id)}))`);
}

function cleanAuthored(body: string): string {
  return authoredLinks(sourceImages(stripYaml(body)));
}

function cleanExample(body: string): string {
  return authoredLinks(sourceImages(stripYaml(body)));
}

function convert(body: string, canonicalPath: string): string {
  return restoreImages(transformBody(normalizeCanonicalSyntax(body, canonicalPath), {
    canonicalPath,
    published,
    githubBlobBase: BLOB,
    githubTreeBase: TREE,
    fenceLangRemap: { jsonc: 'json', nginx: 'conf' },
    stripLeadingTitle: true,
    onOffsiteLink: (canonical, target, resolved) =>
      console.warn(`gen-content: [${canonical}] "${target}" → GitHub (${resolved})`),
  }));
}

for (const section of ['docs', 'examples']) {
  const generatedDir = join(SITE, 'content', section);
  rmSync(generatedDir, { recursive: true, force: true });
  mkdirSync(generatedDir, { recursive: true });
}

writeFileSync(join(SITE, 'content/docs/index.smd'), frontmatter({
  title: 'Documentation — ZigBase',
  description: 'Guides and reference for building, operating, and extending ZigBase.',
  layout: 'docs-index.shtml',
}));
writeFileSync(join(SITE, 'content/examples/index.smd'), frontmatter({
  title: 'Examples — ZigBase',
  description: 'Three buildable ZigBase applications, from a minimal packaging proof to the full framework surface.',
  layout: 'examples-index.shtml',
}));

for (const entry of REGISTRY) {
  const slug = entry.mirror.replace(/\.md$/, '');
  const raw = stripBanner(readFileSync(join(REPO, entry.canonical), 'utf8'));
  const output = frontmatter({
    title: `${entry.frontmatter.title} — ZigBase`,
    description: entry.frontmatter.description,
    layout: 'docs.shtml',
    custom: { slug, canonical: entry.canonical },
  }) + convert(raw, entry.canonical);
  writeFileSync(join(SITE, 'content/docs', `${slug}.smd`), output);
  console.log(`gen-content: docs/${slug}.smd <- ${entry.canonical}`);
}

for (const entry of AUTHORED) {
  const canonical = `site/sources/docs/${entry.slug}.md`;
  const raw = cleanAuthored(readFileSync(join(REPO, canonical), 'utf8'));
  const output = frontmatter({
    title: `${entry.title} — ZigBase`, description: entry.description,
    layout: 'docs.shtml', custom: { slug: entry.slug, canonical },
  }) + convert(raw, canonical);
  writeFileSync(join(SITE, 'content/docs', `${entry.slug}.smd`), output);
}

for (const entry of EXAMPLES) {
  const canonical = `site/sources/examples/${entry.slug}.md`;
  const raw = cleanExample(readFileSync(join(REPO, canonical), 'utf8'));
  const output = frontmatter({
    title: `${entry.title} — ZigBase examples`, description: entry.description,
    layout: 'example.shtml', custom: { slug: entry.slug, canonical },
  }) + convert(raw, canonical);
  writeFileSync(join(SITE, 'content/examples', `${entry.slug}.smd`), output);
}

const version = (readFileSync(join(REPO, 'build.zig.zon'), 'utf8').match(/\.version\s*=\s*"([^"]+)"/) ?? [])[1] ?? 'unknown';
const docs = [
  ...REGISTRY.map((entry) => ({
    slug: entry.mirror.replace(/\.md$/, ''), title: entry.frontmatter.title,
    description: entry.frontmatter.description, group: entry.frontmatter.group,
    order: entry.frontmatter.order, canonical: entry.canonical, raw_url: RAW + entry.canonical,
  })),
  ...AUTHORED.map((entry) => ({ ...entry, canonical: null, raw_url: null })),
].map((entry) => ({ ...entry, url: `${BASE}/docs/${entry.slug}/` }))
  .sort((a, b) => a.group.localeCompare(b.group) || a.order - b.order);

const groups: Record<string, string> = {
  'getting-started': 'Getting started', guides: 'Guides', features: 'Feature guides', reference: 'Reference',
};
const llms = [
  '# ZigBase', '',
  '> A single-binary backend for AI-built and human-built apps: REST API, realtime, storage, auth, an admin UI, SQLite or PostgreSQL, and an embeddable Zig framework.', '',
  `Version ${version}. Linux and macOS; Windows is served by the Docker image.`, '',
  'Access rules default to locked, and local plain-HTTP development needs --insecure-cookies. Start with the coding-agent orientation below.', '',
  '## Start here', '',
  `- [ZigBase for coding agents](${BASE}/docs/agents/): The compact orientation and highest-cost traps.`,
  `- [Machine-readable docs index](${BASE}/docs-index.json): Every published guide with raw-source URLs.`, '',
];
for (const [id, label] of Object.entries(groups)) {
  llms.push(`## ${label}`, '');
  for (const doc of docs.filter((item) => item.group === id)) llms.push(`- [${doc.title}](${doc.url}): ${doc.description}`);
  llms.push('');
}
llms.push('## Optional', '', '- [Source repository](https://github.com/valthon/zigbase): Issues, releases, examples, and canonical Markdown.', '');
writeFileSync(join(SITE, 'assets/llms.txt'), llms.join('\n'));
writeFileSync(join(SITE, 'assets/docs-index.json'), JSON.stringify({
  name: 'zigbase', version, site: BASE, llms_txt: `${BASE}/llms.txt`, generated_from: 'site/scripts/docs-registry.json', groups, docs,
}, null, 2) + '\n');

const routes = ['', 'compare/', 'download/', 'docs/', 'examples/',
  ...docs.map((doc) => `docs/${doc.slug}/`), ...EXAMPLES.map((entry) => `examples/${entry.slug}/`)];
writeFileSync(join(SITE, 'assets/sitemap.xml'),
  '<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n' +
  routes.map((route) => `  <url><loc>${BASE}/${route}</loc></url>`).join('\n') + '\n</urlset>\n');
writeFileSync(join(SITE, 'assets/robots.txt'), `User-agent: *\nAllow: /\nSitemap: ${BASE}/sitemap.xml\n`);
