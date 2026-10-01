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
        refresh = sys.argv[3:] == ["refresh"]
        fixture = root / "linear.json"
        saved = fixture.read_text() if refresh else None
        try:
            for stamp in (0, 0, 86399, 86400, 86401):
                clock[0] = stamp
                if refresh and stamp == 86399:
                    fixture.write_text(json.dumps({"urlKey": "workspace", "keys": ["NEW"]}))
                results.append(markup.outbound(root, "HTIO-5 NEW-6" if refresh else "HTIO-5")[0])
                reads.append(len((root / "linear.calls").read_text().splitlines()))
        finally:
            if saved is not None:
                fixture.write_text(saved)
        result = {"texts": results, "reads": reads}
    elif mode == "roots":
        result = [markup.outbound(Path(path), "KEN-1 #2 org/other#3")[0] for path in sys.argv[3:]]
    else:
        raise ValueError(mode)
print(json.dumps({"result": result, "notices": notices.getvalue().splitlines()}))
