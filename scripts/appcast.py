#!/usr/bin/env python3
"""Adds a published release to Pond's appcast (site/public/appcast.xml), the feed Sparkle reads for updates of the app
(docs/release.md, Updates): its version and build number, Sparkle's signature of its disk image and its size (the
release's Pond-VERSION.sparkle, made by make release), where to download it, and its notes (CHANGELOG.md's section,
as HTML). Newest first; a version already there is replaced. Run by the appcast workflow when a release is published.

    python3 scripts/appcast.py 0.2.0 Pond-0.2.0.sparkle
"""
import email.utils
import html
import os
import re
import subprocess
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
APPCAST = os.path.join(ROOT, "site", "public", "appcast.xml")
REPO = os.environ.get("GITHUB_REPOSITORY", "smithki/pond-nvr")
MINIMUM_SYSTEM = "27.0"


def inline(text):
    """A line of the changelog's Markdown as HTML: bold, code and links; everything else escaped."""
    text = html.escape(text, quote=False)
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"`(.+?)`", r"<code>\1</code>", text)
    return re.sub(r"\[(.+?)\]\((.+?)\)", lambda m: f'<a href="{html.escape(m.group(2))}">{m.group(1)}</a>', text)


def notes_html(markdown):
    """The changelog section's headings, paragraphs and lists (a list item's continued lines joined)."""
    out, items, paragraph = [], [], []

    def flush():
        if items:
            out.append("<ul>" + "".join(f"<li>{inline(i)}</li>" for i in items) + "</ul>")
            items.clear()
        if paragraph:
            out.append(f"<p>{inline(' '.join(paragraph))}</p>")
            paragraph.clear()

    for line in markdown.splitlines():
        if line.startswith("### "):
            flush()
            out.append(f"<h3>{inline(line[4:])}</h3>")
        elif line.startswith("- "):
            if paragraph:
                flush()
            items.append(line[2:].strip())
        elif line.startswith("  ") and items:
            items[-1] += " " + line.strip()
        elif not line.strip():
            flush()
        else:
            paragraph.append(line.strip())
    flush()
    return "\n".join(out)


def main():
    version, sparkle_file = sys.argv[1:3]
    attributes = dict(re.findall(r'(sparkle:\w+|length)="([^"]*)"', open(sparkle_file).read()))
    for needed in ("sparkle:version", "sparkle:edSignature", "length"):
        if needed not in attributes:
            sys.exit(f"✗ {sparkle_file} has no {needed}")
    notes = subprocess.run([os.path.join(ROOT, "scripts", "release-notes.sh"), version], capture_output=True, text=True,
                           check=True).stdout
    if not notes.strip():
        sys.exit(f"✗ CHANGELOG.md has no section for {version}")
    url = f"https://github.com/{REPO}/releases/download/v{version}/Pond-{version}.dmg"
    item = f"""    <item>
      <title>Pond {version}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{attributes["sparkle:version"]}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{MINIMUM_SYSTEM}</sparkle:minimumSystemVersion>
      <description><![CDATA[{notes_html(notes)}]]></description>
      <enclosure url="{url}" type="application/octet-stream" sparkle:edSignature="{attributes["sparkle:edSignature"]}" length="{attributes["length"]}"/>
    </item>
"""
    feed = open(APPCAST).read()
    # A version already there replaced (a release published again), then the new one first in the channel.
    feed = re.sub(rf"    <item>\n      <title>Pond {re.escape(version)}</title>.*?    </item>\n", "", feed, flags=re.S)
    feed = feed.replace("    <language>en</language>\n", "    <language>en</language>\n" + item, 1)
    open(APPCAST, "w").write(feed)
    print(f"✓ {APPCAST}: Pond {version} (build {attributes['sparkle:version']})")


if __name__ == "__main__":
    main()
