#!/usr/bin/env python3
"""Prints unsent emails from the outbox (no mail sender exists yet).
usage: tools/outbox.py [db]   (default ~/bent-data/blog.db)"""
import os, sqlite3, sys
db = sqlite3.connect(sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/bent-data/blog.db"))
for i, to, subj, body, t in db.execute("SELECT id, to_email, subject, body, created_ms FROM outbox WHERE sent_ms IS NULL ORDER BY id DESC LIMIT 20"):
    print(f"--- #{i} to {to}: {subj}\n{body}")
