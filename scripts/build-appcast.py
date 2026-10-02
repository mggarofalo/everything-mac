#!/usr/bin/env python3
"""Sign a package update and its feed with the EverythingMac Keychain key."""
import argparse
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path
import plistlib
import re
import subprocess
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
RELEASES = "https://github.com/mggarofalo/everything-mac/releases"


def build_feed(info, package, signature):
    version = info["CFBundleShortVersionString"]
    build = info["CFBundleVersion"]
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or not re.fullmatch(r"[1-9]\d*", build):
        raise ValueError("Release version and build number must be numeric.")
    if package.name != f"EverythingMac-{version}.pkg":
        raise ValueError("The package filename must match the app release version.")
    ET.register_namespace("sparkle", SPARKLE)
    rss = ET.Element("rss", version="2.0")
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "EverythingMac updates"
    ET.SubElement(channel, "link").text = RELEASES
    ET.SubElement(channel, "description").text = "Signed EverythingMac updates"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"EverythingMac {version}"
    ET.SubElement(item, "link").text = f"{RELEASES}/tag/v{version}"
    ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc))
    ET.SubElement(item, f"{{{SPARKLE}}}version").text = build
    ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = version
    minimum = info["LSMinimumSystemVersion"]
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = minimum + ".0" if minimum.count(".") == 1 else minimum
    ET.SubElement(item, "enclosure", {
        "url": f"{RELEASES}/download/v{version}/{package.name}",
        "length": str(package.stat().st_size),
        "type": "application/octet-stream",
        f"{{{SPARKLE}}}installationType": "package",
        f"{{{SPARKLE}}}edSignature": signature,
    })
    ET.indent(rss)
    return ET.ElementTree(rss)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--sparkle-bin", type=Path, required=True,
                        help="bin directory from the official Sparkle release")
    args = parser.parse_args()
    info = plistlib.loads((args.app / "Contents/Info.plist").read_bytes())
    signer = str(args.sparkle_bin / "sign_update")
    keygen = str(args.sparkle_bin / "generate_keys")
    public_key = subprocess.check_output([keygen, "--account", "everythingmac", "-p"], text=True).strip()
    if public_key != info["SUPublicEDKey"]:
        raise ValueError("The Keychain signing key does not match the app's public key.")
    signature = subprocess.check_output(
        [signer, "--account", "everythingmac", "-p", str(args.package)], text=True).strip()
    subprocess.run([signer, "--account", "everythingmac", "--verify", str(args.package), signature], check=True)
    feed = args.package.parent / "appcast.xml"
    build_feed(info, args.package, signature).write(feed, encoding="utf-8", xml_declaration=True)
    subprocess.run([signer, "--account", "everythingmac", str(feed)], check=True)
    subprocess.run([signer, "--account", "everythingmac", "--verify", str(feed)], check=True)
    print(f"Signed update feed: {feed}")


if __name__ == "__main__":
    main()
