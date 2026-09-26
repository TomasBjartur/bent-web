#!/usr/bin/env python3
"""Bundles the browser editor (src/web/editor.html -> editor.js + the CRDT
compiled to JS) into build/web/editor.bundle.js, served at
/s/editor.js. The bundle is embedded into the server binary by C (#embed in
src/effects/db.c), so it never becomes a Bend String. Run by build.sh.""" 
import glob, os, subprocess, sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
out = os.path.join(root, "build", "web")
subprocess.run(["rm", "-rf", out], check=True)
subprocess.run(["bend", os.path.join(root, "src/web/editor.html"), "-o", out], check=True, stdout=subprocess.DEVNULL)
chunks = glob.glob(os.path.join(out, "*.js"))
if len(chunks) != 1:
    sys.exit(f"expected one bundle chunk, got {chunks}")
js = open(chunks[0], encoding="utf-8").read()


dest = os.path.join(out, "editor.bundle.js")
os.replace(chunks[0], dest)
print(f"bundled editor: {len(js)} bytes -> {dest}")
