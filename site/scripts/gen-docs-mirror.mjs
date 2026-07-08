// Generate site doc mirrors from the canonical source files. The mirrors under
// site/src/content/docs/ are gitignored build artifacts — edit the canonical file
// (repo-root CHANGELOG.md / KNOWN_LIMITATIONS.md, or docs/*.md), never the mirror.
// Runs via package.json predev/prebuild, so `npm run dev` and `npm run build`
// (and CI/release, which use `npm run build`) always regenerate first.
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const siteDir = dirname(dirname(fileURLToPath(import.meta.url))); // .../site
const repoRoot = dirname(siteDir);

// Published doc-route names (mirror basenames without .md). Used by the link
// rewriter: a `docs/<name>.md` link to a published route becomes `./<name>`;
// a link to an unpublished doc (dx-assessment, ideas, security-audit, tutorial)
// becomes a GitHub blob URL so it resolves instead of 404-ing.
const PUBLISHED = new Set([
  'abilities', 'analytics', 'api', 'changelog', 'configuration', 'dart-sdk',
  'docker', 'email', 'fields', 'framework', 'jobs-and-webhooks', 'known-limitations',
  'overview', 'postgres', 'realtime-broadcast', 'recipes', 'search', 'tenancy',
  'typescript-sdk',
]);

// { canonical (relative to repo root) -> mirror basename + frontmatter }.
// PR 1: the two drift-proven root files. PR 2 extends this to docs/*.md pairs.
const REGISTRY = [
  {
    canonical: 'CHANGELOG.md',
    mirror: 'changelog.md',
    fm: {
      title: 'Changelog',
      description: 'Release history for ZigBase, following Keep a Changelog and Semantic Versioning.',
      order: 4,
      group: 'reference',
    },
  },
  {
    canonical: 'KNOWN_LIMITATIONS.md',
    mirror: 'known-limitations.md',
    fm: {
      title: 'Known limitations',
      description: 'Current caveats in ZigBase — auth/email, framework hooks, schema migrations, fields, the scheduler, platform/UI gaps, and deferred work.',
      order: 3,
      group: 'reference',
    },
  },
];

// Root-file canonicals are linked by their UPPER_CASE basename (e.g.
// `KNOWN_LIMITATIONS.md`); map those to their published route from the REGISTRY so
// a cross-ref like `[KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md)` in CHANGELOG.md
// resolves to `./known-limitations` on the site.
const ROOT_ROUTE = new Map(
  REGISTRY.map((e) => [e.canonical.replace(/\.md$/, ''), e.mirror.replace(/\.md$/, '')]),
);

// A link target's published route (`./<route>`), or null if it points at an
// unpublished doc (dx-assessment, ideas, security-audit, tutorial) or a typo.
function routeFor(name) {
  if (ROOT_ROUTE.has(name)) return ROOT_ROUTE.get(name); // upper-case root canonicals
  if (PUBLISHED.has(name)) return name; // docs/*.md published routes (lower-case basename)
  return null;
}

// Rewrite markdown link TARGETS (never the text). Matches `](docs/x.md#a)`,
// `](./x.md#a)`, `](x.md#a)` (incl. UPPER_CASE/underscore root names) — anchored on
// `](` so it never fires mid-URL, and the target-token charset excludes `:` `/` so
// absolute http(s) URLs never match. Unpublished/unknown targets fall back to a
// GitHub blob URL AND log a warning, so a broken/typo'd link is visible at gen time.
function rewriteLinks(body, canonical) {
  return body.replace(
    /\]\((?:\.\/|docs\/)?([A-Za-z0-9][A-Za-z0-9_-]*)\.md(#[^)]*)?\)/g,
    (_m, name, anchor = '') => {
      const route = routeFor(name);
      if (route) return `](./${route}${anchor})`;
      console.warn(
        `gen-docs-mirror: [${canonical}] link "${name}.md" has no published route — falling back to GitHub blob`,
      );
      return `](https://github.com/valthon/zigbase/blob/main/docs/${name}.md${anchor})`;
    },
  );
}

function frontmatter(fm) {
  // Existing mirrors use unquoted scalars; none of these values contain a YAML
  // metacharacter (no leading-space, no `: ` mid-string). Keep it unquoted to match.
  return `---\ntitle: ${fm.title}\ndescription: ${fm.description}\norder: ${fm.order}\ngroup: ${fm.group}\n---\n`;
}

for (const e of REGISTRY) {
  const raw = readFileSync(join(repoRoot, e.canonical), 'utf8');
  const out =
    frontmatter(e.fm) +
    `\n<!-- GENERATED from ${e.canonical} by site/scripts/gen-docs-mirror.mjs — DO NOT EDIT; edit the canonical file. -->\n\n` +
    rewriteLinks(raw, e.canonical);
  writeFileSync(join(siteDir, 'src/content/docs', e.mirror), out);
  console.log(`gen-docs-mirror: ${e.mirror} <- ${e.canonical}`);
}
