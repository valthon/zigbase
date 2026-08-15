### Fixed

- The App Genesis skill now includes the Docker runtime contract for custom framework images: create the non-root `/data` mountpoint with uid/gid `65532`, keep `serve` in the foreground, and verify HTTP readiness plus production doctor against the assembled image and named volume.
