// Single source of truth for ZigBase *release* facts shown across the site.
// Versions are DERIVED at build time — server from build.zig.zon, client from
// the SDK package.json — so the site never hard-codes a release number and can't
// drift. Targets come from the npm server package's targets.json (Plan 2).
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(HERE, '..', '..', '..'); // site/src/config -> repo root

function serverVersion(): string {
  const zon = readFileSync(join(REPO_ROOT, 'build.zig.zon'), 'utf8');
  const m = zon.match(/^\s*\.version\s*=\s*"([^"]+)"/m);
  if (!m) throw new Error('site config: could not read .version from build.zig.zon');
  return m[1];
}

function clientVersion(): string {
  const pkg = JSON.parse(readFileSync(join(REPO_ROOT, 'clients/typescript/package.json'), 'utf8'));
  return pkg.version;
}

type Target = { platform: string; arch: string; triple: string };
function targets(): Target[] {
  const raw = JSON.parse(
    readFileSync(join(REPO_ROOT, 'clients/typescript/npm/server/targets.json'), 'utf8'),
  ) as Array<{ key: string; zig: string; os: string; cpu: string }>;
  const osLabel: Record<string, string> = { linux: 'Linux', darwin: 'macOS' };
  return raw.map((t) => ({
    platform: osLabel[t.os] ?? t.os,
    arch: t.zig.split('-')[0], // x86_64 / aarch64
    triple: t.zig,
  }));
}

export const SERVER_VERSION = serverVersion();
export const CLIENT_VERSION = clientVersion();

/** Back-compat alias: existing importers use ZIGBASE_VERSION for the server release. */
export const ZIGBASE_VERSION = SERVER_VERSION;
/** Display form, e.g. "v0.4.0". */
export const ZIGBASE_VERSION_TAG = `v${SERVER_VERSION}`;

export const REPO_URL = 'https://github.com/valthon/zigbase';

export const TARGETS: Target[] = targets();
