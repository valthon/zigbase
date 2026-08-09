// Generate site doc mirrors from canonical sources. Mirrors under
// site/src/content/docs/ are gitignored build artifacts — edit the canonical
// (repo-root CHANGELOG.md/KNOWN_LIMITATIONS.md, or docs/*.md), never the mirror.
// Runs via package.json predev/prebuild (CI/release use `npm run build`).
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const siteDir = dirname(dirname(fileURLToPath(import.meta.url)));
const repoRoot = dirname(siteDir);
const REGISTRY = JSON.parse(readFileSync(join(siteDir, 'scripts/docs-registry.json'), 'utf8'));

// Every published doc-route name (mirror .md basenames + the site-authored .mdx
// pages) — a link to one of these resolves to `./<route>`; anything else in the
// repo becomes a GitHub URL.
const PUBLISHED = new Set([
  'abilities', 'analytics', 'api', 'changelog', 'configuration', 'dart-sdk',
  'docker', 'email', 'fields', 'framework', 'jobs-and-webhooks', 'known-limitations',
  'kotlin-sdk', 'migration-tools', 'observability', 'overview', 'postgres', 'python-sdk',
  'quick-start', 'realtime-broadcast', 'recipes', 'search', 'serve', 'tenancy', 'tutorial',
  'typescript-sdk',
]);
// Root canonicals linked by UPPER_CASE basename → their route.
const ROOT_ROUTE = new Map([['CHANGELOG', 'changelog'], ['KNOWN_LIMITATIONS', 'known-limitations']]);
const BLOB = 'https://github.com/valthon/zigbase/blob/main/';
const TREE = 'https://github.com/valthon/zigbase/tree/main/';

// Strip the canonical-only "also published on the site" banner blockquote wherever
// it sits (it usually follows the H1). Matches the blockquote line(s) + trailing blank.
function stripBanner(body) {
  return body.replace(/(^|\n)> 📖 This documentation is also published[^\n]*(\n>[^\n]*)*\n?/, '$1');
}

// Resolve a relative link target to a repo-root-relative path, given the canonical's
// directory (`docs` for docs/*.md, `` for the root CHANGELOG/KNOWN_LIMITATIONS).
function resolveRepoPath(path, canonicalDir) {
  const stack = canonicalDir ? canonicalDir.split('/') : [];
  for (const p of path.split('/')) {
    if (p === '' || p === '.') continue;
    else if (p === '..') stack.pop();
    else stack.push(p);
  }
  return stack.join('/');
}

// Rewrite link TARGETS (never text). `.md` links to a published doc → `./route`;
// any other repo file/dir (../README.md, ../clients/…, ../examples/blog/) → a
// GitHub URL; absolute + in-page links untouched. Warn on the GitHub fallback.
function rewriteLinks(body, canonicalPath) {
  const dir = canonicalPath.includes('/') ? canonicalPath.slice(0, canonicalPath.lastIndexOf('/')) : '';
  return body.replace(/\]\(([^)\s]+)\)/g, (m, target) => {
    const h = target.indexOf('#');
    const path = h >= 0 ? target.slice(0, h) : target;
    const anchor = h >= 0 ? target.slice(h) : '';
    if (path === '') return m;                       // in-page #anchor
    if (/^(https?:|mailto:)/i.test(path)) return m;  // absolute
    if (path.startsWith('/')) return m;              // root-absolute path: leave as authored
    const isMd = path.endsWith('.md');
    const isRel = path.startsWith('../') || path.startsWith('./') || !path.includes(':');
    if (!isMd && !path.startsWith('../')) return m;  // only .md links and ../ repo links
    if (!isRel) return m;
    const repoPath = resolveRepoPath(path, dir);
    if (repoPath.startsWith('docs/') && repoPath.endsWith('.md')) {
      const name = repoPath.slice(5, -3);
      if (PUBLISHED.has(name)) return `](./${name}${anchor})`;
    }
    if (repoPath.endsWith('.md') && !repoPath.includes('/')) {
      const stem = repoPath.slice(0, -3);
      if (ROOT_ROUTE.has(stem)) return `](./${ROOT_ROUTE.get(stem)}${anchor})`;
    }
    console.warn(`gen-docs-mirror: [${canonicalPath}] "${path}" → GitHub (${repoPath})`);
    // Directory links (trailing slash on the ORIGINAL target — resolveRepoPath strips
    // it) get a tree URL; file links get a blob URL.
    const url = (path.endsWith('/') ? TREE : BLOB) + repoPath;
    return `](${url}${anchor})`;
  });
}

function frontmatter(fm) {
  // JSON.stringify each string value — a JSON string is a valid YAML double-quoted
  // scalar, so a title/description containing a `:` or `"` can't corrupt the frontmatter.
  const q = (v) => JSON.stringify(String(v));
  return `---\ntitle: ${q(fm.title)}\ndescription: ${q(fm.description)}\norder: ${fm.order}\ngroup: ${q(fm.group)}\n---\n`;
}

for (const e of REGISTRY) {
  const raw = readFileSync(join(repoRoot, e.canonical), 'utf8');
  const out =
    frontmatter(e.frontmatter) +
    `\n<!-- GENERATED from ${e.canonical} by site/scripts/gen-docs-mirror.mjs — DO NOT EDIT; edit the canonical file. -->\n\n` +
    rewriteLinks(stripBanner(raw), e.canonical);
  writeFileSync(join(siteDir, 'src/content/docs', e.mirror), out);
  console.log(`gen-docs-mirror: ${e.mirror} <- ${e.canonical}`);
}
