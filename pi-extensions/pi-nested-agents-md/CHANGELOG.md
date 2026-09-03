# Changelog

## Consumer-impacting changes

### 0.1.0

- First release. On a successful `read`, every `AGENTS.md` between the file's directory and the project root that Pi did not load at startup is appended to the read result once per session, root-most first; a file that cannot be read is reported in one line instead. Master `enabled` toggle via pi-extension-manager.
