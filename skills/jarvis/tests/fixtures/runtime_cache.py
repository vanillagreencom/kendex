"""The agent-runtime binary cache a test carries into an environment whose HOME it replaces.

The runtime wrappers resolve their cache under HOME when AGENT_RUNTIME_CACHE
is unset, so under a scratch HOME they would find no build. CI sets the
variable; a local run would otherwise read an empty cache. The path is
resolved once, at import, from this process's own environment, by the
wrappers' own agent_runtime_cache in agent-runtime's scripts/lib/key.sh.
"""
from pathlib import Path
import subprocess

KEY_SH = Path(__file__).resolve().parents[3] / "agent-runtime/scripts/lib/key.sh"


def _resolve():
    result = subprocess.run(["bash", "-c", '. "$1" && agent_runtime_cache', "runtime-cache", str(KEY_SH)],
                            capture_output=True, text=True, timeout=30)
    if result.returncode != 0 or not result.stdout.strip():
        raise RuntimeError("runtime-cache: resolve-failed key_sh=%s rc=%d stderr=%s"
                           % (KEY_SH, result.returncode, result.stderr.strip()))
    return result.stdout.rstrip("\n")


AGENT_RUNTIME_CACHE = _resolve()
