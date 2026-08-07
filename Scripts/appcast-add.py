"""Add (or replace) one release item in a Sparkle appcast.

Called by Scripts/appcast.sh after sign_update. Idempotent per version: re-running for a
version already listed replaces its item rather than duplicating it, so a botched publish
can be redone. Newest item is written first, which is cosmetic — Sparkle picks the best
applicable version regardless of order.

Exists instead of Sparkle's own generate_appcast because that tool takes a single
--download-url-prefix for a whole folder, while a GitHub release asset URL embeds its tag
and therefore differs per version.

Usage:
  appcast-add.py --appcast appcast.xml --short-version 0.2.0 --version 5 \
      --url https://github.com/…/releases/download/v0.2.0/ClawBar-0.2.0.dmg \
      --sig-attrs 'sparkle:edSignature="…" length="…"' \
      --min-system 14.0 [--link https://…/releases/tag/v0.2.0]
"""

import argparse
import email.utils
import os
import re
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def s(tag: str) -> str:
    return f"{{{SPARKLE}}}{tag}"


def load_or_create(path: str, channel_title: str):
    if os.path.exists(path) and os.path.getsize(path) > 0:
        tree = ET.parse(path)
        root = tree.getroot()
        channel = root.find("channel")
        if channel is None:
            raise SystemExit(f"{path} has no <channel>")
        return root, channel

    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = channel_title
    return root, channel


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--appcast", required=True)
    p.add_argument("--short-version", required=True, help="CFBundleShortVersionString, e.g. 0.2.0")
    p.add_argument("--version", required=True, help="CFBundleVersion (build number)")
    p.add_argument("--url", required=True, help="public enclosure (DMG) URL")
    p.add_argument("--sig-attrs", required=True,
                   help='verbatim sign_update output: sparkle:edSignature="…" length="…"')
    p.add_argument("--min-system", required=True)
    p.add_argument("--link", help="human-readable release page")
    p.add_argument("--title", default="ClawBar")
    args = p.parse_args()

    sig = re.search(r'sparkle:edSignature="([^"]+)"', args.sig_attrs)
    length = re.search(r'length="([^"]+)"', args.sig_attrs)
    if not sig or not length:
        raise SystemExit(f"could not parse sign_update output: {args.sig_attrs!r}")

    root, channel = load_or_create(args.appcast, args.title)

    # Drop any existing item for this short version so re-publishing replaces it.
    for item in list(channel.findall("item")):
        existing = item.find(s("shortVersionString"))
        if existing is not None and existing.text == args.short_version:
            channel.remove(item)

    item = ET.Element("item")
    ET.SubElement(item, "title").text = args.short_version
    if args.link:
        ET.SubElement(item, "link").text = args.link
    ET.SubElement(item, "pubDate").text = email.utils.formatdate(localtime=True)
    ET.SubElement(item, s("version")).text = args.version
    ET.SubElement(item, s("shortVersionString")).text = args.short_version
    ET.SubElement(item, s("minimumSystemVersion")).text = args.min_system
    ET.SubElement(item, "enclosure", {
        "url": args.url,
        "type": "application/octet-stream",
        "length": length.group(1),
        s("edSignature"): sig.group(1),
    })

    # Newest first.
    first = channel.find("item")
    channel.insert(list(channel).index(first) if first is not None else len(list(channel)), item)

    ET.indent(root, space="  ")
    ET.ElementTree(root).write(args.appcast, encoding="utf-8", xml_declaration=True)
    print(f"appcast updated: {args.appcast} -> {args.short_version} (build {args.version})")


if __name__ == "__main__":
    main()
