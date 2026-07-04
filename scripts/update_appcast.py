#!/usr/bin/env python3
"""Prepend a release item to appcast.xml, creating the file if needed."""
import argparse
import datetime
import os
import re
import sys

APPCAST_SKELETON = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Sill Updates</title>
    <link>{feed_url}</link>
    <description>Release updates for Sill.</description>
    <language>en</language>
{items}  </channel>
</rss>
"""

ITEM_TEMPLATE = """    <item>
      <title>Version {version}</title>
      <pubDate>{pub_date}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{min_os}</sparkle:minimumSystemVersion>
      <enclosure url="{url}" length="{length}" type="application/octet-stream" {sig_attr} />
    </item>
"""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--appcast", required=True)
    parser.add_argument("--feed-url", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--min-os", default="14.0")
    parser.add_argument("--sig-line", required=True, help='output of sign_update, e.g. sparkle:edSignature="..." length="123"')
    args = parser.parse_args()

    sig_match = re.search(r'sparkle:edSignature="([^"]+)"', args.sig_line)
    length_match = re.search(r'length="(\d+)"', args.sig_line)
    if not sig_match or not length_match:
        print(f"Could not parse sign_update output: {args.sig_line!r}", file=sys.stderr)
        return 1

    sig_attr = f'sparkle:edSignature="{sig_match.group(1)}"'
    length = length_match.group(1)
    pub_date = datetime.datetime.now(datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")

    new_item = ITEM_TEMPLATE.format(
        version=args.version,
        build=args.build,
        pub_date=pub_date,
        min_os=args.min_os,
        url=args.url,
        length=length,
        sig_attr=sig_attr,
    )

    if os.path.exists(args.appcast):
        with open(args.appcast, "r", encoding="utf-8") as f:
            content = f.read()
        marker = "  </channel>"
        idx = content.rindex(marker)
        content = content[:idx] + new_item + content[idx:]
    else:
        content = APPCAST_SKELETON.format(feed_url=args.feed_url, items=new_item)

    with open(args.appcast, "w", encoding="utf-8") as f:
        f.write(content)

    print(f"Added {args.version} ({args.build}) to {args.appcast}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
