import { mkdtempSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { expect, it } from 'vitest';

it('builds from the harness without reinstalling packages in the running test tree', () => {
  const dir = mkdtempSync(join(tmpdir(), 'golfsim-build-test-'));
  try {
    const log = join(dir, 'calls');
    for (const tool of ['npm', 'npx']) {
      writeFileSync(join(dir, tool), '#!/bin/sh\nprintf "%s\\n" "$*" >> "$BUILD_TEST_LOG"\n', { mode: 0o755 });
    }
    const script = fileURLToPath(new URL('../frontend/build.sh', import.meta.url));
    const result = spawnSync('bash', [script, '--no-install'], {
      env: { ...process.env, PATH: `${dir}:${process.env.PATH}`, BUILD_TEST_LOG: log },
      encoding: 'utf8',
    });
    expect(result.status, result.stderr).toBe(0);
    const calls = readFileSync(log, 'utf8');
    expect(calls).not.toContain('--prefix ../../../clients/typescript');
    expect(calls).toContain('--prefix .. run typecheck');
    expect(calls).toContain('zigapagos release');
    expect(calls).not.toMatch(/\b(ci|install)\b/);
    const harness = readFileSync(fileURLToPath(new URL('./harness.ts', import.meta.url)), 'utf8');
    expect(harness).toContain('["build.sh", "--no-install"]');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
