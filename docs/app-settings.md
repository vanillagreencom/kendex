# App settings

The desktop app and CLI share personal settings in the app config directory. These files are separate from a project's `kendex.settings.toml`. On Linux, the directory is `~/.config/kendex` by default. Other platforms use their app config directory.

| File | Purpose | Dotfiles |
|---|---|---|
| `settings.toml` | Personal preferences shared across machines. | Track this file if you want to share preferences. |
| `machine.toml` | This machine's registered projects, harness root overrides, and terms acceptance. | Exclude this file. |

Both files carry a `schema` field for the file format. The [settings owner](../crates/core/src/settings/mod.rs) declares the preference fields. Package notification preferences can name a project path. Those paths identify notification choices; they do not register a project on another machine. Exclude the adjacent `.lock` files from dotfiles too.

## Existing installations

The first read migrates machine keys from `settings.toml` to `machine.toml`. The read prints one warning that names the new file. The migration removes the old keys and keeps preference comments. No manual conversion is required. The compatibility reader remains until the next major release. An existing machine file takes precedence over old machine keys in the preference file.

## Writes

Each file has its own lock and check for changes since it was read. A save from an old copy refuses if either file changed. Changes to machine state alone leave the shared preference file unchanged. A save that changes both files writes machine state first. An interruption between writes leaves new machine state and old, readable preferences. A subsequent read finishes an interrupted migration.
