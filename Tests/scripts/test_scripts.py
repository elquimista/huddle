#!/usr/bin/env python3
"""Tests for the release and build scripts in Scripts/, which run on CI where a mistake ships.

  python3 -I -B Tests/scripts/test_scripts.py
"""
import base64
import hashlib
import importlib.util
import os
import re
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True
SCRIPTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "Scripts")
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def load(name):
    """A script as a module (their names have hyphens, so not by import)."""
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), os.path.join(SCRIPTS, name))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


release_notes = load("release-notes.py")
appcast = load("appcast.py")
csp = load("element-call-csp.py")


class ReleaseNotesTests(unittest.TestCase):
    def test_title_and_notes(self):
        title, notes = release_notes.parse(
            "Huddle 1.4.4: faster and safer\n\nThis update makes long\nconversations quicker.\n\n"
            "- Pictures too large\n  wait for a click.\n- Drafts are encrypted.\n")
        self.assertEqual(title, "Huddle 1.4.4: faster and safer")
        self.assertEqual(notes, "This update makes long conversations quicker.\n\n"
                                "- Pictures too large wait for a click.\n- Drafts are encrypted.")

    def test_trailers_and_signatures_are_left_out(self):
        _, notes = release_notes.parse(
            "Title\n\nWhat's new.\n\nCo-Authored-By: Claude <noreply@anthropic.com>\nSigned-off-by: Someone <a@b.c>\n"
            "-----BEGIN PGP SIGNATURE-----\nabc\n-----END PGP SIGNATURE-----\n")
        self.assertEqual(notes, "What's new.")

    def test_a_closing_paragraph_that_isnt_a_trailer_stays(self):
        _, notes = release_notes.parse("Title\n\nWhat's new.\n\nNote: macOS 14 or later.\n")
        self.assertEqual(notes, "What's new.\n\nNote: macOS 14 or later.")

    def test_no_message(self):
        self.assertEqual(release_notes.parse(""), ("", ""))
        self.assertEqual(release_notes.parse("Only a title\n"), ("Only a title", ""))


class AppcastTests(unittest.TestCase):
    def test_notes_as_html(self):
        self.assertEqual(appcast.notes_html("Intro <with> & stuff.\n\n- One\n- Two's"),
                         "<p>Intro &lt;with&gt; &amp; stuff.</p><ul><li>One</li><li>Two&#x27;s</li></ul>")

    def test_an_entry_for_one_line_of_releases(self):
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "appcast.xml")
            common = ["--url", "https://example.org/Huddle.zip", "--length", "123", "--signature", "c2ln"]

            def notes(text):
                file = os.path.join(folder, f"notes-{len(text)}.md")
                with open(file, "w", encoding="utf-8") as f:
                    f.write(text)
                return file

            subprocess.run([sys.executable, "-I", "-B", os.path.join(SCRIPTS, "appcast.py"), path, "--version", "1.4.4",
                            "--build", "1150", "--notes", notes("Faster.\n\n- One")] + common, check=True, capture_output=True)
            subprocess.run([sys.executable, "-I", "-B", os.path.join(SCRIPTS, "appcast.py"), path, "--version", "0.13.14",
                            "--build", "150", "--minimum-system", "13.0", "--maximum-system", "13.99",
                            "--notes", notes("For macOS 13.")] + common, check=True, capture_output=True)
            items = {item.findtext("title"): item for item in ET.parse(path).getroot().iter("item")}
            main, legacy = items["Huddle 1.4.4"], items["Huddle 0.13.14"]
            self.assertEqual(main.findtext(SPARKLE + "version"), "1150")
            self.assertEqual(main.findtext(SPARKLE + "minimumSystemVersion"), "14.0")
            self.assertIsNone(main.find(SPARKLE + "maximumSystemVersion"))
            self.assertEqual(main.findtext("description"), "<p>Faster.</p><ul><li>One</li></ul>")
            self.assertEqual(legacy.findtext(SPARKLE + "minimumSystemVersion"), "13.0")
            self.assertEqual(legacy.findtext(SPARKLE + "maximumSystemVersion"), "13.99")
            self.assertEqual(main.find("enclosure").get(SPARKLE + "edSignature"), "c2ln")


class ElementCallPolicyTests(unittest.TestCase):
    PAGE = ('<!doctype html><html lang="en"><head><meta charset="UTF-8"><title>Element Call</title>'
            '<script>window.global = window;</script><script>if (!x) { y(); }</script>'
            '<script type="module" crossorigin src="./assets/index.js"></script></head><body></body></html>')

    def run_on(self, page):
        with tempfile.NamedTemporaryFile("w", suffix=".html", delete=False, encoding="utf-8") as f:
            f.write(page)
        try:
            result = subprocess.run([sys.executable, "-I", "-B", os.path.join(SCRIPTS, "element-call-csp.py"), f.name],
                                    capture_output=True, text=True)
            return result, open(f.name, encoding="utf-8").read()
        finally:
            os.unlink(f.name)

    def policy(self, page):
        return re.search(r'http-equiv="Content-Security-Policy" content="([^"]*)"', page).group(1)

    def test_the_policy_comes_before_any_script(self):
        result, page = self.run_on(self.PAGE)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(page.index("Content-Security-Policy"), page.index("<script"))
        self.assertLess(page.index('<meta charset="UTF-8">'), page.index("Content-Security-Policy"))

    def test_only_the_pages_own_scripts_run(self):
        _, page = self.run_on(self.PAGE)
        directives = dict(part.strip().split(" ", 1) for part in self.policy(page).split(";"))
        self.assertEqual(directives["default-src"], "'none'")
        for inline in ("window.global = window;", "if (!x) { y(); }"):
            digest = base64.b64encode(hashlib.sha256(inline.encode()).digest()).decode()
            self.assertIn(f"'sha256-{digest}'", directives["script-src"])
        self.assertNotIn("https:", directives["script-src"])
        self.assertNotIn("'unsafe-inline'", directives["script-src"])
        self.assertNotIn("'unsafe-eval'", directives["script-src"])
        for none in ("frame-src", "object-src", "base-uri", "form-action"):
            self.assertEqual(directives[none], "'none'", none)
        # HTTPS anywhere; plain HTTP only to this Mac.
        connect = directives["connect-src"].split()
        self.assertIn("https:", connect)
        self.assertNotIn("http:", connect)
        self.assertTrue(all(s.startswith(("http://localhost", "ws://localhost", "http://127.0.0.1", "ws://127.0.0.1"))
                            for s in connect if s.startswith(("http://", "ws://"))))

    def test_a_page_with_a_policy_already_stops_the_build(self):
        _, once = self.run_on(self.PAGE)
        result, _ = self.run_on(once)
        self.assertNotEqual(result.returncode, 0)

    def test_a_page_without_a_head_stops_the_build(self):
        result, _ = self.run_on("<html><body><script>x()</script></body></html>")
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
