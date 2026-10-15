#!/usr/bin/env python3 -I
"""Dead-code candidates: declarations nothing else refers to.

Lists every type, function, property and enum case declared in Sources, then
counts references to each name across Sources and Tests outside comments. A
name used only where it is declared is a candidate — evidence to read, not a
verdict: SwiftUI, Codable and AppKit call some things by convention, and those
are skipped by name below.

Also reports comments that mention names which no longer exist anywhere in
code, the residue of removed features.

Usage: Tools/refscan.py <repo root>
"""
import os
import re
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."

# Called by the frameworks, never by name from our code.
CONVENTIONAL = {
    "body", "init", "deinit", "main", "makeBody", "sizeThatFits", "placeSubviews", "path",
    "encode", "hash", "description", "id", "rawValue", "allCases", "CodingKeys", "LegacyKeys",
    "applicationDidFinishLaunching", "applicationWillTerminate", "applicationShouldHandleReopen",
    "draggingEntered", "draggingUpdated", "draggingExited", "draggingEnded", "performDragOperation",
    "prepareForDragOperation", "draggingSession", "mouseDown", "mouseDragged", "mouseUp", "mouseEntered",
    "mouseExited", "updateTrackingAreas", "acceptsFirstMouse", "canBecomeKey", "canBecomeMain",
    "constrainFrameRect", "resignKey", "cancelOperation", "windowWillClose", "windowDidResignKey",
    "numberOfPreviewItems", "previewPanel", "ssidDidChangeForWiFiInterface", "userNotificationCenter",
    "accessibilityLabel", "previews", "isEqual", "copy", "layout", "viewDidMoveToWindow", "keyDown",
    "applicationWillFinishLaunching", "applicationShouldTerminateAfterLastWindowClosed",
    "makeNSView", "updateNSView", "hitTest", "popoverDidClose", "GruppenApp",
}


def swift_files(*dirs):
    for directory in dirs:
        for root, _, files in os.walk(os.path.join(ROOT, directory)):
            for name in files:
                if name.endswith(".swift"):
                    yield os.path.join(root, name)


def strip_line_comment(line):
    """The line up to a `//` that is not inside a string literal."""
    quoted = False
    for index, char in enumerate(line):
        if char == '"' and (index == 0 or line[index - 1] != "\\"):
            quoted = not quoted
        elif not quoted and line.startswith("//", index):
            return line[:index]
    return line


def strip_comments(text):
    # Block comments become their own line breaks, so line numbers survive.
    text = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group().count("\n"), text, flags=re.S)
    return "\n".join(strip_line_comment(line) for line in text.splitlines())


DECL = re.compile(
    r"^(?P<indent>\s*)(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:private|fileprivate|internal|public|open|static|final|"
    r"override|nonisolated|mutating|lazy|weak|unowned|convenience|required|@objc|class)\s+)*"
    r"(?P<kind>struct|class|enum|protocol|actor|func|var|let|case|typealias)\s+(?P<name>[A-Za-z_]\w*)",
    re.M)

sources = {path: open(path, encoding="utf-8").read() for path in swift_files("Sources")}
tests = {path: open(path, encoding="utf-8").read() for path in swift_files("Tests")}
code = {path: strip_comments(text) for path, text in {**sources, **tests}.items()}
corpus = "\n".join(code.values())

counts = {}
for word in re.findall(r"[A-Za-z_]\w*", corpus):
    counts[word] = counts.get(word, 0) + 1

def kept_by_type(original, text, offset):
    """Whether the nearest enclosing type declaration carries `sweep: keep`."""
    lines = original.splitlines()
    for number in range(text[:offset].count("\n"), -1, -1):
        if re.match(r"^\s*(?:\w+\s+)*(struct|class|enum|actor)\s", lines[number]):
            return "sweep: keep" in lines[number]
    return False


candidates = []
for path, original in sources.items():
    text = strip_comments(original)
    for match in DECL.finditer(text):
        name, kind, indent = match["name"], match["kind"], len(match["indent"].expandtabs(4))
        if name in CONVENTIONAL or name.startswith("_"):
            continue
        # `// sweep: keep` on the line, or on its type's line, exempts it —
        # fields mirroring a C struct's layout, say, which nothing reads.
        line_text = original.splitlines()[text[:match.start()].count("\n")]
        if "sweep: keep" in line_text or kept_by_type(original, text, match.start()):
            continue
        # Locals inside function bodies are the compiler's business (pass 1).
        if kind in ("var", "let") and indent > 4:
            continue
        line = text[:match.start()].count("\n") + 1
        declared = len(re.findall(rf"\b(?:struct|class|enum|protocol|actor|func|var|let|case|typealias)\s+{name}\b", corpus))
        uses = counts.get(name, 0) - declared
        if uses <= 0:
            candidates.append((os.path.relpath(path, ROOT), line, kind, name))

print(f"## Unreferenced declarations ({len(candidates)})\n")
for path, line, kind, name in sorted(candidates):
    print(f"{path}:{line}  {kind} {name}")

# Comments naming one of *our* declarations that has since been removed:
# absent from the code today, but declared somewhere in git history.
print("\n## Comments naming removed code\n")
import subprocess
identifier = re.compile(r"`([A-Z][A-Za-z]+)`")
mentions = {}
for path, text in sources.items():
    for number, line in enumerate(text.splitlines(), 1):
        if "//" in line:
            for name in identifier.findall(line.split("//", 1)[1]):
                if counts.get(name, 0) == 0:
                    mentions.setdefault(name, []).append(f"{os.path.relpath(path, ROOT)}:{number}")
stale = []
for name, places in sorted(mentions.items()):
    history = subprocess.run(["git", "-C", ROOT, "log", "--oneline", "-1", "-G",
                              rf"(struct|class|enum|func|var|let|case) {name}\b", "--", "Sources"],
                             capture_output=True, text=True).stdout.strip()
    if history:
        stale += [f"{place}  `{name}` (removed; last seen {history.split()[0]})" for place in places]
print("\n".join(stale) or "none")
