#!/usr/bin/env python3
"""Catch an attribute that has been separated from what it applies to.

Inserting a new function directly above an existing one is easy to get wrong by
exactly one line: the new code lands between `@ViewBuilder` and the declaration
it belongs to. The compiler's complaint is then about two things that both look
fine on their own — "only one result builder attribute can be attached" over
here, "no return statements from which to infer an underlying type" over there —
and neither names the edit that caused it. This has now cost two CI failures
(7c455e5, 2f74cf0), which is two more than a ten-line check is worth.

A Swift attribute must be followed by another attribute, a doc comment that
belongs to the same declaration, or the declaration itself. What it must never
be followed by is a blank line, a `//` comment, or — the case that bites — a
`///` doc comment that opens a *different* declaration's documentation.

The rule used here: an attribute line may be followed by another attribute or a
declaration keyword. A `///` line is allowed only if no blank line separates it
from what follows, and there is no second attribute after it — a doc comment
after an attribute and before another attribute means something was inserted in
between.

    python Tools/check-attributes.py            # the whole of Sources/
    python Tools/check-attributes.py <paths…>

Exit 0 when clean, 1 when something looks misplaced.
"""
import re
import sys
from pathlib import Path

# Only an attribute alone on its line can be separated from what it applies to.
# `@ViewBuilder var content: Content`, and a `@ViewBuilder` on a parameter, both
# carry their declaration with them.
ATTR = re.compile(r'^\s*@(ViewBuilder|MainActor|Sendable|Observable|inlinable|discardableResult)\s*$')
DECL = re.compile(r'^\s*(?:@\w+\s+)*(?:public |private |internal |fileprivate |static |final |override |nonisolated )*'
                  r'(?:func|var|let|init|deinit|struct|class|actor|protocol|enum|extension'
                  r'|subscript|typealias|associatedtype|case)\b')
DOC = re.compile(r'^\s*///')
COMMENT = re.compile(r'^\s*//(?!/)')


def check(path):
    lines = path.read_text(encoding='utf-8', errors='replace').splitlines()
    problems = []
    for i, line in enumerate(lines):
        if not ATTR.match(line):
            continue
        # Walk forward to whatever this attribute actually lands on.
        saw_doc = False
        for j in range(i + 1, min(i + 40, len(lines))):
            nxt = lines[j]
            if not nxt.strip():
                problems.append((i + 1, 'blank line between the attribute and its declaration'))
                break
            if COMMENT.match(nxt):
                problems.append((i + 1, 'a // comment sits between the attribute and its declaration'))
                break
            if DOC.match(nxt):
                saw_doc = True
                continue
            if ATTR.match(nxt):
                if saw_doc:
                    problems.append((i + 1, 'doc comment between two attributes — something was inserted here'))
                    break
                continue
            if DECL.match(nxt):
                break
            problems.append((i + 1, 'attribute is followed by %r' % nxt.strip()[:50]))
            break
    return problems


def main(argv):
    roots = [Path(a) for a in argv[1:]] or [Path('Sources')]
    files = []
    for root in roots:
        files.extend(root.rglob('*.swift') if root.is_dir() else [root])

    failures = 0
    for path in sorted(files):
        for line, why in check(path):
            print('%s:%d: %s' % (path.as_posix(), line, why))
            failures += 1

    if failures:
        print('\n%d misplaced attribute(s).' % failures)
        return 1
    print('attributes: %d files clean' % len(files))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
