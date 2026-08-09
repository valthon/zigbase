### Features

- Error codes are now a frozen, documented registry (`src/error-codes.frozen`): every code ZigBase emits — the ten top-level envelope codes and the 27 field-level `validation_*` codes — is append-only and permanent, enforced by unit tests and by a CI guard that diffs the ledger against the base branch so a code can never be quietly deleted. Match on `code`; `message` text is explicitly not part of the contract and may be reworded at any time.
