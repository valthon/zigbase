### Fixes
- Startup provisioning now applies safe select-option widening to existing databases without rebuilding tables. Select narrowing, single/multi-value changes, and other field option or flag changes emit an explicit-migration warning instead of being silently ignored.
- Concurrent startup plans for the same definition converge without conflicts or repeated cache invalidation; select-value reordering alone leaves the stored definition unchanged.
