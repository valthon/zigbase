// @ts-check
import { defineConfig } from 'astro/config';
import react from '@astrojs/react';

export default defineConfig({
  integrations: [react()],
  vite: {
    // `astro dev` proxies API calls to a locally running golfsim backend so the
    // islands work in dev; the production build is same-origin (served by the
    // golfsim binary itself via the comptime-hardcoded static dir).
    server: { proxy: { '/api': 'http://127.0.0.1:8090' } },
  },
});
