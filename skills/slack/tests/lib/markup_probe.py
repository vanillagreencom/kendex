"""Disposable probe for the real markup module; shell suites own assertions."""
import contextlib
import io
import json
from pathlib import Path
import sys

import markup

root, mode = Path(sys.argv[1]), sys.argv[2]
clock = [0.0]
markup.TRACKERS = markup.TrackerMetadata(lambda: clock[0])
notices = io.StringIO()
with contextlib.redirect_stdout(notices):
    if mode == "outbound":
        result = markup.outbound(root, sys.argv[3], file_comment=sys.argv[4] == "file")
    elif mode == "lifetime":
        results = []
        reads = []
        github = "github" in sys.argv[3:]
        refresh = "refresh" in sys.argv[3:]
        source = "github" if github else "linear"
        fixture = root / (source + ".json")
        exit_fixture = root / (source + ".exit")
        saved = fixture.read_text() if refresh else None
        saved_exit = exit_fixture.read_bytes() if refresh and exit_fixture.exists() else None
        try:
            for stamp in (0, 0, 86399, 86400, 86401):
                clock[0] = stamp
                if refresh and stamp == 86399:
                    fixture.write_text(json.dumps({"nameWithOwner": "org/changed"} if github else
                                                  {"urlKey": "workspace", "keys": ["NEW"]}))
                    if saved_exit is not None:
                        exit_fixture.unlink()
                text = "#2" if github else "HTIO-5 NEW-6" if refresh else "HTIO-5"
                results.append(markup.outbound(root, text)[0])
                reads.append(len((root / (source + ".calls")).read_text().splitlines()))
        finally:
            if saved is not None:
                fixture.write_text(saved)
            if saved_exit is not None:
                exit_fixture.write_bytes(saved_exit)
        result = {"texts": results, "reads": reads}
    elif mode == "roots":
        result = [markup.outbound(Path(path), "KEN-1 #2 org/other#3")[0] for path in sys.argv[3:]]
    else:
        raise ValueError(mode)
print(json.dumps({"result": result, "notices": notices.getvalue().splitlines()}))
