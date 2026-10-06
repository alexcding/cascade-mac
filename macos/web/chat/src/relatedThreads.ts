// The threads a subagent strip reads besides the one on screen. Synara's ChatView keeps a parent's
// subagent threads (their own session says whether they still run) and, on a subagent's thread,
// its parent (whose activities list the siblings) in its store through detail subscriptions
// (useChatWorkLog's retainThreadDetailSubscription). The app pushes only the thread on screen, so
// this page reads the others itself with `orchestration.getThreadDetailSnapshot` and puts them in
// Synara's store, again whenever the thread on screen changes, at most every READ_INTERVAL_MS; a
// subagent seen settled is not read again until a new tool call names it.
import { ThreadId, type OrchestrationThread, type OrchestrationThreadActivity, type OrchestrationThreadDetailSnapshot } from "@synara/contracts";
import { decodeSubagentReceiverThreadIds } from "@synara/shared/subagents";
import { useEffect, useRef } from "react";

import { localSubagentThreadId } from "~/components/ChatView.selectors";
import { useStore } from "~/store";

import { request } from "./bridge";
import { decodeThreadSnapshot } from "./decode";

const READ_INTERVAL_MS = 500;
/** Synara's cap on the subagent threads one parent turn shows (MAX_NATIVE_CHILDREN_PER_PARENT_TURN). */
const MAX_RELATED_THREADS = 20;

function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : null;
}

/** How many subagent tool calls name each provider thread id, oldest named first (Synara's workLog). */
function subagentMentions(activities: ReadonlyArray<OrchestrationThreadActivity>): Map<string, number> {
  const mentions = new Map<string, number>();
  for (const activity of activities) {
    const payload = asRecord(activity.payload);
    if (payload?.itemType !== "collab_agent_tool_call") continue;
    const data = asRecord(payload.data);
    const item = asRecord(data?.item) ?? data;
    for (const id of new Set(decodeSubagentReceiverThreadIds(item))) {
      mentions.set(id, (mentions.get(id) ?? 0) + 1);
    }
  }
  return mentions;
}

/** The provider thread ids the thread's subagent tool calls name, oldest first (Synara's workLog). */
export function subagentProviderThreadIds(activities: ReadonlyArray<OrchestrationThreadActivity>): string[] {
  return [...subagentMentions(activities).keys()];
}

/**
 * A thread the strip reads: the parent of a subagent's page, or a subagent thread, with how many
 * tool calls of its parent name it. A subagent read once it has settled is not read again until a
 * new call names it (Codex can send a settled agent more work); the parent is always read.
 */
export interface RelatedThread {
  readonly id: string;
  readonly child: boolean;
  readonly mentions: number;
}

/**
 * The threads to read for `thread`: its parent, if it is a subagent's, and the subagent threads of
 * whichever of the two the strip is drawn from (the parent on a subagent's page).
 */
export function relatedThreads(
  thread: Pick<OrchestrationThread, "id" | "parentThreadId" | "activities"> | undefined,
  parent: Pick<OrchestrationThread, "id" | "activities"> | undefined,
): RelatedThread[] {
  if (!thread) return [];
  const related: RelatedThread[] = [];
  if (thread.parentThreadId) related.push({ id: String(thread.parentThreadId), child: false, mentions: 0 });
  const source = thread.parentThreadId ? parent : thread;
  if (source) {
    const children = [...subagentMentions(source.activities)].map(([id, mentions]) => ({
      id: String(localSubagentThreadId(ThreadId.makeUnsafe(String(source.id)), id)),
      child: true,
      mentions,
    }));
    related.push(...children.slice(-MAX_RELATED_THREADS));
  }
  const seen = new Set<string>([String(thread.id)]);
  return related.filter((entry) => !seen.has(entry.id) && Boolean(seen.add(entry.id)));
}

/** The snapshot sequence applied per related thread, so a late answer cannot undo a newer one. */
const appliedSequences = new Map<string, number>();
/** Per subagent thread seen settled, how many tool calls named it when it was read. */
const settledAtMentions = new Map<string, number>();

function isSettled(thread: Pick<OrchestrationThread, "session" | "latestTurn">): boolean {
  const status = thread.session?.status;
  return status !== "running" && status !== "starting" && thread.latestTurn?.state !== "running";
}

/** Whether `entry` still needs reading: a subagent seen settled since its last mention does not. */
export function needsRead(entry: RelatedThread): boolean {
  return !entry.child || settledAtMentions.get(entry.id) !== entry.mentions;
}

function readRelatedThread(entry: RelatedThread): void {
  const threadId = entry.id;
  void request<OrchestrationThreadDetailSnapshot | null>("orchestration.getThreadDetailSnapshot", { threadId })
    .then((result) => {
      if (!result) return;
      const snapshot = decodeThreadSnapshot(result);
      if ((appliedSequences.get(threadId) ?? -1) > snapshot.snapshotSequence) return;
      appliedSequences.set(threadId, snapshot.snapshotSequence);
      if (entry.child && isSettled(snapshot.thread)) settledAtMentions.set(threadId, entry.mentions);
      else settledAtMentions.delete(threadId);
      useStore.getState().syncServerThreadDetailHotPath(snapshot.thread, snapshot.snapshotSequence);
    })
    .catch(() => undefined);
}

/**
 * Reads `threads` into the store now and each time `revision` changes, at most every 500 ms,
 * skipping the subagents already seen settled.
 */
export function useRelatedThreadSnapshots(threads: readonly RelatedThread[], revision: unknown): void {
  const key = threads.map((entry) => `${entry.child ? "c" : "p"}${entry.mentions}:${entry.id}`).join("\n");
  const latest = useRef(threads);
  latest.current = threads;
  const lastRead = useRef(0);
  const pending = useRef<{ timer: ReturnType<typeof setTimeout>; key: string } | null>(null);
  useEffect(() => {
    if (!key || pending.current?.key === key) return;
    if (!latest.current.some(needsRead)) return;
    if (pending.current) clearTimeout(pending.current.timer);
    const wait = Math.max(0, READ_INTERVAL_MS - (Date.now() - lastRead.current));
    const timer = setTimeout(() => {
      pending.current = null;
      lastRead.current = Date.now();
      for (const entry of latest.current) if (needsRead(entry)) readRelatedThread(entry);
    }, wait);
    pending.current = { timer, key };
  }, [key, revision]);
  useEffect(
    () => () => {
      if (pending.current) clearTimeout(pending.current.timer);
      pending.current = null;
    },
    [],
  );
}
