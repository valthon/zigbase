### Changed
- Admin navigation groups auth collections under Users and ordinary collections under Data collections. Account links preserve the selected auth collection, including legacy record URLs, and collection settings link directly to account management.

### Features
- User create/edit forms now support schema-defined profile fields, validation, JSON and rich text editors, relations, multiple selections, and file uploads alongside credentials.

### Fixes
- Clearing a single select or relation during a multipart record update now clears the field instead of validating an empty option or target ID. A single select that declares `""` as an option keeps it as a value and is cleared with `null`.
- Admin account password validation uses UTF-8 byte length, matching the server policy for non-ASCII passwords.
- Admin account forms accept internationalized email addresses and keep Manage users links on the stored collection until a rename is saved.
- Float fields normalize consistently across JSON and multipart saves, including finite JSON numeric tokens beyond the integer range, with the same bounds and nonfinite-value validation.
- File changes preserve untouched nullable text, date, editor, URL, and email profile fields while keeping intentional empty-string clears.
- Large finite numeric min/max schema options survive API parsing and schema JSON round trips; string and nonfinite bounds remain invalid.
- Valid custom field names such as constructor, valueOf, and toString use their own values in forms, validation messages, JSON payloads, and file-removal state.
- Account credentials and profile controls have associated labels, including JSON, rich text, relations, and file actions, so assistive technology can identify each field.
- Focusing and leaving unchanged rich text preserves null values; deliberate clears still save. Account creation also honors an explicitly configured zero password minimum.
- Account edits submit only changed fields, preserving concurrent profile updates and allowing credential resets on legacy rows with missing required profile values. Blank usernames on creation remain null.
- Users reuses the sidebar collection metadata; one guarded refresh owns loading and errors, and failed lookups do not block later collection routes. Record drawers load their current collection definition when opened, including fields changed in another tab or through the API.
- Rich-text blur persists cleanup of unsafe stored HTML, and authentication settings preserve a zero password minimum when saved and reopened.
- Base-collection record drawers retain ordinary email, username, verified and token_epoch fields, including the email inputs in built-in mail collections.
- Authentication settings validate an integer password minimum from 0 through 255; invalid collection API values return a field error instead of silently falling back.
- Account drawers also refresh their collection definition on open, honoring required profile fields and password policy changed while Users remains open.
