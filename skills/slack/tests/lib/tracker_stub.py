#!/usr/bin/env python3
"""Linear and repository discovery fixtures, keyed by the child's checkout."""
import json
import pathlib
import sys

root = pathlib.Path.cwd()
github = pathlib.Path(sys.argv[0]).name == "gh"
expected = ["repo", "view", "--json", "nameWithOwner"] if github else ["teams", "keys"]
if sys.argv[1:] != expected:
    sys.exit(9)
name = "github" if github else "linear"
with (root / (name + ".calls")).open("a") as log:
    log.write("read\n")
exit_file = root / (name + ".exit")
if exit_file.exists():
    sys.exit(int(exit_file.read_text()))
fixture = root / (name + ".json")
if not fixture.exists():
    sys.exit(1)
print(fixture.read_text().strip())
