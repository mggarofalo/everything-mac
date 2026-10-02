#!/usr/bin/env python3
"""Render all Installer pages with one font stack and explicit UTF-8 encoding."""
from html import escape
from pathlib import Path
import sys


def page(title, paragraphs):
    body = "\n".join(f"<p>{escape(paragraph)}</p>" for paragraph in paragraphs)
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{escape(title)}</title>
<style>
body {{ font-family: Helvetica, Arial, sans-serif; font-size: 13px; line-height: 1.5; margin: 24px; }}
h1 {{ font-family: Helvetica, Arial, sans-serif; font-size: 20px; margin: 0 0 16px; }}
p {{ margin: 0 0 14px; }}
</style>
</head>
<body>
<h1>{escape(title)}</h1>
{body}
</body>
</html>
"""


destination = Path(sys.argv[1])
destination.mkdir(parents=True, exist_ok=True)
(destination / "Welcome.html").write_text(page("Install or update EverythingMac", [
    "The installer will close EverythingMac and its background services, install the new version in Applications, and reopen the app.",
    "Your index and settings are preserved. You do not need to quit anything manually.",
    "macOS will ask you to authorize installing EverythingMac. Choose Install Software in the system prompt to continue.",
]), encoding="utf-8")
(destination / "Conclusion.html").write_text(page("EverythingMac is installed", [
    "Open EverythingMac from Applications if it has not reopened.",
    "On a first installation, enable EverythingMac in System Settings > Privacy & Security > Full Disk Access.",
    "For future updates, choose EverythingMac > Check for Updates...",
]), encoding="utf-8")
