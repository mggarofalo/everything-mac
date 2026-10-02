#!/usr/bin/env python3
"""Format the authoritative MIT license as an informational Installer readme."""
from html import escape
from pathlib import Path
import sys

source, destination = map(Path, sys.argv[1:])
paragraphs = source.read_text().strip().split("\n\n")
title, *body = paragraphs
notice = "\n".join(f"<p>{escape(' '.join(paragraph.splitlines()))}</p>" for paragraph in body)
destination.write_text(f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Open-source license notice</title>
<style>
body {{ font-family: -apple-system, Helvetica, sans-serif; font-size: 13px; line-height: 1.5; margin: 24px; }}
h1 {{ font-size: 20px; margin-bottom: 8px; }}
h2 {{ font-size: 16px; margin-top: 24px; }}
p {{ margin: 0 0 14px; }}
</style>
</head>
<body>
<h1>Open-source license notice</h1>
<p>EverythingMac is distributed under the MIT License. This notice is provided for your information; no acceptance is requested.</p>
<h2>{escape(title)}</h2>
{notice}
</body>
</html>
""")
