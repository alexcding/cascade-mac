// The chat page. Push-only: Swift calls `window.nativeChat.render(state)` with the session's turns
// and the page draws them. It has no network access and reports back through one message
// handler — `ready`, `copy`, `open` and `download` — so it can never reach the backend itself.
import { memo, useLayoutEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { Streamdown } from "streamdown";
import { code } from "./highlight.js";

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

function Markdown({ text }) {
  return (
    <Streamdown mode="static" className="answer" plugins={{ code }}
      shikiTheme={["github-light", "github-dark"]} linkSafety={{ enabled: false }} tableMaxHeight={0}>
      {text}
    </Streamdown>
  );
}

const time = (iso) => iso ? new Date(iso).toLocaleString(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }) : "";

function dateLine(iso) {
  const date = new Date(iso);
  const day = date.toLocaleDateString(undefined, { weekday: "short", month: "short", day: "numeric" });
  const clock = date.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
  return `${day} at ${clock}`;
}

function duration(seconds) {
  const total = Math.round(seconds);
  if (total < 60) return `${total}s`;
  if (total < 3600) return `${Math.floor(total / 60)}m ${total % 60}s`;
  return `${Math.floor(total / 3600)}h ${Math.floor((total % 3600) / 60)}m`;
}

const CopyIcon = () => (
  <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.3"><rect x="5" y="5" width="8.5" height="8.5" rx="2"/><path d="M11 5V4a1.5 1.5 0 0 0-1.5-1.5h-5A1.5 1.5 0 0 0 3 4v5a1.5 1.5 0 0 0 1.5 1.5H5"/></svg>
);
const CheckIcon = () => (
  <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M3.5 8.5l3 3 6-7"/></svg>
);

function Actions({ text, at }) {
  const [copied, setCopied] = useState(false);
  return (
    <div className={`actions${copied ? " copied" : ""}`}>
      <button title="Copy" onClick={() => {
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

const VERBS = {
  Bash: "Ran", shell: "Ran", exec: "Ran", exec_command: "Ran", Read: "Read", Edit: "Edited",
  NotebookEdit: "Edited", apply_patch: "Edited", Write: "Created", Glob: "Searched", Grep: "Searched",
  WebFetch: "Fetched", WebSearch: "Searched the web", Task: "Delegated", Agent: "Delegated",
  spawn_agent: "Delegated", TodoWrite: "Updated plan", update_plan: "Updated plan",
};

function Tool({ tool }) {
  const name = tool.name || "Tool";
  const isEdit = tool.path != null && tool.new != null;
  const lines = isEdit ? diff(tool.old || "", tool.new) : null;
  const badge = isEdit && name !== "Write"
    ? `+${lines.filter((l) => l.kind === "add").length} −${lines.filter((l) => l.kind === "remove").length}` : null;
  const output = tool.output || "";
  const command = !isEdit && tool.command ? tool.command : "";
  const expandable = isEdit || output || command;
  const header = (
    <>
      <span className="verb">{VERBS[name] || name}</span>
      {tool.summary && <span className="summary">{tool.summary}</span>}
      {badge && <span className="badge">{badge}</span>}
      {tool.isError && <span className="error">failed</span>}
      {expandable && <span className="chev">›</span>}
    </>
  );
  if (!expandable) return <div className="tool"><summary>{header}</summary></div>;
  return (
    <details className="tool">
      <summary>{header}</summary>
      <div className="body">
        {command && <div><div className="block-label">Command</div><pre className="mono">{command}</pre></div>}
        {isEdit && (
          <div className="diff">
            {lines.slice(0, 400).map((line, index) => (
              <div key={index} className={line.kind}>{(line.kind === "add" ? "+ " : line.kind === "remove" ? "− " : "  ") + line.text}</div>
            ))}
          </div>
        )}
        {output && <div><div className="block-label">{tool.isError ? "Error" : "Output"}</div><pre className="mono">{output}</pre></div>}
      </div>
    </details>
  );
}

function Worked({ blocks, label, working }) {
  return (
    <details className="worked" open={working}>
      <summary><span className={working ? "shimmer" : undefined}>{label}</span> <span className="chev">›</span></summary>
      <div className="steps">
        {blocks.map((block, index) => {
          if (block.type === "tool") return <Tool key={index} tool={block} />;
          if (block.type === "thinking") return (
            <details key={index} className="thought">
              <summary>Thought ›</summary>
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
const Turn = memo(function Turn({ turn, working }) {
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
  let label = "Worked";
  if (working) label = "Working";
  else if (turn.timestamp && turn.ended) {
    const seconds = (new Date(turn.ended) - new Date(turn.timestamp)) / 1000;
    if (seconds > 0) label = `Worked for ${duration(seconds)}`;
  }
  return (
    <div className="turn">
      {(work.length > 0 || working) && <Worked blocks={work} label={label} working={working} />}
      {answer && <Markdown text={answer} />}
      {answer && !working && <Actions text={answer} at={turn.ended || turn.timestamp} />}
    </div>
  );
}, (before, after) => before.working === after.working && JSON.stringify(before.turn) === JSON.stringify(after.turn));

const ASKS = {
  Bash: "Run this command?", shell: "Run this command?", exec: "Run this command?", exec_command: "Run this command?",
  Edit: "Edit this file?", MultiEdit: "Edit this file?", Write: "Create this file?", apply_patch: "Apply this patch?",
  WebFetch: "Fetch this page?", WebSearch: "Search the web?",
};

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
      <div className="ask">{ASKS[permission.tool] || `Allow ${permission.tool}?`}</div>
      {permission.reason && <div className="reason">{permission.reason}</div>}
      {permission.detail && <pre className="mono">{permission.detail}</pre>}
      {change && (
        <div className="diff">
          {change.map((line, index) => (
            <div key={index} className={line.kind}>{(line.kind === "add" ? "+ " : line.kind === "remove" ? "− " : "  ") + line.text}</div>
          ))}
        </div>
      )}
      {permission.truncated && <div className="reason">Too long to show here in full. Review it in the terminal.</div>}
      <div className="choices">
        {permission.truncated
          ? <button className="allow" disabled={sent} onClick={() => answer("pass")}>Review in Terminal</button>
          : <button className="allow" disabled={sent} onClick={() => answer("allow")}>Allow</button>}
        <button disabled={sent} onClick={() => answer("deny")}>Deny</button>
      </div>
    </div>
  );
}

const SEPARATOR_GAP = 30 * 60 * 1000;

function separator(turns, index) {
  const turn = turns[index];
  if (turn.role !== "user" || !turn.timestamp) return null;
  if (index === 0) return turn.timestamp;
  const previous = turns[index - 1];
  const before = previous.ended || previous.timestamp;
  if (!before) return turn.timestamp;
  return new Date(turn.timestamp) - new Date(before) > SEPARATOR_GAP ? turn.timestamp : null;
}

function Chat({ state }) {
  const { turns, busy, pending, queued, loaded, permission } = state;
  const stick = useRef(true);
  // Follows the conversation down while the reader is at the bottom; scrolled up, it stays put.
  useLayoutEffect(() => {
    if (stick.current) window.scrollTo(0, document.documentElement.scrollHeight);
  });
  useLayoutEffect(() => {
    const onScroll = () => {
      const root = document.documentElement;
      stick.current = root.scrollHeight - root.scrollTop - root.clientHeight < 40;
    };
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  const last = turns[turns.length - 1];
  return (
    <div className="column">
      {loaded && turns.length === 0 && !pending && <div className="empty">No conversation yet. Send a message to start.</div>}
      {turns.map((turn, index) => {
        const date = separator(turns, index);
        return (
          <div key={turn.id}>
            {date && <div className="date">{dateLine(date)}</div>}
            <Turn turn={turn} working={busy && index === turns.length - 1} />
          </div>
        );
      })}
      {pending && (
        <div className={`turn prompt${queued ? " queued" : ""}`}>
          <div className="pill">{pending}</div>
          {queued && <div className="actions"><span>Waiting to send</span></div>}
        </div>
      )}
      {busy && !permission && (pending || last?.role === "user") && <div className="turn working"><span className="shimmer">Working</span></div>}
      {permission && <Permission key={permission.id} permission={permission} />}
    </div>
  );
}

const root = createRoot(document.getElementById("chat"));
window.nativeChat = {
  render(state) { root.render(<Chat state={state} />); },
};
window.addEventListener("error", (event) => post({ type: "error", message: event.message || "The chat page failed to load." }));
post({ type: "ready" });
