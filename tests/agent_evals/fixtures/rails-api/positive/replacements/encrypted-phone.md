# User.phone retirement

`phone` was Active Record-encrypted. Ciphertext cannot travel without the
application key, and no migrated route reads the value, so the attribute is
retired rather than re-keyed. Users re-enter a phone number if they want one.
