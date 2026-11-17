- Model classes prefer GPT-6.2 Sol for `standard` and GPT-6.2 Astra for `top` on Codex, Copilot CLI and Pi when the harness advertises them. Older available releases remain usable.

  You do: in `kendex.toml`, remove copied GPT-6.1 Sol or GPT-6 Astra model bindings to inherit the class defaults, or update explicit pins to `gpt-6.2-sol` and `gpt-6.2-astra`.
