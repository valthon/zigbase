// Single source of truth for ZigBase *release* facts used across the site.
//
// Note: this is the ZigBase backend release version shown in the UI and used to
// build release-asset URLs. It is deliberately NOT derived from this site's
// package.json `version` — the marketing site and the backend are versioned
// independently, so coupling them would display the wrong number when one moves.
// Bump ZIGBASE_VERSION here when a new ZigBase release is cut.

export const ZIGBASE_VERSION = '0.3.0';

/** Display form, e.g. "v0.1.0". */
export const ZIGBASE_VERSION_TAG = `v${ZIGBASE_VERSION}`;

export const REPO_URL = 'https://github.com/valthon/zigbase';
