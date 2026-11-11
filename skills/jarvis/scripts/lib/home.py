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
# project. The kendex names copy KENDEX_FILES and kendex_dirs in
# crates/core/src/settings_secret/destination.rs, which a catalog script
# cannot import.
NAMES = frozenset({
    "AGENTS.md", "skills", "memory", "state", "tmp", ".env.local",
    ".git", ".gitignore",
    "kendex.toml", "kendex.settings.toml", ".kendex-lock.json", ".kendex-generated.json", ".cache",
    ".kendex", ".kendex-local",
    ".agents", ".claude", ".codex", ".github", ".pi", ".opencode", ".cursor", ".gemini",
    ".mcp.json", "opencode.json", "opencode.jsonc",
})
# The route keeps one copy of the persona: the installed file. An app that
# supplies the persona itself has its text loaded already.
ROUTE = ("Read `.agents/skills/jarvis/persona.md` and follow it."
         " Read it once per session; when its text is already loaded, use that text.\n")
INDEX = "# Memory index\n"
# The starting files Git carries: a folder holding both is an initialized
# home on every clone. STATE is the starting folder, which Git does not
# carry while it is empty.
FILES = (("memory/MEMORY.md", INDEX), ("AGENTS.md", ROUTE))
STATE = "state"
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
NOT_A_REPOSITORY = re.compile(r"^fatal: not a git repository", re.MULTILINE)
FEATURES_HEADER = re.compile(r"^[ \t]*\[[ \t]*features[ \t]*\][ \t]*(#[^\r\n]*)?(?=\r?\n|\Z)", re.MULTILINE)


class Unmergeable(ValueError):
    """The settings file holds the key's table in a form a textual insert cannot extend."""


class Refused(Exception):
    """The folder is not a dedicated home; nothing was written. NAME and VALUE name what refused it."""

    def __init__(self, cause, name=None, value=None):
        super().__init__(cause)
        self.cause, self.name, self.value = cause, name, value

    def line(self):
        return ("jarvis-session: init=refused cause=" + self.cause
                + (" " + self.name + "=" + json.dumps(self.value) if self.name else ""))


class Failed(Exception):
    """A step could not complete; `created` names what this call wrote before it."""

    def __init__(self, cause, path, created, detail=None):
        super().__init__(cause)
        self.cause, self.path, self.created, self.detail = cause, path, created, detail

    def line(self):
        return ("jarvis-session: init=failed path=" + self.path + " cause=" + self.cause
                + " created=" + ",".join(self.created)
                + (" detail=" + json.dumps(self.detail) if self.detail else ""))


def initialized(home):
    return all((Path(home) / relative).exists() for relative, _ in FILES)


def complete(home):
    return initialized(home) and (Path(home) / STATE).is_dir()


def toplevel(directory, path):
    """The work tree root git finds from DIRECTORY, or None outside every work tree; PATH names DIRECTORY in a failure."""
    env = {key: value for key, value in os.environ.items() if key not in GIT_REDIRECTS}
    # C keeps git's message in the words matched below.
    env["LC_ALL"] = "C"
    try:
        # rev-parse reads config and runs nothing; safe.directory keeps a
        # repository owned by someone else from reading as no repository.
        result = subprocess.run(["git", "-c", "safe.directory=*", "-C", str(directory), "rev-parse", "--show-toplevel"],
                                env=env, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as failure:
        raise Failed("git-" + type(failure).__name__, path, [])
    # git exits 128 on every fatal error. Only its not-a-repository outcome
    # means no work tree; a repository git cannot read may still enclose
    # DIRECTORY.
    if result.returncode == 128 and NOT_A_REPOSITORY.search(result.stderr):
        return None
    if result.returncode:
        raise Failed("git-exit-" + str(result.returncode), path, [], (result.stderr.splitlines() or [""])[0])
    return Path(result.stdout.strip()).resolve()


def qualify(home):
    root = toplevel(home, ".")
    if root is None:
        raise Refused("no-git")
    # The enclosing work tree: the one git finds from HOME when HOME is not
    # its root, else the one around HOME's own repository.
    if root == home:
        root = toplevel(home.parent, "..") if home.parent != home else None
    if root is not None:
        raise Refused("inside-work-tree", "work-tree", str(root))
    extra = sorted(set(os.listdir(home)) - NAMES)
    if extra:
        raise Refused("other-entry", "entry", extra[0])


def replace(path, text):
    # Same-directory staging keeps the replacement atomic and the mode as it was.
    mode = path.stat().st_mode & 0o7777 if path.exists() else None
    fd, name = tempfile.mkstemp(dir=path.parent, prefix="." + path.name + "-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as stream:
            stream.write(text)
        if mode is not None:
            os.chmod(name, mode)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def line_ending(text):
    ending = re.search(r"\r?\n", text)
    return ending.group() if ending else "\n"


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
    newline = line_ending(text)
    tail = newline if not data else ","
    return text[:start] + newline + '  "autoMemoryEnabled": false' + tail + text[start:], dict(data, autoMemoryEnabled=False)


def codex_config(text):
    import tomllib
    text = text or ""
    data = tomllib.loads(text)
    features = data.get("features")
    if isinstance(features, dict) and "memories" in features:
        return None
    expected = copy.deepcopy(data)
    expected.setdefault("features", {})["memories"] = False
    newline = line_ending(text)
    if features is None:
        separator = "" if not text else (newline if text.endswith("\n") else newline * 2)
        return text + separator + "[features]" + newline + "memories = false" + newline, expected
    header = FEATURES_HEADER.search(text)
    if not header:
        raise Unmergeable("features")
    end = header.end()
    return text[:end] + newline + "memories = false" + text[end:], expected


def merge(home, relative, key, edit, parse):
    """Add KEY when the file lacks it; a file that already names it keeps its value."""
    path = home / relative
    row = {"path": relative, "key": key}
    if path.is_symlink():
        return dict(row, outcome="refused", cause="linked")
    try:
        text = None
        if path.exists():
            # newline="" keeps user line endings untranslated on reads and
            # writes (docs.python.org/3/library/functions.html#open).
            with path.open(encoding="utf-8", newline="") as stream:
                text = stream.read()
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
    # A clone of an initialized home can lack only STATE; its own files and
    # entries were already judged when it was set up.
    if not initialized(home):
        qualify(home)
    created, kept = [], []
    try:
        (home / STATE).mkdir()
        created.append(STATE)
    except FileExistsError:
        if not (home / STATE).is_dir():
            raise Failed("not-a-directory", STATE, created)
        kept.append(STATE)
    except OSError as failure:
        raise Failed(type(failure).__name__, STATE, created)
    for relative, text in FILES:
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
