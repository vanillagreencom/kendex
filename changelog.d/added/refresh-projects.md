- Automatic consumer refresh can update declared projects inside one checkout through `KENDEX_REFRESH_PROJECTS`. Their renders enter the same refresh pull request.

  You do: set `KENDEX_REFRESH_PROJECTS` in the root `kendex.settings.toml` `[env]` table to the project paths separated by semicolons, such as `"packaging/jarvis-home;another/project"`.
