// @ts-check
import { defineConfig } from 'astro/config';
import { rehypeHeadingIds } from '@astrojs/markdown-remark';
import rehypeAutolinkHeadings from 'rehype-autolink-headings';

// https://astro.build/config
export default defineConfig({
  site: 'https://valthon.github.io',
  base: '/zigbase',
  trailingSlash: 'ignore',
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
