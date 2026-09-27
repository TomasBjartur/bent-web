// Common prefix and suffix of two strings: the edit between two versions
// of the text, found on every keystroke (editor.js, vim.js). A document may
// be megabytes, so equal stretches are compared 4 KB at a time with the
// engine's native string comparison (slices share the string's memory),
// then unit by unit near the change: ~10x faster than units alone.

const CHUNK = 4096;

// Length of the common prefix of a and b, in UTF-16 units.
export function prefix(a, b) {
  const n = Math.min(a.length, b.length);
  let p = 0;
  while (p + CHUNK <= n && a.slice(p, p + CHUNK) === b.slice(p, p + CHUNK)) p += CHUNK;
  while (p < n && a.charCodeAt(p) === b.charCodeAt(p)) p++;
  return p;
}

// Length of the common suffix, not reaching into the first p units of
// either string (p: the common prefix).
export function suffix(a, b, p) {
  const n = Math.min(a.length, b.length) - p;
  let s = 0;
  while (s + CHUNK <= n && a.slice(a.length - s - CHUNK, a.length - s) === b.slice(b.length - s - CHUNK, b.length - s)) s += CHUNK;
  while (s < n && a.charCodeAt(a.length - 1 - s) === b.charCodeAt(b.length - 1 - s)) s++;
  return s;
}
