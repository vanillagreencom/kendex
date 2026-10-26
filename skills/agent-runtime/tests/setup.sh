#!/usr/bin/env bash
# The setup suite's entry for the runners that glob tests/*.sh; the suite is
# tests/setup/setup.sh.
exec "$(cd -- "${BASH_SOURCE[0]%/*}" && pwd -P)/setup/setup.sh" "$@"
