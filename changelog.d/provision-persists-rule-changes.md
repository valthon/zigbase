### Security

- **Startup provisioning now persists an access-rule change to an existing collection.** A rule
  edited in a comptime `.collections` literal was silently dropped unless the same startup also
  added a field or changed `.ttl_field` — so a developer who **tightened** a rule in code and
  redeployed kept enforcing the old, looser rule until the collection was touched some other way
  (access rules are enforced from the persisted `_collections` row, not from the comptime
  literal). Rule changes are now written on every startup, via a metadata-only update: no table
  rebuild, no row copy, and no risk to indexes the provisioner doesn't manage. A rule left unset
  (`null`) still means "leave the live value alone", and `null` vs `""` is not treated as a change
  (both mean locked/superusers-only). Note that `.indexes` changes on an existing collection are
  still not re-applied — see [Known limitations](../KNOWN_LIMITATIONS.md).
