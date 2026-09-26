#!/usr/bin/env python3
"""Reorder a Bend file's top-level defs so every def comes after the defs it
calls (Bend requires this). Types, imports and the leading comment stay on
top. Comments directly above a def move with it. Reports cycles (mutual
recursion, which Bend forbids) instead of reordering them.

usage: tools/bend_order.py file.bend [--check]
"""
import re, sys

def blocks(text):
    lines = text.split('\n')
    out, cur, pending = [], None, []
    header = []
    i = 0
    # header: everything before the first def/type/law, minus trailing comments
    starts = [k for k, l in enumerate(lines) if re.match(r'(def|type|law) ', l) or l.startswith('@unsafe')]
    first = starts[0] if starts else len(lines)
    head = lines[:first]
    # comments immediately above the first block belong to it
    j = len(head)
    while j > 0 and head[j-1].startswith('#'):
        j -= 1
    header, lead = head[:j], head[j:]
    body = lead + lines[first:]
    chunks, cur = [], []
    for l in body:
        is_start = re.match(r'(def|type|law) ', l) or l.startswith('@unsafe')
        if is_start and cur and not all(x.startswith('#') or x.startswith('@') for x in cur if x.strip()):
            # split trailing comment lines of cur into the next chunk
            k = len(cur)
            while k > 0 and (cur[k-1].startswith('#') or cur[k-1].startswith('@') or not cur[k-1].strip()):
                k -= 1
            carry = [x for x in cur[k:] if x.strip()]
            chunks.append(cur[:k])
            cur = carry + [l]
        else:
            cur.append(l)
    if cur:
        chunks.append(cur)
    return header, chunks

def name_of(chunk):
    for l in chunk:
        m = re.match(r'(?:def|type|law) ([A-Za-z0-9_.?]+)', l)
        if m:
            return m.group(1).rstrip('?'), l.startswith('type')
    return None, False

def main():
    path = sys.argv[1]
    text = open(path).read()
    header, chunks = blocks(text)
    names = [name_of(c) for c in chunks]
    defs = {n: i for i, (n, t) in enumerate(names) if n and not t}
    deps = {}
    for i, c in enumerate(chunks):
        n, is_type = names[i]
        body = '\n'.join(x for x in c if not x.lstrip().startswith('#'))
        body = re.sub(r'"(\\.|[^"\\])*"', '""', body)
        ds = set()
        for m in re.finditer(r'(?<![A-Za-z0-9_.])([A-Za-z_][A-Za-z0-9_.]*)', body):
            w = m.group(1)
            if w in defs and w != n:
                ds.add(defs[w])
        deps[i] = ds
    order, state, cycles = [], {}, []
    def visit(i, stack):
        if state.get(i) == 2:
            return
        if state.get(i) == 1:
            cycles.append([names[k][0] for k in stack[stack.index(i):]] + [names[i][0]])
            return
        state[i] = 1
        for d in sorted(deps[i]):
            visit(d, stack + [i])
        state[i] = 2
        order.append(i)
    types = [i for i, (n, t) in enumerate(names) if t]
    for i in types:
        state[i] = 2
    for i in range(len(chunks)):
        if i not in types:
            visit(i, [])
    if cycles:
        for c in cycles:
            print('cycle (mutual recursion):', ' -> '.join(c), file=sys.stderr)
        sys.exit(1)
    # keep types in place relative to each other, first
    new = [chunks[i] for i in types] + [chunks[i] for i in order]
    def strip(c):
        while c and not c[-1].strip():
            c = c[:-1]
        return c
    out = '\n'.join(header) + ('\n' if header else '') + '\n\n'.join('\n'.join(strip(c)) for c in new)
    out = re.sub(r'\n{3,}', '\n\n', out).rstrip('\n') + '\n'
    if '--check' in sys.argv:
        sys.exit(0 if out == text else 2)
    open(path, 'w').write(out)

main()
