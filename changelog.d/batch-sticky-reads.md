### Performance

- Feature-state resolution (`ctx.flags().resolveAll` / the public `/api/state` projection) now reads every sticky experiment's persisted assignment in a **single** batched query, so a resolve is a constant 2 queries regardless of how many `.sticky` experiments an app declares (previously 1 + N — one assignment read per sticky experiment). Variants and miss-persist behavior are byte-identical; the single-accessor `App.experiment` path is unchanged.
