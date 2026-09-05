import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    include: ['test/**/*.frontend.test.ts'],
    environment: 'node',
    pool: 'forks',
    fileParallelism: false,
  },
});
