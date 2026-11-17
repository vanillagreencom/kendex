- Model classes prefer GPT-6.2 Sol for `standard` and GPT-6.2 Astra for `top` on Codex, Copilot CLI and Pi when the harness advertises them. Older available releases remain usable.

  You do: in `kendex.toml`, update copied `model-bindings.codex` and `model-bindings.copilot` entries or explicit model pins to `gpt-6.2-sol` and `gpt-6.2-astra`; removing these static bindings inherits the session model.
