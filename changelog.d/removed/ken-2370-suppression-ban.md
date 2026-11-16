- Remove the blanket lint-suppression spelling check and Rust bare-allow count ratchet from commit-guards. A dispatcher call or setting naming `suppression-ban` now warns and skips it.

  You do: remove `suppression-ban` from `COMMIT_GUARDS_CHECKS` and stop calling its script directly; nothing replaces it.
