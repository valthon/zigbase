### Fixes
- Align the website, SDK READMEs, framework guides, and operational guidance with the pending release. Correct OAuth state handling, WebAuthn creation options, flat `register/finish` proofs, login timeout and browser encoding, trusted-route authorization, and executable auth, booking, and abilities examples. Give SQL commands for rotating the restored replay journal's secret.

### Internal
- Compile and exercise canonical Zig documentation examples in CI; check configuration-table parity and execute the TypeScript and Python OAuth examples through their SDK transports.
- Wait for PostgreSQL's final TCP listener in CI so its temporary initialization server cannot satisfy readiness early.
