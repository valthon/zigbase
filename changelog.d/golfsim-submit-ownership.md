### Fixes
- Fixed the GolfSim webhook example to follow `app.submit` ownership correctly, avoiding a leaked caller copy and a double-free of the queue-owned job name.
