"""Exercise the production reader against outputs captured before KEN-3662."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, file)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def run(script, root, bash, counting):
    here = Path(__file__).parent
    counter = module("counter", here / "process-count.py")
    world = module("world", here / "mail-read-world.py")
    rows = json.loads((here.parent / "fixtures/mail-read-base.json").read_text())
    for index, row in enumerate(rows):
        case = Path(root) / str(index)
        world.prepare(case, row["state"])
        count_dir = case / "counter"
        counter.install(count_dir, os.environ["PATH"], bash)
        env = {key: os.environ[key] for key in ("HOME", "PATH", "LANG", "LC_ALL", "TMPDIR") if key in os.environ}
        if counting:
            env.update(PATH=str(count_dir / "bin") + os.pathsep + env["PATH"], BASH_ENV=str(count_dir / "bash-env"))
        result = subprocess.run([bash, script, *row["args"], "--item", "KEN-1", "--root", str(case)],
                                capture_output=True, env=env, timeout=30)
        stdout_matches = result.stdout == row["stdout"].encode()
        stderr_key = result.stderr.split(b"\n", 1)[0]
        expected_key = row["stderr"].encode().split(b"\n", 1)[0]
        print(f"row={index} state={row['state']} args={' '.join(row['args'])}")
        print(f"stdout={int(stdout_matches)} exit={int(result.returncode == row['exit'])} key={int(stderr_key == expected_key)}")
        if not stdout_matches or stderr_key != expected_key:
            print(f"actual stdout={result.stdout!r} stderr={result.stderr!r}", file=sys.stderr)
        if counting:
            counter.count(count_dir)
        else:
            print("0")


if __name__ == "__main__":
    run(*sys.argv[1:4], sys.argv[4] == "yes")
