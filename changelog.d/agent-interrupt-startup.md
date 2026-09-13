### Internal

- Defer agent-evaluation runner interrupts until the child process and I/O threads are owned, so Ctrl-C during startup still reaps the agent and emits the stable interrupted result.
