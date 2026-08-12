// @ts-check
import { defineConfig } from 'astro/config';
import mdx from '@astrojs/mdx';
import sitemap from '@astrojs/sitemap';
import { rehypeHeadingIds } from '@astrojs/markdown-remark';
import rehypeAutolinkHeadings from 'rehype-autolink-headings';

// https://astro.build/config
export default defineConfig({
  site: 'https://valthon.github.io',
  // @astrojs/mdx inherits the `markdown` config below (rehype heading ids +
  // autolink anchors, Shiki dual themes) by default — keep it integration-first.
  // /docs is a meta-refresh redirect page to /docs/overview and is noindexed
  // (see src/pages/docs/index.astro) — keep it out of the sitemap so it doesn't
  // send GSC contradictory signals (a noindexed page listed for indexing).
  integrations: [
    mdx(),
    sitemap({ filter: (page) => page !== 'https://valthon.github.io/zigbase/docs' }),
  ],
  base: '/zigbase',
  trailingSlash: 'never',
  build: {
    // Emit `docs/tutorial.html` (served at `/zigbase/docs/tutorial`, no trailing
    // slash) rather than `docs/tutorial/index.html` (served at `.../tutorial/`).
    // This is what makes the authored relative cross-links in the markdown content
    // (e.g. `./api`, `../download`) resolve correctly on GitHub Pages — a sibling
    // `./api` from `/zigbase/docs/tutorial` points at `/zigbase/docs/api`.
    format: 'file',
  },
  markdown: {
    // Append a small '#' anchor link to each heading so the prose CSS can render
    // hover anchors and the TOC can target them.
    //
    // rehypeHeadingIds is REQUIRED here, not redundant: rehype-autolink-headings
    // needs heading `id`s to already exist when it runs, and a user-supplied
    // rehypePlugins array runs before Astro injects its own id pass — so without
    // this explicit plugin the autolink step finds no ids and emits zero anchors
    // (verified: removing it drops 24 anchors → 0 on the framework page).
    rehypePlugins: [
      rehypeHeadingIds,
      [
        rehypeAutolinkHeadings,
        {
          behavior: 'append',
          properties: { class: 'heading-anchor', ariaHidden: 'true', tabIndex: -1 },
          content: [],
        },
      ],
    ],
    shikiConfig: {
      themes: {
        light: 'github-light',
        dark: 'github-dark',
      },
    },
  },
});
