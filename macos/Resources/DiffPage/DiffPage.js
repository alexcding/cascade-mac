// This surface only renders the snapshot supplied by its native owner. It has no file I/O
// or HTTP access (CSP connect-src 'none'); native controls own loading and mutations, and
// the page reports intent back through one message handler: ready, open, discard.
import { parseDiff, diffPath, hunkBlocks } from './DiffParse.mjs';
import { highlightLine, langForPath } from './DiffHighlight.mjs';

// Render guards: a huge diff (lockfile churn, generated code) must not freeze the pane.
const MAX_FILES = 100;
const MAX_FILE_LINES = 2000;
const MAX_TOTAL_LINES = 6000;
const MAX_UNTRACKED = 200;
const CODE_FONT_FALLBACK = '"SF Mono", Menlo, Monaco, monospace';
const CHEVRON = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 6l6 6-6 6"/></svg>';

const esc = s => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
const msg = text => `<div class="diff-empty">${text}</div>`;
const post = body => window.webkit?.messageHandlers.diff?.postMessage(body);

function renderFile(f, fi, allow, discardable, fileLinks) {
  const canOpen = fileLinks && f.status !== 'deleted' && !f.binary && f.newPath;
  const open = (label, line, aria) => `<button class="diff-open-file" data-open-path="${esc(f.newPath)}" data-open-line="${line}" aria-label="${esc(aria)}">${label}</button>`;
  const badge = { added: 'A', deleted: 'D', renamed: 'R' }[f.status] || '';
  const counts = `<span class="diff-counts">${f.adds ? `<span class="dc-add">+${f.adds}</span>` : ''}${f.dels ? `<span class="dc-del">−${f.dels}</span>` : ''}</span>`;
  const head = `<div class="diff-file-head"><span class="diff-chev">${CHEVRON}</span>` +
    (badge ? `<span class="diff-badge diff-badge-${f.status}">${badge}</span>` : '') +
    `<span class="diff-fpath">${esc(diffPath(f))}</span>${counts}${canOpen ? open('Open File', 1, `Open ${f.newPath}`) : ''}</div>`;

  let body;
  const total = f.hunks.reduce((n, h) => n + h.lines.length, 0);
  if (f.binary)                      body = `<div class="diff-stub">Binary file</div>`;
  else if (!total)                   body = ''; // pure rename / mode change — header says it all
  else if (total > MAX_FILE_LINES || !allow)
    body = `<div class="diff-stub">Large diff (+${f.adds} −${f.dels}) — not rendered. Use the terminal: <code>git diff ${esc(f.newPath || f.oldPath)}</code></div>`;
  else {
    // Rows are grouped into one <tbody> per change BLOCK (contiguous +/− run) with the
    // context runs in plain tbodys between them. Hovering anywhere in a block reveals
    // its Discard button (pure CSS, tbody:hover) on the block's first row.
    const lang = langForPath(diffPath(f));
    const row = l => {
      const cls = l.t === '+' ? 'add' : l.t === '-' ? 'del' : 'ctx';
      return `<tr class="diff-line ${cls}"><td class="dg">${l.oldNo || ''}</td><td class="dg">${canOpen && l.newNo ? open(l.newNo, l.newNo, `Open ${f.newPath} at line ${l.newNo}`) : l.newNo || ''}</td>` +
             `<td class="dx"><span class="dm">${l.t === ' ' ? '&nbsp;' : l.t}</span>${highlightLine(l.text, lang)}</td></tr>`;
    };
    const groups = f.hunks.map((h, hi) => {
      const ids = hunkBlocks(h);
      const segs = [];
      h.lines.forEach((l, i) => {
        const last = segs[segs.length - 1];
        if (!last || last.id !== ids[i]) segs.push({ id: ids[i], lines: [] });
        segs[segs.length - 1].lines.push(l);
      });
      return `<tbody><tr class="diff-hunk"><td class="dg" colspan="2"></td><td class="dx">${esc(h.header)}</td></tr></tbody>` +
        segs.map(s => {
          const rows = s.lines.map(row);
          if (!discardable || s.id === null) return `<tbody>${rows.join('')}</tbody>`;
          rows[0] = rows[0].replace('</td></tr>',
            `<button class="hunk-discard" data-f="${fi}" data-h="${hi}" data-b="${s.id}" title="Revert this block in the file">Discard</button></td></tr>`);
          return `<tbody class="diff-block">${rows.join('')}</tbody>`;
        }).join('');
    });
    body = `<table class="diff-table">${groups.join('')}</table>`;
  }
  // .diff-body owns the rounded-corner clipping so the sticky header above it works.
  return `<div class="diff-file">${head}${body ? `<div class="diff-body">${body}</div>` : ''}</div>`;
}

function renderUntracked(untracked, fileLinks) {
  const visible = untracked.slice(0, MAX_UNTRACKED);
  const remainder = untracked.length - visible.length;
  const entry = path => fileLinks
    ? `<button class="diff-open-file" data-open-path="${esc(path)}" data-open-line="1">${esc(path)}</button>` : esc(path);
  return `<div class="diff-file"><div class="diff-file-head diff-untracked-head">Untracked files</div><div class="diff-body">` +
    visible.map(path => `<div class="diff-untracked">${entry(path)}</div>`).join('') +
    (remainder ? `<div class="diff-stub">… and ${remainder} more untracked files</div>` : '') + `</div></div>`;
}

function render(files, untracked, discardable, fileLinks) {
  if (!files.length && !untracked.length) return msg(discardable ? 'No uncommitted changes' : 'No changes (empty or merge commit).');
  const parts = [];
  // Per-file cap alone still allows 100 × 2000 rows in one innerHTML parse; a whole-pane
  // budget keeps the worst case bounded — files past it render as header-only stubs.
  let budget = MAX_TOTAL_LINES;
  files.slice(0, MAX_FILES).forEach((f, i) => {
    parts.push(renderFile(f, i, budget > 0, discardable, fileLinks));
    budget -= f.hunks.reduce((n, h) => n + h.lines.length, 0);
  });
  if (files.length > MAX_FILES) parts.push(msg(`… and ${files.length - MAX_FILES} more files — diff truncated`));
  if (untracked.length) parts.push(renderUntracked(untracked, fileLinks));
  return `<div class="diff-root">${parts.join('')}</div>`;
}

const pane = document.getElementById('native-diff');
let previous = null;
let renderedRevision = null;
let currentTheme = 'system';

pane.addEventListener('click', event => {
  const discard = event.target.closest('.hunk-discard');
  if (discard) {
    post({ type: 'discard', selection: [discard.dataset.f, discard.dataset.h, discard.dataset.b].map(Number), revision: renderedRevision });
    return;
  }
  const button = event.target.closest('[data-open-path]');
  if (button) {
    const line = Number(button.dataset.openLine);
    if (Number.isSafeInteger(line) && line > 0 && line <= 1_000_000) post({ type: 'open', path: button.dataset.openPath, line });
    return;
  }
  const head = event.target.closest('.diff-file-head');
  if (head && !head.classList.contains('diff-untracked-head')) head.parentElement.classList.toggle('collapsed');
});

// Hover frame: one overlay div moved over whichever block is hovered. Drawn outside
// the table because cell-painted borders get sliced at row seams (see CSS comment).
const frame = document.createElement('div');
frame.className = 'diff-frame';
let framed = null;
const clearFrame = () => { framed = null; frame.style.display = 'none'; };
pane.addEventListener('mouseover', event => {
  const block = event.target.closest('tbody.diff-block');
  if (block === framed) return;
  framed = block;
  const root = pane.querySelector('.diff-root');
  if (!block || !root) { frame.style.display = 'none'; return; }
  root.appendChild(frame); // re-parent into the current render (innerHTML resets drop it)
  const r = block.getBoundingClientRect(), o = root.getBoundingClientRect();
  frame.style.top = (r.top - o.top - 1) + 'px';
  frame.style.left = (r.left - o.left - 1) + 'px';
  frame.style.width = (r.width + 1) + 'px';
  frame.style.height = (r.height + 1) + 'px';
  frame.style.display = 'block';
});
pane.addEventListener('mouseleave', clearFrame);

matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => window.nativeDiff.setTheme(currentTheme));

window.nativeDiff = {
  render(snapshot) {
    const key = JSON.stringify(snapshot);
    if (key === previous) return true;
    // Collapsed files and scroll position survive a refresh of the working changes: the pane is
    // rebuilt wholesale. A snapshot with no revision is a commit's patch, and a different commit
    // starts from the top with everything open.
    const keep = Boolean(snapshot.revision) && Boolean(renderedRevision);
    const collapsed = new Set(keep ? [...pane.querySelectorAll('.diff-file.collapsed .diff-fpath')].map(el => el.textContent) : []);
    const scroll = keep ? pane.scrollTop : 0;
    clearFrame();
    pane.innerHTML = render(parseDiff(snapshot.diff), snapshot.untracked || [], Boolean(snapshot.revision), snapshot.fileLinks !== false);
    if (collapsed.size) pane.querySelectorAll('.diff-fpath').forEach(el => {
      if (collapsed.has(el.textContent)) el.closest('.diff-file').classList.add('collapsed');
    });
    pane.scrollTop = scroll;
    renderedRevision = snapshot.revision || null;
    previous = key;
    return true;
  },
  setTheme(theme) {
    currentTheme = theme;
    document.documentElement.dataset.theme = theme === 'system'
      ? (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light') : theme;
  },
  setFont({ family, size }) {
    if (typeof family !== 'string' || family.length > 256 || /[\x00-\x1f\x7f"\\]/.test(family) || !Number.isInteger(size) || size < 9 || size > 24) return;
    document.documentElement.style.setProperty('--diff-font', family ? `"${family}", ${CODE_FONT_FALLBACK}` : CODE_FONT_FALLBACK);
    document.documentElement.style.setProperty('--diff-font-size', `${size}px`);
  },
};
post({ type: 'ready' });
