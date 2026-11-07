"""A Jarvis home's starting files: the one initializer for jarvis-session init and the first manual start."""

import copy
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile


# The top-level names ../../references/home-layout.md § Initialize accepts:
# the home layout's paths, Git's, and the files kendex writes in a project.
# Any other entry means the folder is something else, such as an ordinary
# project.
NAMES = frozenset({
    "AGENTS.md", "skills", "memory", "state", "tmp", ".env.local",
    ".git", ".gitignore",
    "kendex.toml", "kendex.settings.toml", ".kendex-lock.json", ".kendex-generated.json", ".cache",
    ".agents", ".claude", ".codex", ".github", ".pi", ".opencode", ".cursor", ".gemini",
    ".mcp.json", "opencode.json", "opencode.jsonc",
})
STARTING = ("AGENTS.md", "memory/MEMORY.md", "state")
# The route keeps one copy of the persona: the installed file. An app that
# supplies the persona itself has its text loaded already.
ROUTE = ("Read `.agents/skills/jarvis/persona.md` and follow it."
         " Read it once per session; when its text is already loaded, use that text.\n")
INDEX = "# Memory index\n"
# The separate-folder action every refusal names, within the 200 printable
# characters a session answer's detail holds.
SEPARATE_FOLDER = ("Jarvis needs a folder of its own. Make a new folder outside any project,"
                   " run git init in it, then kendex add and start Jarvis there.")
# Each harness's own switch for its vendor memory, which would hold a second
# memory beside the home's memory/. Claude Code: autoMemoryEnabled, any
# settings file (code.claude.com/docs/en/settings-reference). Codex: the
# memories feature flag (codex features list, codex-cli 0.167.0).
CLAUDE_SETTINGS = ".claude/settings.json"
CODEX_CONFIG = ".codex/config.toml"
# Variables that point git at another repository than the folder asked about.
GIT_REDIRECTS = {"GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE"}
FEATURES_HEADER = re.compile(r"^[ \t]*\[[ \t]*features[ \t]*\][ \t]*(#.*)?$", re.MULTILINE)


class Unmergeable(ValueError):
    """The settings file holds the key's table in a form a textual insert cannot extend."""


class Refused(Exception):
    """The folder is not a dedicated home; nothing was written."""

    def __init__(self, cause, entry=None):
        super().__init__(cause)
        self.cause, self.entry = cause, entry

    def line(self):
        return ("jarvis-session: init=refused cause=" + self.cause
                + (" entry=" + json.dumps(self.entry) if self.entry is not None else ""))


class Failed(Exception):
    """A step could not complete; `created` names what this call wrote before it."""

    def __init__(self, cause, path, created):
        super().__init__(cause)
        self.cause, self.path, self.created = cause, path, created

    def line(self):
        return ("jarvis-session: init=failed path=" + self.path + " cause=" + self.cause
                + " created=" + ",".join(self.created))


def complete(home):
    home = Path(home)
    return (home / "AGENTS.md").exists() and (home / "memory/MEMORY.md").exists() and (home / "state").is_dir()


def toplevel(directory):
    """The work tree root git finds from DIRECTORY, or None outside every work tree."""
    env = {key: value for key, value in os.environ.items() if key not in GIT_REDIRECTS}
    try:
        # rev-parse reads config and runs nothing; safe.directory keeps a
        # repository owned by someone else from reading as no repository.
        result = subprocess.run(["git", "-c", "safe.directory=*", "-C", str(directory), "rev-parse", "--show-toplevel"],
                                env=env, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as failure:
        raise Failed("git-" + type(failure).__name__, ".git", [])
    if result.returncode == 128:
        return None
    if result.returncode:
        raise Failed("git-exit-" + str(result.returncode), ".git", [])
    return Path(result.stdout.strip()).resolve()


def qualify(home):
    root = toplevel(home)
    if root is None:
        raise Refused("no-git")
    if root != home or (home.parent != home and toplevel(home.parent) is not None):
        raise Refused("inside-work-tree")
    extra = sorted(set(os.listdir(home)) - NAMES)
    if extra:
        raise Refused("other-entry", extra[0])


def replace(path, text):
    # Same-directory staging keeps the replacement atomic and the mode as it was.
    mode = path.stat().st_mode & 0o7777 if path.exists() else None
    fd, name = tempfile.mkstemp(dir=path.parent, prefix="." + path.name + "-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(text)
        if mode is not None:
            os.chmod(name, mode)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def claude_settings(text):
    data = json.loads(text) if text is not None else {}
    if not isinstance(data, dict):
        raise Unmergeable("object")
    if "autoMemoryEnabled" in data:
        return None
    if text is None:
        return '{\n  "autoMemoryEnabled": false\n}\n', dict(data, autoMemoryEnabled=False)
    # Insert after the opening brace so every other byte stays.
    start = text.index("{") + 1
    tail = "\n" if not data else ","
    return text[:start] + '\n  "autoMemoryEnabled": false' + tail + text[start:], dict(data, autoMemoryEnabled=False)


def codex_config(text):
    import tomllib
    text = text or ""
    data = tomllib.loads(text)
    features = data.get("features")
    if isinstance(features, dict) and "memories" in features:
        return None
    expected = copy.deepcopy(data)
    expected.setdefault("features", {})["memories"] = False
    if features is None:
        separator = "" if not text else ("\n" if text.endswith("\n") else "\n\n")
        return text + separator + "[features]\nmemories = false\n", expected
    header = FEATURES_HEADER.search(text)
    if not header:
        raise Unmergeable("features")
    end = header.end()
    return text[:end] + "\nmemories = false" + text[end:], expected


def merge(home, relative, key, edit, parse):
    """Add KEY when the file lacks it; a file that already names it keeps its value."""
    path = home / relative
    row = {"path": relative, "key": key}
    if path.is_symlink():
        return dict(row, outcome="refused", cause="linked")
    try:
        text = path.read_text(encoding="utf-8") if path.exists() else None
        change = edit(text)
    except ImportError:
        # tomllib arrived in Python 3.11; without a reader the file stays as it is.
        return dict(row, outcome="refused", cause="toml-reader-missing")
    except Unmergeable:
        return dict(row, outcome="refused", cause="shape")
    except (OSError, UnicodeError, ValueError):
        return dict(row, outcome="refused", cause="unreadable")
    if change is None:
        return dict(row, outcome="kept")
    updated, expected = change
    # The edit is textual; the parsed result proves it added the key alone.
    try:
        if parse(updated) != expected:
            raise ValueError("shape")
    except ValueError:
        return dict(row, outcome="refused", cause="shape")
    try:
        replace(path, updated)
    except OSError:
        return dict(row, outcome="refused", cause="unwritable")
    return dict(row, outcome="merged")


def toml_loads(text):
    import tomllib
    return tomllib.loads(text)


def init(home):
    """Write the missing starting files of a dedicated HOME and report each one."""
    home = Path(home).resolve(strict=True)
    qualify(home)
    created, kept = [], []
    try:
        (home / "state").mkdir()
        created.append("state")
    except FileExistsError:
        if not (home / "state").is_dir():
            raise Failed("not-a-directory", "state", created)
        kept.append("state")
    except OSError as failure:
        raise Failed(type(failure).__name__, "state", created)
    for relative, text in (("memory/MEMORY.md", INDEX), ("AGENTS.md", ROUTE)):
        path = home / relative
        try:
            path.parent.mkdir(exist_ok=True)
            # Exclusive creation: a file the user made first is never replaced.
            with path.open("x", encoding="utf-8") as stream:
                stream.write(text)
            created.append(relative)
        except FileExistsError:
            kept.append(relative)
        except OSError as failure:
            raise Failed(type(failure).__name__, relative, created)
    settings = []
    # A harness directory kendex wrote says the home uses that harness.
    if (home / ".claude").is_dir():
        settings.append(merge(home, CLAUDE_SETTINGS, "autoMemoryEnabled", claude_settings, json.loads))
    if (home / ".codex").is_dir():
        settings.append(merge(home, CODEX_CONFIG, "features.memories", codex_config, toml_loads))
    return {"v": 1, "home": str(home), "created": created, "kept": kept, "settings": settings}


def settings_lines(report):
    return ["jarvis-session: init-settings=refused path=" + row["path"] + " cause=" + row["cause"]
            for row in report["settings"] if row["outcome"] == "refused"]
