- The Jarvis session hold uses `SLACK_JARVIS_SESSION_FILE` and `SLACK_JARVIS_SESSION_MAX_AGE`. Status shows `held-by=jarvis`; an unreadable hold file reports `jarvis-session-file-unreadable`. The old `SLACK_MASTER_FILE` and `SLACK_MASTER_MAX_AGE` keys still hold the relay until kendex 2.0.0, with one `setting-renamed` warning per old key and process. The new key takes precedence, including an empty value.

  You do: rename the two keys in kendex.settings.toml before 2.0.0 removes the old ones
