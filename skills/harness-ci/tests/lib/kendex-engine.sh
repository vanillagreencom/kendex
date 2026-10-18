#!/usr/bin/env bash
# Select the render rows' engine. The release compatibility job must keep
# the engine it supplied; ordinary source-tree tests judge their own build.
hci_test_engine() { # SOURCE_ROOT SANDBOX; sets checkout_kendex and PATH
  local kendex_tree=$1 sandbox=$2
  checkout_kendex=""
  [ "${KENDEX_RELEASE_TEST:-}" != 1 ] || return 0
  if command -v kendex >/dev/null 2>&1 && [ -f "$kendex_tree/crates/cli/Cargo.toml" ]; then
    if checkout_kendex="$(cd "$kendex_tree" && cargo build -p kendex-cli --locked \
      --message-format=json-render-diagnostics 2>"$sandbox/kendex-build" | jq -r \
      'select(.reason == "compiler-artifact" and .target.name == "kendex" and .executable != null) | .executable')" \
      && [ -x "$checkout_kendex" ]; then
      mkdir -p "$sandbox/checkout-bin"
      ln -s "$checkout_kendex" "$sandbox/checkout-bin/kendex"
      PATH="$sandbox/checkout-bin:$PATH"
    else
      printf '  FAIL: the render rows judge the kendex %s builds, and cargo build -p kendex-cli did not make one\n' \
        "$kendex_tree" >&2
      sed 's/^/    /' "$sandbox/kendex-build" >&2
      checkout_kendex=unbuilt
      return 1
    fi
  fi
}
