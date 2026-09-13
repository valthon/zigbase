### Breaking

- File inventory and reconciliation explicitly reject incompatible collection
  metadata before inspecting objects. Run migrations after upgrading the binary;
  these maintenance commands remain non-migrating.
