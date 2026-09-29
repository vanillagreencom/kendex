# Changelog

## Consumer-impacting changes

### 0.1.2

- A session started below the home directory no longer takes a marked folder above home for its project root, so settings and the `AGENTS.md` walk use the project kendex renders into. The walk up stops at home; a `.kendex-lock.json` at home still makes home the project.

### 0.1.1

- An attached instructions file is introduced by an `instructions_path=<path>` line, and a file that cannot be read by an `unreadable_path=<path>` line followed by the reason, replacing the bracketed one-line forms.
- A walk started outside the project root throws an error carrying the code `OUTSIDE_ROOT` and both paths, rather than a prose message only.

### 0.1.0

- First release. On a successful `read`, every `AGENTS.md` between the file's directory and the project root that Pi did not load at startup is appended to the read result once per session, root-most first; a file that cannot be read is reported with a path key followed by an explanation instead. Master `enabled` toggle via pi-extension-manager.
