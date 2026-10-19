"""ATX Markdown headings outside code fences, for every Jarvis section reader and writer."""
import re


def headings(lines):
    """Return (line index, level, title) for each heading in keepends lines."""
    found = []
    fence = None
    for index, line in enumerate(lines):
        text = line.rstrip("\r\n")
        marker = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", text)
        if fence:
            if marker and marker[1][0] == fence[0] and len(marker[1]) >= len(fence) and not marker[2].strip():
                fence = None
            continue
        if marker and (marker[1][0] == "~" or "`" not in marker[2]):
            fence = marker[1]
            continue
        match = re.match(r"^ {0,3}(#{1,6})(?:[ \t]+(.*)|$)", text)
        if match:
            title = re.sub(r"[ \t]+#+[ \t]*$", "", match[2] or "").strip(" \t")
            found.append((index, len(match[1]), title))
    return found


def section(lines, heading):
    """Return (start, end) line indexes of the one section titled heading.

    A title matching no heading or several raises LookupError carrying the
    refusal key and the candidate headings.
    """
    found = headings(lines)
    matches = [row for row in found if row[2] == heading]
    if len(matches) != 1:
        raise LookupError("ambiguous-heading" if matches else "unknown-heading", matches if matches else found)
    start, level, _ = matches[0]
    end = next((index for index, depth, _ in found if index > start and depth <= level), len(lines))
    return start, end
