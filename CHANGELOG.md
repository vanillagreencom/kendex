# Changelog

## 4.0.2

- Flightdeck: add `vstack flightdeck migrate-permissions` to safely repair legacy run-store permissions after the vstack#227 strict-permissions upgrade. Use `--dry-run` first to review planned `0600` file and `0700` directory changes; unsafe paths such as symlinks, foreign-owned files, or group/other-writable paths are refused.
- Flightdeck: strict run-store permission errors now point users at the migration command instead of leaving them with raw `mode=644 expected 600` failures.
