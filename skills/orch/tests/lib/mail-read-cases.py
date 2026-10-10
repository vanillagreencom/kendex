"""Exercise the production reader against outputs captured before KEN-3662."""

import importlib.util
import contextlib
import io
import json
import os
from pathlib import Path
import select
import signal
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


def delivery(script, root, bash, mode, counting):
    """Interrupt a real send --halt's delivery through the plain inbox."""
    root = Path(root)
    env = {key: os.environ[key] for key in ("HOME", "PATH", "LANG", "LC_ALL", "TMPDIR") if key in os.environ}

    def command(*args):
        return subprocess.run([bash, script, *args], cwd=root, env=env,
                              capture_output=True, check=True, timeout=30)

    command("inbox", "--item", "KEN-1")
    cursor = root / "tmp/lane-mail/KEN-1/to-lane.cursor"
    assert cursor.read_text() == "0\n", "empty inbox did not establish cursor zero"
    payload = "Halt until the owner reply.\n" + "x" * 262144
    text = root / "halt.txt"
    text.write_text(payload)
    command("send", "--item", "KEN-1", "--root", str(root), "--halt", "--file", str(text))
    process = subprocess.Popen([bash, script, "inbox", "--item", "KEN-1"], cwd=root, env=env,
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True)
    try:
        ready, _, _ = select.select([process.stdout], [], [], 10)
        assert ready and os.read(process.stdout.fileno(), 1), "plain inbox did not begin delivery"
        assert process.poll() is None, "plain inbox finished before the interruption"
        assert cursor.read_text() == "0\n", "delivery-before-cursor"
        if mode == "term":
            os.killpg(process.pid, signal.SIGTERM)
        else:
            process.stdout.close()
            process.stdout = None
        process.communicate(timeout=10)
        assert process.returncode != 0, "interrupted delivery reported success"
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate(timeout=10)
    assert cursor.read_text() == "0\n", "interrupted inbox lost the unread cursor"
    retry = command("inbox", "--item", "KEN-1", "--peek").stdout
    rows = [json.loads(line) for line in retry.splitlines()[1:]]
    assert len(rows) == 1 and rows[0].get("halt") is True and rows[0].get("text") == payload, \
        "interrupted inbox lost the halt on retry"
    assert cursor.read_text() == "0\n", "peek consumed the interrupted halt"
    delivery_env = env.copy()
    if counting:
        counter = module("counter", Path(__file__).parent / "process-count.py")
        count_dir = root / "delivery-counter"
        counter.install(count_dir, env["PATH"], bash)
        delivery_env.update(PATH=str(count_dir / "bin") + os.pathsep + env["PATH"],
                            BASH_ENV=str(count_dir / "bash-env"))
    delivered = subprocess.run([bash, script, "inbox", "--item", "KEN-1"], cwd=root, env=delivery_env,
                               capture_output=True, check=True, timeout=30)
    assert delivered.stdout == retry.split(b"\n", 1)[1], \
        "successful delivery changed the unread envelope bytes"
    assert cursor.read_text() == "1\n", "successful delivery did not advance the cursor"
    assert command("inbox", "--item", "KEN-1").stdout == b"", "completed delivery repeated the halt"
    starts = "unavailable"
    if counting:
        with contextlib.redirect_stdout(io.StringIO()) as count_output:
            counter.count(count_dir)
        starts = count_output.getvalue().strip()
    print(f"delivery {mode}: cursor=0 retry_halt=1 delivered_cursor=1 empty_retry=1 starts={starts}")


if __name__ == "__main__":
    if sys.argv[4].startswith("delivery-"):
        delivery(*sys.argv[1:4], sys.argv[4][len("delivery-"):], sys.argv[5] == "yes")
    else:
        run(*sys.argv[1:4], sys.argv[4] == "yes")
