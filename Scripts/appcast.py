#!/usr/bin/env python3
"""Adds a release to Huddle's appcast, the feed Sparkle reads to find updates.

  Scripts/appcast.py <appcast.xml> --version 0.2.0 --build 45 --url <archive URL> \\
      --length <bytes> --signature <EdDSA signature from sign_update> \\
      [--changes <file, one change per line>] [--beta]

The release workflow runs it for every tag (.github/workflows/release.yml). It makes the appcast if
there isn't one, and replaces the item for the same version (when a tag's workflow runs again).
Newest first. Sparkle compares --build with an app's CFBundleVersion; --beta puts the release in
the "beta" channel, offered only to those who chose beta versions in Settings.
"""
import argparse
import email.utils
import html
import os
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def sparkle(tag):
    return f"{{{SPARKLE}}}{tag}"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("appcast")
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--length", required=True)
    parser.add_argument("--signature", required=True)
    parser.add_argument("--changes")
    parser.add_argument("--beta", action="store_true")
    parser.add_argument("--minimum-system", default="14.0")
    args = parser.parse_args()

    if os.path.exists(args.appcast):
        tree = ET.parse(args.appcast)
        channel = tree.getroot().find("channel")
    else:
        root = ET.Element("rss", {"version": "2.0"})
        channel = ET.SubElement(root, "channel")
        ET.SubElement(channel, "title").text = "Huddle"
        tree = ET.ElementTree(root)

    for item in channel.findall("item"):
        if item.findtext(sparkle("shortVersionString")) == args.version:
            channel.remove(item)

    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"Huddle {args.version}"
    ET.SubElement(item, "pubDate").text = email.utils.formatdate(usegmt=True)
    ET.SubElement(item, sparkle("version")).text = args.build
    ET.SubElement(item, sparkle("shortVersionString")).text = args.version
    ET.SubElement(item, sparkle("minimumSystemVersion")).text = args.minimum_system
    if args.beta:
        ET.SubElement(item, sparkle("channel")).text = "beta"
    if args.changes:
        with open(args.changes, encoding="utf-8") as f:
            changes = [line.strip() for line in f if line.strip()]
        if changes:
            # Shown above the Install button, as HTML.
            ET.SubElement(item, "description").text = (
                "<ul>" + "".join(f"<li>{html.escape(change)}</li>" for change in changes) + "</ul>")
    ET.SubElement(item, "enclosure", {
        "url": args.url,
        "length": args.length,
        "type": "application/octet-stream",
        sparkle("edSignature"): args.signature,
    })

    first = next((index for index, child in enumerate(channel) if child.tag == "item"), len(channel))
    channel.insert(first, item)
    ET.indent(tree, "  ")
    tree.write(args.appcast, encoding="utf-8", xml_declaration=True)


if __name__ == "__main__":
    main()
