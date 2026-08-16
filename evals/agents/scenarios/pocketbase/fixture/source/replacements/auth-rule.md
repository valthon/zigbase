# Auth rule replacement

The source collection has an empty PocketBase `authRule`, so password authentication has no
additional record filter. The ZigBase target deliberately keeps `require_verified` disabled. The
migration parity suite must exercise the intended unverified-account policy before cutover.
