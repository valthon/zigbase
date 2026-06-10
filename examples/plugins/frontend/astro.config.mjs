// @ts-check
import { defineConfig } from 'astro/config';
import react from '@astrojs/react';

export default defineConfig({
  integrations: [react()],
  vite: {
    // `astro dev` proxies API calls to a locally running plugins backend so the
    // islands work in dev; the production build is same-origin (embedded in the binary).
    server: { proxy: { '/api': 'http://127.0.0.1:8090' } },
  },
});
