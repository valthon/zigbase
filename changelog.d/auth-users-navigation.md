### Fixes
- Clearing a single select or relation during a multipart record update now clears the field instead of validating an empty option or target ID. A single select that declares `""` as an option keeps it as a value and is cleared with `null`.
- Float fields normalize consistently across JSON and multipart saves, including finite JSON numeric tokens beyond the integer range, with the same bounds and nonfinite-value validation.
- Large finite numeric min/max schema options survive API parsing and schema JSON round trips; string and nonfinite bounds remain invalid.
- Authentication settings validate an integer password minimum from 0 through 255; invalid collection API values return a field error instead of silently falling back.
