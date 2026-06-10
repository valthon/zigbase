// @ts-check
import { defineConfig } from 'astro/config';
import { rehypeHeadingIds } from '@astrojs/markdown-remark';
import rehypeAutolinkHeadings from 'rehype-autolink-headings';

// https://astro.build/config
export default defineConfig({
  site: 'https://valthon.github.io',
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
    // Astro auto-adds heading ids; append a small '#' anchor link to each
    // h2–h4 so the prose CSS can render hover anchors and the TOC can target them.
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
