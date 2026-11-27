#!/usr/bin/env python3
"""Turns a release tag's message into the release's title and notes.

  Scripts/release-notes.py <tag message> <notes.md> <title.txt>

The release workflow (.github/workflows/release.yml) runs it on the message of the tag it builds:
an annotated tag (git tag -a), its first line the release's title ("Huddle 1.4.3: …"), the rest
its notes, as paragraphs and "- " lists. Lines broken to fit a terminal are joined again (GitHub
and Sparkle would show the breaks), and trailers such as Co-Authored-By, and a signature, are left
out. A tag with no message, or only a title, gives empty notes: the workflow lists the commits
since the last release instead. Scripts/appcast.py turns the notes into the appcast's HTML.
"""
import re
import sys

# The usual git trailers only: a closing paragraph that happens to start "Note: …" stays.
TRAILER = re.compile(r"^(Co-authored-by|Signed-off-by|Reviewed-by|Acked-by|Tested-by|Reported-by|"
                     r"Suggested-by|Helped-by|Cc|Fixes|Refs|See-also|Change-Id): \S", re.I)
BULLET = re.compile(r"^\s*[-*•]\s+")


def parse(message):
    """(title, notes as Markdown) from a tag's message."""
    # A signed tag's signature comes after its message.
    message = re.split(r"^-----BEGIN (?:PGP|SSH) SIGNATURE-----", message, flags=re.M)[0]
    lines = [line.rstrip() for line in message.splitlines()]
    while lines and not lines[0]:
        lines.pop(0)
    if not lines:
        return "", ""
    title, body = lines[0].strip(), lines[1:]

    paragraphs, current = [], []
    for line in body + [""]:
        if line.strip():
            current.append(line)
        elif current:
            paragraphs.append(current)
            current = []
    # Trailers: a last paragraph of nothing but "Key: value" lines.
    if paragraphs and all(TRAILER.match(line) for line in paragraphs[-1]):
        paragraphs.pop()

    blocks = []
    for paragraph in paragraphs:
        if BULLET.match(paragraph[0]):
            items = []
            for line in paragraph:
                if BULLET.match(line):
                    items.append(BULLET.sub("", line).strip())
                else:  # an item's text going on onto the next line
                    items[-1] += " " + line.strip()
            blocks.append("\n".join("- " + item for item in items))
        else:
            blocks.append(" ".join(line.strip() for line in paragraph))
    return title, "\n\n".join(blocks)


def main():
    source, notes_path, title_path = sys.argv[1:4]
    with open(source, encoding="utf-8") as f:
        title, notes = parse(f.read())
    with open(notes_path, "w", encoding="utf-8") as f:
        f.write(notes + "\n" if notes else "")
    with open(title_path, "w", encoding="utf-8") as f:
        f.write(title + "\n" if title else "")


if __name__ == "__main__":
    main()
