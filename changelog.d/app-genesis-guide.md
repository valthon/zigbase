### Features

- Added a rules-first app-design guide for humans and coding agents: turn user journeys into trust boundaries, choose box or framework mode, model relations without accidental denormalization, inventory every intentional public rule, place trusted behavior in the narrowest server seam, and choose the test boundary that proves each feature.
- Documented the custom-image Docker runtime contract: create the non-root `/data` mountpoint with uid/gid `65532`, keep `serve` in the foreground, and verify HTTP readiness plus production doctor against the assembled image and named volume.
