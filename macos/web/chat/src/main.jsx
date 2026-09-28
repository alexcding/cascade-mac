// The chat page. Push-only: Swift calls `window.nativeChat.render(state)` with the session's turns
// and the page draws them. It has no network access and reports back through one message
// handler — `ready`, `copy`, `open` and `download` — so it can never reach the backend itself.
import { memo, useLayoutEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { Streamdown } from "streamdown";
import { code } from "./highlight.js";

let localization = { strings: {}, locale: undefined, language: "en" };
const t = (key, ...values) => {
  let index = 0;
  return (localization.strings[key] ?? key).replace(/%(?:(\d+)\$)?@/g,
    (_, position) => String(values[position ? Number(position) - 1 : index++] ?? ""));
};

const post = (message) => window.webkit?.messageHandlers?.chat?.postMessage(message);

// The page is not a secure context, so WebKit gives it no clipboard; copying goes through Swift.
Object.defineProperty(navigator, "clipboard", {
  configurable: true,
  value: { writeText: (text) => { post({ type: "copy", text: String(text) }); return Promise.resolve(); } },
});

// Downloads (a table's CSV, a code block) click a `blob:` link and revoke it at once, so the page
// keeps each blob it mints and hands its bytes to Swift, which saves them to Downloads.
const blobs = new Map();
const createObjectURL = URL.createObjectURL.bind(URL);
URL.createObjectURL = (blob) => { const url = createObjectURL(blob); blobs.set(url, blob); return url; };
const download = (name, blob) => {
  const reader = new FileReader();
  reader.onload = () => post({ type: "download", name, data: String(reader.result).split(",", 2)[1] ?? "" });
  reader.readAsDataURL(blob);
};

// Links leave through Swift, which opens web addresses in the session's browser; the page never navigates.
document.addEventListener("click", (event) => {
  const link = event.target.closest?.("a[href]");
  if (!link) return;
  event.preventDefault();
  const blob = link.hasAttribute("download") ? blobs.get(link.href) : undefined;
  if (blob) { blobs.delete(link.href); download(link.getAttribute("download") || "download", blob); return; }
  post({ type: "open", url: link.href });
}, true);

const markdownTranslations = () => ({
  close: t("Close"),
  copied: t("Copied"),
  copyCode: t("Copy Code"),
  copyLink: t("Copy Link"),
  copyTable: t("Copy Table"),
  downloadDiagram: t("Download Diagram"),
  downloadFile: t("Download File"),
  downloadImage: t("Download Image"),
  downloadTable: t("Download Table"),
  exitFullscreen: t("Exit Full Screen"),
  externalLinkWarning: t("You are about to open an external link."),
  imageNotAvailable: t("Image unavailable"),
  openExternalLink: t("Open External Link"),
  openLink: t("Open Link"),
  resetView: t("Reset View"),
  viewFullscreen: t("View Full Screen"),
  zoomIn: t("Zoom In"),
  zoomOut: t("Zoom Out"),
  copyTableAsCsv: t("Copy as %@", "CSV"),
  copyTableAsMarkdown: t("Copy as %@", "Markdown"),
  copyTableAsTsv: t("Copy as %@", "TSV"),
  downloadDiagramAsMmd: t("Download as %@", "MMD"),
  downloadDiagramAsPng: t("Download as %@", "PNG"),
  downloadDiagramAsSvg: t("Download as %@", "SVG"),
  downloadTableAsCsv: t("Download as %@", "CSV"),
  downloadTableAsMarkdown: t("Download as %@", "Markdown"),
  mermaidFormatMmd: "MMD",
  mermaidFormatPng: "PNG",
  mermaidFormatSvg: "SVG",
  tableFormatCsv: "CSV",
  tableFormatMarkdown: "Markdown",
  tableFormatTsv: "TSV",
});

function Markdown({ text }) {
  return (
    <Streamdown translations={markdownTranslations()} mode="static" className="answer" plugins={{ code }}
      shikiTheme={["github-light", "github-dark"]} linkSafety={{ enabled: false }} tableMaxHeight={0}>
      {text}
    </Streamdown>
  );
}

const time = (iso) => iso ? new Date(iso).toLocaleString(localization.locale, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }) : "";

function dateLine(iso) {
  const date = new Date(iso);
  const day = date.toLocaleDateString(localization.locale, { weekday: "short", month: "short", day: "numeric" });
  const clock = date.toLocaleTimeString(localization.locale, { hour: "numeric", minute: "2-digit" });
  return t("%@ at %@", day, clock);
}

function duration(seconds) {
  const total = Math.round(seconds);
  const unit = (value, unit) => new Intl.NumberFormat(localization.locale,
    { style: "unit", unit, unitDisplay: "narrow" }).format(value);
  if (total < 60) return unit(total, "second");
  if (total < 3600) return unit(Math.floor(total / 60), "minute") + " " + unit(total % 60, "second");
  return unit(Math.floor(total / 3600), "hour") + " " + unit(Math.floor((total % 3600) / 60), "minute");
}

const CopyIcon = () => (
  <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.3"><rect x="5" y="5" width="8.5" height="8.5" rx="2"/><path d="M11 5V4a1.5 1.5 0 0 0-1.5-1.5h-5A1.5 1.5 0 0 0 3 4v5a1.5 1.5 0 0 0 1.5 1.5H5"/></svg>
);
const CheckIcon = () => (
  <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M3.5 8.5l3 3 6-7"/></svg>
);
const DownIcon = () => (
  <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.1" strokeLinecap="round" strokeLinejoin="round"><path d="M8 2.5v11M3.5 9 8 13.5 12.5 9"/></svg>
);

function Actions({ text, at }) {
  const [copied, setCopied] = useState(false);
  return (
    <div className={`actions${copied ? " copied" : ""}`}>
      <button title={t("Copy")} aria-label={t("Copy")} onClick={() => {
        post({ type: "copy", text });
        setCopied(true);
        setTimeout(() => setCopied(false), 1200);
      }}>{copied ? <CheckIcon /> : <CopyIcon />}</button>
      {at && <span>{time(at)}</span>}
    </div>
  );
}

// A line diff by longest common subsequence, so a file edit reads like a real diff.
function diff(oldText, newText) {
  const a = oldText ? oldText.split("\n") : [];
  const b = newText.split("\n");
  if (!a.length) return b.map((text) => ({ kind: "add", text }));
  const n = a.length, m = b.length;
  if (n * m > 2_000_000) return [...a.map((text) => ({ kind: "remove", text })), ...b.map((text) => ({ kind: "add", text }))];
  const table = Array.from({ length: n + 1 }, () => new Int32Array(m + 1));
  for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--)
    table[i][j] = a[i] === b[j] ? table[i + 1][j + 1] + 1 : Math.max(table[i + 1][j], table[i][j + 1]);
  const lines = [];
  let i = 0, j = 0;
  while (i < n && j < m) {
    if (a[i] === b[j]) { lines.push({ kind: "same", text: a[i] }); i++; j++; }
    else if (table[i + 1][j] >= table[i][j + 1]) lines.push({ kind: "remove", text: a[i++] });
    else lines.push({ kind: "add", text: b[j++] });
  }
  while (i < n) lines.push({ kind: "remove", text: a[i++] });
  while (j < m) lines.push({ kind: "add", text: b[j++] });
  return lines;
}

// A tool by what it does, not by its name: the backend gives each call a `kind` every CLI shares,
// so nothing here knows one CLI from another. A kind not listed shows the tool's own name.
const DONE = {
  run: "Ran", read: "Read", edit: "Edited", patch: "Edited", create: "Created", search: "Searched",
  fetch: "Fetched", web: "Searched the web", delegate: "Delegated", plan: "Updated plan",
};
const DOING = {
  run: "Running", read: "Reading", edit: "Editing", patch: "Editing", create: "Creating", search: "Searching",
  fetch: "Fetching", web: "Searching the web", delegate: "Delegating", plan: "Updating plan",
};
const ASKS = {
  run: "Run this command?", edit: "Edit this file?", patch: "Apply this patch?", create: "Create this file?",
  fetch: "Fetch this page?", web: "Search the web?",
};

// What the agent is doing while it works: thinking, or the call it is waiting on and what that
// runs or touches, with a band of light sweeping the words.
function Activity({ activity }) {
  const doing = DOING[activity?.kind];
  if (!doing) return <span className="shimmer">{t(activity?.kind === "thinking" ? "Thinking" : "Working")}</span>;
  return (
    <>
      <span className="shimmer">{t(doing)}</span>
      {activity.detail && <span className="activity-detail">{activity.detail}</span>}
    </>
  );
}

function Tool({ tool }) {
  const name = tool.name || t("Tool");
  const isEdit = tool.path != null && tool.new != null;
  const lines = isEdit ? diff(tool.old || "", tool.new) : null;
  const badge = isEdit && tool.kind !== "create"
    ? `+${lines.filter((l) => l.kind === "add").length} −${lines.filter((l) => l.kind === "remove").length}` : null;
  const output = tool.output || "";
  const command = !isEdit && tool.command ? tool.command : "";
  const expandable = isEdit || output || command;
  const header = (
    <>
      <span className="verb">{DONE[tool.kind] ? t(DONE[tool.kind]) : name}</span>
      {tool.summary && <span className="summary">{tool.summary}</span>}
      {badge && <span className="badge">{badge}</span>}
      {tool.isError && <span className="error">{t("Failed")}</span>}
      {expandable && <span className="chev">›</span>}
    </>
  );
  if (!expandable) return <div className="tool"><summary>{header}</summary></div>;
  return (
    <details className="tool">
      <summary>{header}</summary>
      <div className="body">
        {command && <div><div className="block-label">{t("Command")}</div><pre className="mono">{command}</pre></div>}
        {isEdit && (
          <div className="diff">
            {lines.slice(0, 400).map((line, index) => (
              <div key={index} className={line.kind}>{(line.kind === "add" ? "+ " : line.kind === "remove" ? "− " : "  ") + line.text}</div>
            ))}
          </div>
        )}
        {output && <div><div className="block-label">{t(tool.isError ? "Error" : "Output")}</div><pre className="mono">{output}</pre></div>}
      </div>
    </details>
  );
}

function Worked({ blocks, label, working, activity }) {
  return (
    <details className="worked" open={working}>
      <summary>{working ? <Activity activity={activity} /> : <span>{label}</span>} <span className="chev">›</span></summary>
      <div className="steps">
        {blocks.map((block, index) => {
          if (block.type === "tool") return <Tool key={index} tool={block} />;
          if (block.type === "thinking") return (
            <details key={index} className="thought">
              <summary>{t("Thought")} ›</summary>
              <div className="body"><Markdown text={block.text || ""} /></div>
            </details>
          );
          return <div key={index} className="commentary"><Markdown text={block.text || ""} /></div>;
        })}
      </div>
    </details>
  );
}

// Memoised on the turn's content: a poll re-renders only the turn that changed, usually the last.
const Turn = memo(function Turn({ turn, working, activity }) {
  if (turn.role === "user") {
    const text = turn.blocks.filter((b) => b.type === "text").map((b) => b.text).join("\n\n");
    return (
      <div className="turn prompt">
        <div className="pill">{text}</div>
        <Actions text={text} at={turn.timestamp} />
      </div>
    );
  }
  // Everything up to the last tool call or thought is work; the text after it is the answer.
  let last = -1;
  turn.blocks.forEach((block, index) => { if (block.type !== "text") last = index; });
  const work = turn.blocks.slice(0, last + 1);
  const answer = turn.blocks.slice(last + 1).map((b) => b.text).filter(Boolean).join("\n\n");
  let label = t("Worked");
  if (working) label = t("Working");
  else if (turn.timestamp && turn.ended) {
    const seconds = (new Date(turn.ended) - new Date(turn.timestamp)) / 1000;
    if (seconds > 0) label = t("Worked for %@", duration(seconds));
  }
  return (
    <div className="turn">
      {(work.length > 0 || working) && <Worked blocks={work} label={label} working={working} activity={activity} />}
      {answer && <Markdown text={answer} />}
      {answer && !working && <Actions text={answer} at={turn.ended || turn.timestamp} />}
    </div>
  );
}, (before, after) => before.working === after.working && JSON.stringify(before.turn) === JSON.stringify(after.turn)
  && (!after.working || JSON.stringify(before.activity) === JSON.stringify(after.activity)));

// The agent is stopped on this until it is answered; the terminal shows nothing meanwhile. What
// is allowed is shown whole: a file change as its diff, and a request too long for the card goes
// to the terminal's own prompt instead of being allowed half-read.
function Permission({ permission }) {
  const [sent, setSent] = useState(false);
  const answer = (decision) => {
    setSent(true);
    post({ type: "permission", id: permission.id, decision });
  };
  const change = permission.new != null ? diff(permission.old || "", permission.new) : null;
  return (
    <div className="turn permission">
      <div className="ask">{ASKS[permission.kind] ? t(ASKS[permission.kind]) : t("Allow %@?", permission.tool)}</div>
      {permission.reason && <div className="reason">{permission.reason}</div>}
      {permission.detail && <pre className="mono">{permission.detail}</pre>}
      {change && (
        <div className="diff">
          {change.map((line, index) => (
            <div key={index} className={line.kind}>{(line.kind === "add" ? "+ " : line.kind === "remove" ? "− " : "  ") + line.text}</div>
          ))}
        </div>
      )}
      {permission.truncated && <div className="reason">{t("Too long to show here in full. Review it in the terminal.")}</div>}
      <div className="choices">
        {permission.truncated
          ? <button className="allow" disabled={sent} onClick={() => answer("pass")}>{t("Review in Terminal")}</button>
          : <button className="allow" disabled={sent} onClick={() => answer("allow")}>{t("Allow")}</button>}
        <button disabled={sent} onClick={() => answer("deny")}>{t("Deny")}</button>
      </div>
    </div>
  );
}

const SEPARATOR_GAP = 30 * 60 * 1000;

function separator(turns, index) {
  const turn = turns[index];
  if (turn.role !== "user" || !turn.timestamp) return null;
  return opens(turns[index - 1], turn.timestamp) ? turn.timestamp : null;
}

// A prompt at `at` opens the page, or comes a long while after what was before it.
function opens(previous, at) {
  const before = previous && (previous.ended || previous.timestamp);
  return !before || new Date(at) - new Date(before) > SEPARATOR_GAP;
}

// Glides the page to where `target()` says, easing out, as a chat app does; WebKit's own `smooth`
// scrolling is not on in every web view. The target is asked again on every frame, so the glide
// lands where the page ends up if it changes on the way. A new glide, or the reader's own
// scrolling, stops the one under way.
let glide = 0;
let gliding = false;
function glideTo(target) {
  cancelAnimationFrame(glide);
  const from = window.scrollY;
  const distance = target() - from;
  if (Math.abs(distance) < 1 || matchMedia("(prefers-reduced-motion: reduce)").matches) {
    gliding = false;
    window.scrollTo(0, target());
    return;
  }
  const duration = Math.min(480, 220 + Math.abs(distance) / 5);
  const start = performance.now();
  gliding = true;
  const step = (now) => {
    const progress = Math.min(1, (now - start) / duration);
    window.scrollTo(0, from + (target() - from) * (1 - Math.pow(1 - progress, 3)));
    if (progress < 1) glide = requestAnimationFrame(step);
    else gliding = false;
  };
  glide = requestAnimationFrame(step);
}
const stopGlide = () => { cancelAnimationFrame(glide); gliding = false; };

// A prompt sent while the latest is within this of the view's bottom edge is placed, with room
// for its reply; sent from further up, the reader is left where they are. The Codex app's rule.
const NEAR_LATEST = 300;
// Keeps a card clear of the window's edge when it is brought into view.
const EDGE = 16;

function Chat({ state }) {
  const { turns, busy, pending, queued, loaded, permission, activity } = state;
  // How the view moves as the conversation changes, after the Codex app's thread.
  // `watch`: a prompt was just placed, its reply's room below it, and the view holds still until
  //   the agent's work runs past the bottom edge; from then it follows.
  // `follow`: the view keeps to the bottom as the latest comes in.
  // `static`: what the reader sees stays where it is.
  // Each holds against anything that changes height above what is shown: turns falling off the
  // front of the transcript's window, or an earlier answer's code finishing late.
  const mode = useRef("static");
  // Outside `follow`, the turns in view and how far each sat from the top. The first still on the
  // page is held: the transcript's window drops its oldest turns as it moves.
  const held = useRef([]);
  // The latest was within NEAR_LATEST of the bottom edge, as the view last stood.
  const near = useRef(true);
  const working = useRef(busy);
  working.current = busy;
  const shown = useRef(false);
  const placed = useRef(null);
  // The prompt whose reply was given room when it was placed.
  const room = useRef(null);
  // The next scroll is the reader's: a wheel, a key or the scroller, not one of the page's own.
  const reader = useRef(false);
  const column = useRef(null);
  const end = useRef(null);
  const card = useRef(null);
  // Scrolled up, a button over the bottom edge goes back down to the latest.
  const [away, setAway] = useState(false);

  // The newest prompt: the one sent and not in the transcript yet, or the transcript's last.
  let start = turns.length;
  if (!pending) {
    for (let index = turns.length - 1; index >= 0; index--) {
      if (turns[index].role === "user") { start = index; break; }
    }
  }
  const prompt = pending ? null : turns[start];
  const key = pending ? `pending:${pending}` : prompt?.id ?? null;
  // Placed, its reply gets room below it: two thirds of the view, never so much that less than
  // 240px of what came before shows above it.
  const placing = shown.current && key !== null && key !== placed.current && near.current;
  const roomy = key !== null && (placing || key === room.current);

  const scroll = (target, smooth) => {
    reader.current = false;
    if (smooth) glideTo(target);
    else { stopGlide(); window.scrollTo(0, target()); }
  };
  const bottom = () => document.documentElement.scrollHeight - document.documentElement.clientHeight;
  const moveBy = (distance) => { if (Math.abs(distance) >= 1) scroll(() => window.scrollY + distance, false); };
  // How far the end of the latest reply lies below the bottom edge.
  const latestBelow = () => (end.current ? end.current.getBoundingClientRect().top - window.innerHeight : 0);
  const hold = () => {
    held.current = [...document.querySelectorAll("[data-turn]")]
      .map((turn) => ({ id: turn.dataset.turn, box: turn.getBoundingClientRect() }))
      .filter(({ box }) => box.bottom > 0 && box.top < window.innerHeight)
      .map(({ id, box }) => ({ id, offset: box.top }));
  };
  // Puts the view back where its mode keeps it, after the page changed under it.
  const settle = () => {
    if (gliding) return;
    if (mode.current === "watch" && working.current && latestBelow() > 0) mode.current = "follow";
    if (mode.current === "follow") {
      if (window.scrollY < bottom() - 1) scroll(bottom, true);
    } else {
      for (const { id, offset } of held.current) {
        const row = document.querySelector(`[data-turn="${CSS.escape(id)}"]`);
        if (row) { moveBy(row.getBoundingClientRect().top - offset); break; }
      }
    }
    near.current = latestBelow() <= NEAR_LATEST;
  };
  const settling = useRef(settle);
  settling.current = settle;

  useLayoutEffect(() => {
    if (!shown.current) {
      if (!loaded) return;
      // Opened at the latest, at once, following the agent if it is at work.
      shown.current = true;
      placed.current = key;
      mode.current = busy ? "follow" : "static";
      scroll(bottom, false);
      hold();
      return;
    }
    if (key !== placed.current) {
      placed.current = key;
      if (placing) {
        room.current = key;
        mode.current = "watch";
        scroll(bottom, true);
        return;
      }
    }
    // Its turn over, a view that only watched it holds still.
    if (!busy && mode.current === "watch") mode.current = "static";
    settle();
  });
  // A question the agent waits on is never left below the fold.
  useLayoutEffect(() => {
    if (!permission || !card.current) return;
    if (card.current.getBoundingClientRect().bottom <= window.innerHeight) return;
    scroll(() => window.scrollY + card.current.getBoundingClientRect().bottom - window.innerHeight + EDGE, true);
  }, [permission?.id]);
  useLayoutEffect(() => {
    const onScroll = () => {
      const root = document.documentElement;
      const atBottom = root.scrollHeight - root.scrollTop - root.clientHeight < 40;
      // The reader scrolling away from the latest stops the view going after it.
      if (reader.current && !atBottom) mode.current = "static";
      if (mode.current !== "follow") hold();
      near.current = latestBelow() <= NEAR_LATEST;
      setAway(!atBottom);
    };
    const onInput = () => { reader.current = true; stopGlide(); };
    // A height that changes with no new state, as code highlighting finishes, moves nothing.
    const observer = new ResizeObserver(() => settling.current());
    observer.observe(column.current);
    const onResize = () => { onScroll(); settling.current(); };
    window.addEventListener("scroll", onScroll, { passive: true });
    // The composer growing shrinks the page from below without a scroll.
    window.addEventListener("resize", onResize);
    for (const input of ["wheel", "keydown", "pointerdown"]) window.addEventListener(input, onInput, { passive: true });
    return () => {
      observer.disconnect();
      window.removeEventListener("scroll", onScroll);
      window.removeEventListener("resize", onResize);
      for (const input of ["wheel", "keydown", "pointerdown"]) window.removeEventListener(input, onInput);
    };
  }, []);

  const last = turns[turns.length - 1];
  // A prompt not in the transcript yet gets the date line it will have there, so nothing shifts
  // under it when it arrives.
  const now = new Date().toISOString();
  const pendingDate = pending && opens(last, now) ? now : null;
  const row = (turn, index) => {
    const date = separator(turns, index);
    return (
      <div key={turn.id} data-turn={turn.id}>
        {date && <div className="date">{dateLine(date)}</div>}
        {/* A prompt sent after it is what the agent works on, not this turn. */}
        <Turn turn={turn} working={busy && !pending && index === turns.length - 1} activity={activity} />
      </div>
    );
  };
  const replies = prompt ? start + 1 : start;
  return (
    <div className="column" ref={column}>
      {loaded && turns.length === 0 && !pending && <div className="empty">{t("No conversation yet. Send a message to start.")}</div>}
      {turns.slice(0, replies).map((turn, index) => row(turn, index))}
      {pendingDate && <div className="date">{dateLine(pendingDate)}</div>}
      {pending && (
        <div className={`turn prompt${queued ? " queued" : ""}`}>
          <div className="pill">{pending}</div>
          {/* Sent, it has the row the transcript will give it, so it does not shift when it arrives. */}
          {queued ? <div className="actions"><span>{t("Waiting to send")}</span></div> : <Actions text={pending} at={now} />}
        </div>
      )}
      <div className={roomy ? "reply roomy" : "reply"}>
        {turns.slice(replies).map((turn, index) => row(turn, replies + index))}
        {busy && !permission && (pending || last?.role === "user") && <div className="turn working"><Activity activity={activity} /></div>}
        {permission && <div ref={card}><Permission key={permission.id} permission={permission} /></div>}
        <div ref={end} />
      </div>
      {away && (
        <button className="to-latest" aria-label={t("Scroll to latest")} title={t("Scroll to latest")}
                onClick={() => { mode.current = "follow"; scroll(bottom, true); }}>
          <DownIcon />
        </button>
      )}
    </div>
  );
}

const root = createRoot(document.getElementById("chat"));
window.nativeChat = {
  render(state) {
    localization = state.localization ?? localization;
    document.documentElement.lang = localization.language;
    document.title = t("Conversation");
    root.render(<Chat state={state} />);
  },
};
window.addEventListener("error", (event) => post({ type: "error", message: event.message || t("The chat page failed to load.") }));
post({ type: "ready" });
