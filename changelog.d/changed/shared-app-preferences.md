- App preferences can be shared through dotfiles. Registered projects, harness roots, and terms acceptance move to `machine.toml` beside `settings.toml`. Existing settings migrate on the first unprivileged read. A run acting as root reads the existing settings without migration.

  You do: exclude `machine.toml` and the adjacent `.lock` files from shared dotfiles; keep `settings.toml` tracked.
