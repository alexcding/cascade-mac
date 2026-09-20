// Minimal, dependency-free syntax highlighter for the .diff-table renderer (diff.js), so the
// Changes / History / Git-tab diffs get token colour without re-adding the ~1 MB diff2html bundle.
// It tokenizes ONE line at a time — diffs aren't contiguous source, so multi-line constructs
// (block comments, template strings spanning lines) are approximate — into <span class="tok-*">
// spans coloured by the --tok-* theme tokens (tokens.css). Pure + DOM-free, like diff-parse.mjs,
// so node:test can exercise it directly.
// .mjs (not .js): the package is type:commonjs; the extension lets node:test import it while the
// browser loads it like any other module.

const esc = s => String(s).replace(/[&<>]/g, c => (c === '&' ? '&amp;' : c === '<' ? '&lt;' : '&gt;'));
const set = s => new Set(s.split(/\s+/).filter(Boolean));

// Keyword sets (literals like true/false/null folded in — they read as keywords).
const JS = set(`await break case catch class const continue debugger default delete do else export
  extends finally for from function get if implements import in instanceof interface let new of
  return set static super switch this throw try typeof var void while with yield async as enum
  public private protected readonly type namespace declare true false null undefined NaN Infinity`);
const PY = set(`and as assert async await break class continue def del elif else except finally for
  from global if import in is lambda nonlocal not or pass raise return try while with yield True
  False None self cls match case`);
const GO = set(`break case chan const continue default defer else fallthrough for func go goto if
  import interface map package range return select struct switch type var nil true false iota`);
const RUST = set(`as async await break const continue crate dyn else enum extern fn for if impl in
  let loop match mod move mut pub ref return self Self static struct super trait type unsafe use
  where while true false`);
const CLIKE = set(`auto bool break case catch char class const constexpr continue default delete do
  double else enum extern final float for friend goto if inline int long namespace new nullptr
  operator private protected public register return short signed sizeof static struct switch
  template this throw try typedef typename union unsigned using virtual void volatile while true
  false null var val fun when object companion data sealed override import package`);
const SH = set(`if then else elif fi for while until do done case esac function in return export
  local readonly declare echo set unset shift source alias true false`);
const RUBY = set(`def end class module if elsif else unless while until for in do return yield then
  begin rescue ensure raise require require_relative attr_accessor attr_reader attr_writer self nil
  true false and or not super case when next break`);

// Language descriptors: comment style + keyword set. `line` = line-comment token; `hash` = '#'
// comments; `block` = /* */ ; `tmpl` = backtick strings.
const LANGS = {
  js:   { line: '//', block: true, tmpl: true, kw: JS },
  py:   { hash: true, kw: PY },
  go:   { line: '//', block: true, kw: GO },
  rust: { line: '//', block: true, kw: RUST },
  c:    { line: '//', block: true, kw: CLIKE },
  sh:   { hash: true, kw: SH },
  ruby: { hash: true, kw: RUBY },
  json: { kw: set('true false null') },
};

// File extension → language key. Unknown extensions return '' (no highlighting → plain text).
const EXT = {
  js: 'js', jsx: 'js', mjs: 'js', cjs: 'js', ts: 'js', tsx: 'js', mts: 'js', cts: 'js',
  py: 'py', pyi: 'py',
  go: 'go',
  rs: 'rust',
  c: 'c', h: 'c', cc: 'c', cpp: 'c', cxx: 'c', hpp: 'c', hxx: 'c', cs: 'c',
  java: 'c', kt: 'c', kts: 'c', swift: 'c', scala: 'c',
  sh: 'sh', bash: 'sh', zsh: 'sh', fish: 'sh',
  rb: 'ruby',
  json: 'json',
};

export function langForPath(path) {
  const m = /\.([A-Za-z0-9]+)$/.exec(String(path || ''));
  return (m && EXT[m[1].toLowerCase()]) || '';
}

const ID = /[A-Za-z0-9_$]/;
const IDSTART = /[A-Za-z_$]/;
const span = (cls, raw) => `<span class="tok-${cls}">${esc(raw)}</span>`;

// Highlight one line of code for `lang` (a key from LANGS, or '' for none). Returns HTML-escaped
// text with token spans. Strings/comments take precedence over keywords so `//` inside a string
// isn't read as a comment; an unterminated string/block-comment colours to end of line.
export function highlightLine(text, lang) {
  const L = lang && LANGS[lang];
  if (!L || !text) return esc(text);
  let out = '', i = 0;
  const n = text.length;
  while (i < n) {
    const ch = text[i];
    if (L.line && text.startsWith(L.line, i)) { out += span('com', text.slice(i)); break; }
    if (L.hash && ch === '#') { out += span('com', text.slice(i)); break; }
    if (L.block && ch === '/' && text[i + 1] === '*') {
      const end = text.indexOf('*/', i + 2);
      const stop = end === -1 ? n : end + 2;
      out += span('com', text.slice(i, stop)); i = stop; continue;
    }
    if (ch === '"' || ch === "'" || (L.tmpl && ch === '`')) {
      let j = i + 1;
      while (j < n) { if (text[j] === '\\') { j += 2; continue; } if (text[j] === ch) { j++; break; } j++; }
      out += span('str', text.slice(i, j)); i = j; continue;
    }
    if (ch >= '0' && ch <= '9' && !(i > 0 && ID.test(text[i - 1]))) {
      let j = i + 1;
      while (j < n && /[0-9a-fA-FxXob._]/.test(text[j])) j++;
      out += span('num', text.slice(i, j)); i = j; continue;
    }
    if (IDSTART.test(ch)) {
      let j = i + 1;
      while (j < n && ID.test(text[j])) j++;
      const word = text.slice(i, j);
      let k = j; while (k < n && text[k] === ' ') k++;
      if (L.kw.has(word)) out += span('kw', word);
      else if (text[k] === '(') out += span('fn', word);
      else out += esc(word);
      i = j; continue;
    }
    out += esc(ch); i++;
  }
  return out;
}
