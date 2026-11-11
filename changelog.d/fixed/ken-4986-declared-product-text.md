- CI can recognize declared product-text Markdown files outside the default documentation paths while preserving the checks that claim those files.

  You do: to opt in, set `HARNESS_CI_DOCS_PATHS` to a space-separated string of exact Markdown paths under `[env]` in your default branch's `kendex.settings.toml`, keep each file claimed by its checking lane in `.github/ci-lanes.conf`, and gate those checks through the shared `lanes` and per-lane outputs.
