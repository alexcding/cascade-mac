// Folds the app's "thread" pushes into Synara's store, the way Synara's root route folds its
// server's thread stream (apps/web/src/routes/__root.tsx): a snapshot replaces the thread's
// detail (syncServerThreadDetailHotPath), and the events after it are applied in sequence
// order, coalesced and batched per frame (coalesceOrchestrationUiEvents,
// applyOrchestrationEventsHotPath). An event older than what is applied is dropped; an event
// that skips a sequence number means one was lost, so the page asks for a fresh snapshot.
import {
  ProjectId,
  ThreadId,
  type OrchestrationEvent,
  type OrchestrationThreadDetailSnapshot,
} from "@synara/contracts";
import type { QueryClient } from "@tanstack/react-query";

import { providerQueryKeys } from "~/lib/providerReactQuery";
import { coalesceOrchestrationUiEvents } from "~/orchestrationEventCoalescing";
import { useStore } from "~/store";

import { BridgeError, cancelPending, latestPush, onPush, request, type ChatContext } from "./bridge";
import { decodeOrchestrationEvent, decodeThreadSnapshot } from "./decode";

type StreamItem =
  | { kind: "snapshot"; snapshot: unknown }
  | { kind: "event"; event: unknown };

const PENDING_LIMIT = 2_000;

let appliedSequence: number | undefined;
let currentThreadId: string | null = null;
let pending: OrchestrationEvent[] = [];
let batch: OrchestrationEvent[] = [];
let flushScheduled = false;
/** The read in flight, and the thread it was made for. */
let snapshotRequest: { threadId: string; promise: Promise<void> } | null = null;
let queryClient: QueryClient | null = null;

const SNAPSHOT_READ = "orchestration.getThreadDetailSnapshot";

/** Synara's store keys threads by project; the thread's project is made from the context. */
function ensureProject(projectId: string): void {
  const state = useStore.getState();
  if (state.projects.some((project) => project.id === projectId)) return;
  const context = latestPush<ChatContext>("context");
  const now = new Date().toISOString();
  state.applyShellEvent({
    kind: "project-upserted",
    sequence: 0,
    project: {
      id: ProjectId.makeUnsafe(projectId),
      kind: "project",
      title: context?.projectName || "Project",
      workspaceRoot: context?.cwd || "/",
      defaultModelSelection: null,
      scripts: [],
      isPinned: false,
      spaceId: null,
      createdAt: now,
      updatedAt: now,
    },
  });
}

function scheduleFlush(): void {
  if (flushScheduled) return;
  flushScheduled = true;
  setTimeout(flush, 16);
}

function flush(): void {
  flushScheduled = false;
  if (batch.length === 0) return;
  const events = batch;
  batch = [];
  useStore.getState().applyOrchestrationEventsHotPath(coalesceOrchestrationUiEvents(events));
  // A settled turn may have changed what the provider offers (commands, skills) and the
  // files an @-mention lists, as Synara's root route refreshes them.
  if (events.some((event) => event.type === "thread.session-set" && event.payload.session.status !== "running")) {
    void queryClient?.invalidateQueries({ queryKey: providerQueryKeys.all });
  }
}

function applySnapshot(snapshot: OrchestrationThreadDetailSnapshot): void {
  // A snapshot older than what is on screen (a read that raced the stream) changes nothing.
  if (appliedSequence !== undefined && snapshot.snapshotSequence < appliedSequence) {
    drainPending();
    return;
  }
  ensureProject(snapshot.thread.projectId);
  // Events already batched belong to the state this snapshot replaces.
  batch = [];
  useStore.getState().syncServerThreadDetailHotPath(snapshot.thread, snapshot.snapshotSequence);
  appliedSequence = snapshot.snapshotSequence;
  drainPending();
}

/** Applies the buffered events that follow what is applied; a gap left waits for a read. */
function drainPending(): void {
  if (appliedSequence === undefined) return;
  const ordered = pending.filter((event) => event.sequence > appliedSequence!).sort((a, b) => a.sequence - b.sequence);
  pending = [];
  for (let index = 0; index < ordered.length; index++) {
    const event = ordered[index]!;
    if (event.sequence === appliedSequence + 1) {
      take(event);
      continue;
    }
    if (event.sequence <= appliedSequence) continue;
    pending = ordered.slice(index);
    scheduleRefresh();
    return;
  }
  refreshAttempts = 0;
}

function take(event: OrchestrationEvent): void {
  appliedSequence = event.sequence;
  batch.push(event);
  scheduleFlush();
}

function applyEvent(event: OrchestrationEvent): void {
  if (appliedSequence === undefined || snapshotRequest) {
    if (pending.length < PENDING_LIMIT) pending.push(event);
    if (appliedSequence === undefined) scheduleRefresh();
    return;
  }
  if (event.sequence <= appliedSequence) return;
  if (event.sequence > appliedSequence + 1) {
    if (pending.length < PENDING_LIMIT) pending.push(event);
    scheduleRefresh();
    return;
  }
  take(event);
  if (pending.length > 0) drainPending();
}

let refreshAttempts = 0;
let refreshTimer: ReturnType<typeof setTimeout> | null = null;

/**
 * Reads the thread again after a lost event, at once the first time and then backing off
 * (0.5 s doubling to 30 s) while the reads come back no newer, so a backend whose snapshot
 * trails its events is asked again later rather than in a loop.
 */
function scheduleRefresh(): void {
  if (refreshTimer || snapshotRequest) return;
  const delay = refreshAttempts === 0 ? 0 : Math.min(30_000, 500 * 2 ** (refreshAttempts - 1));
  refreshAttempts++;
  refreshTimer = setTimeout(() => {
    refreshTimer = null;
    void refreshSnapshot();
  }, delay);
}

/**
 * Reads the thread again, after a lost event or when the page starts without a push. A read
 * already in flight for the thread is shared, unless `fresh` asks for one made after now (as
 * Synara's subscribeThread does after a command: the read in flight may predate it).
 * Never rejects: a failed read is retried while events wait on it.
 */
export function refreshSnapshot(options: { fresh?: boolean } = {}): Promise<void> {
  const threadId = currentThreadId;
  if (!threadId) return Promise.resolve();
  if (snapshotRequest && snapshotRequest.threadId === threadId) {
    if (!options.fresh) return snapshotRequest.promise;
    return snapshotRequest.promise.then(() => (currentThreadId === threadId ? refreshSnapshot() : undefined));
  }
  const promise: Promise<void> = request<OrchestrationThreadDetailSnapshot | null>(SNAPSHOT_READ, { threadId })
    .then((result) => {
      if (snapshotRequest?.promise === promise) snapshotRequest = null;
      if (threadId !== currentThreadId) return;
      if (result) applySnapshot(decodeThreadSnapshot(result));
      else drainPending();
    })
    .catch((error: unknown) => {
      if (snapshotRequest?.promise === promise) snapshotRequest = null;
      if (threadId !== currentThreadId) return;
      // Events wait on this read, or the app never answered it: ask again, backing off.
      const timedOut = error instanceof BridgeError && error.code === "timeout";
      if (pending.length > 0 || timedOut) scheduleRefresh();
    });
  snapshotRequest = { threadId, promise };
  return promise;
}

/** The thread the stream applies; pushes for any other are dropped. */
export function streamThreadId(): string | null {
  return currentThreadId;
}

/** Whether a snapshot of the thread on screen has been applied. */
export function hasSnapshot(): boolean {
  return appliedSequence !== undefined;
}

/**
 * Switches the stream to another thread: what was applied, buffered or scheduled for the old
 * one is dropped, and its read in flight is cancelled (its answer would be the old thread's).
 */
export function setStreamThread(threadId: string | null): void {
  if (threadId === currentThreadId) return;
  currentThreadId = threadId;
  appliedSequence = undefined;
  pending = [];
  batch = [];
  refreshAttempts = 0;
  if (refreshTimer) clearTimeout(refreshTimer);
  refreshTimer = null;
  if (snapshotRequest) {
    snapshotRequest = null;
    cancelPending(SNAPSHOT_READ);
  }
}

export function installThreadStream(client: QueryClient): void {
  queryClient = client;
  // The context names the thread. It is switched here, as the push lands, not when React next
  // renders: the app pushes the new thread's snapshot right behind its context, in the same
  // turn, and it must find the stream already on that thread.
  const followContext = (context: ChatContext | undefined) => {
    if (context?.threadId) setStreamThread(context.threadId);
  };
  followContext(latestPush<ChatContext>("context"));
  onPush<ChatContext>("context", followContext);
  onPush<StreamItem>("thread", (item) => {
    if (!item || typeof item !== "object") return;
    if (item.kind === "snapshot") {
      const snapshot = decodeThreadSnapshot(item.snapshot);
      if (currentThreadId && snapshot.thread.id !== currentThreadId) return;
      if (!currentThreadId) setStreamThread(snapshot.thread.id);
      applySnapshot(snapshot);
      return;
    }
    if (item.kind === "event") {
      const event = decodeOrchestrationEvent(item.event);
      if (currentThreadId && String(event.aggregateId) !== currentThreadId) return;
      applyEvent(event);
    }
  });
}

export function threadIdOf(value: string): ThreadId {
  return ThreadId.makeUnsafe(value);
}
