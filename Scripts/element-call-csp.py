#!/usr/bin/env python3
"""Gives Element Call's page, as bundled into the app, a content security policy.

  Scripts/element-call-csp.py <the app's ElementCall/index.html>

build-app.sh runs it on the copy of Element Call it puts in the app (Vendor/ElementCall stays as
fetched). The page runs with a bridge into Huddle that can send events into the room, so it runs
only its own code: its scripts from the app (its two inline ones by their hashes), nothing from
anywhere else, no frames, no plugins, no forms. It may still connect out over HTTPS and secure
WebSockets, to the homeserver and the call server (LiveKit, whichever the homeserver names), and
over plain HTTP to a server on this Mac, as Huddle signs in to one.

The policy goes first in the page's head, before any script, as a meta tag; a page with one
already, or without the head it expects, stops the build rather than going out without it.
"""
import base64
import hashlib
import re
import sys

MARKER = 'http-equiv="Content-Security-Policy"'


def policy(inline_scripts):
    hashes = " ".join(f"'sha256-{base64.b64encode(hashlib.sha256(s.encode()).digest()).decode()}'"
                      for s in inline_scripts)
    return "; ".join([
        "default-src 'none'",
        f"script-src file: {hashes}",
        "worker-src file: blob:",
        "style-src file: 'unsafe-inline'",
        "img-src file: data: blob: https:",
        "font-src file: data:",
        "media-src file: data: blob: mediastream:",
        # Plain HTTP only to a server on this Mac, as signing in allows (LoginFlow).
        "connect-src file: data: blob: https: wss: http://localhost:* ws://localhost:* http://127.0.0.1:* ws://127.0.0.1:*",
        "manifest-src file:",
        "frame-src 'none'",
        "object-src 'none'",
        "base-uri 'none'",
        "form-action 'none'",
    ])


def main():
    path = sys.argv[1]
    html = open(path, encoding="utf-8").read()
    if MARKER in html:
        sys.exit(f"error: {path} has a content security policy already")
    inline = re.findall(r"<script(?![^>]*\bsrc=)[^>]*>(.*?)</script>", html, flags=re.S)
    head = re.search(r"<head>(\s*<meta charset=\"UTF-8\">)?", html, flags=re.I)
    if not head:
        sys.exit(f"error: no <head> in {path}")
    meta = f'<meta {MARKER} content="{policy(inline)}">'
    html = html[:head.end()] + meta + html[head.end():]
    open(path, "w", encoding="utf-8").write(html)
    print(f"Element Call: content security policy added ({len(inline)} inline scripts allowed by hash)")


if __name__ == "__main__":
    main()
