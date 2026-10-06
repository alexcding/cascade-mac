// A slim DiffPanel: Synara's review panel for one thread's turn diffs, drawn over the chat.
//
// Synara's DiffPanel (apps/web/src/components/DiffPanel.tsx) is not vendored: besides the
// checkpoint diffs it reviews the git working tree (git.status, git.listBranches, working-tree
// diff stats, blame, compare refs, commit and push through GitActionsControl), none of which the
// app serves, and it gates every view on git.listBranches. This keeps its turn view, wired as it
// wires it: the same checkpoint query (checkpointDiffQueryOptions → orchestration.getTurnDiff for
// one turn, orchestration.getFullThreadDiff for the whole thread), the same patch parsing
// (getRenderablePatch), the same body (DiffPanelPatchViewport, DiffPanelChangeMarkers) in the
// same shell (DiffPanelShell, "sheet": the page is a pane, too narrow for Synara's inline column).
//
// Synara's per-file "Edit file" opens the file in its own diff editor; here it is handed to the
// app as `openTurnDiff { threadId, turnId, filePath }`, which opens Cascade's diff of that file.
import { type ThreadId, type TurnId } from "@synara/contracts";
import { useQuery } from "@tanstack/react-query";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import { useAppSettings } from "~/appSettings";
import { DiffPanelChangeMarkers } from "~/components/DiffPanelChangeMarkers";
import { DiffPanelPatchViewport } from "~/components/DiffPanelPatchViewport";
import { DiffPanelShell } from "~/components/DiffPanelShell";
import { resolveConversationCacheScope, resolveSelectedTurnSummary } from "~/components/DiffPanel.logic";
import { ComposerPickerMenuPopup } from "~/components/chat/ComposerPickerMenuPopup";
import { DiffStat } from "~/components/chat/DiffStatLabel";
import { TOOLBAR_ICON_BUTTON_TONE_CLASS_NAME } from "~/components/ui/button-group";
import { IconButton } from "~/components/ui/icon-button";
import { Menu, MenuItem, MenuTrigger } from "~/components/ui/menu";
import { useTheme } from "~/hooks/useTheme";
import { appendChatFileReference, appendComposerPromptText, buildWhyChangedPrompt } from "~/lib/chatReferences";
import { getRenderablePatch, sortFileDiffsByPath, summarizeRenderablePatchStats } from "~/lib/diffRendering";
import { ChevronDownIcon, Columns2Icon, Rows3Icon, TextWrapIcon, XIcon } from "~/lib/icons";
import { checkpointDiffQueryOptions, resolveCheckpointDiffQueryDisplayState } from "~/lib/providerReactQuery";
import { formatShortTimestamp } from "~/timestampFormat";
import { type TurnDiffSummary } from "~/types";

import { emit } from "./bridge";

export interface TurnDiffSelection {
  /** The turn shown, or null for the whole thread. */
  turnId: TurnId | null;
  filePath: string | null;
}

export function TurnDiffPanel(props: {
  threadId: ThreadId;
  workspaceRoot: string | null;
  /** A transcript to read: no per-file actions that write into a composer it does not have. */
  readOnly: boolean;
  turnDiffSummaries: ReadonlyArray<TurnDiffSummary>;
  inferredCheckpointTurnCountByTurnId: Record<string, number | undefined>;
  selection: TurnDiffSelection;
  onSelect: (selection: TurnDiffSelection) => void;
  onClose: () => void;
}) {
  const { threadId, turnDiffSummaries, inferredCheckpointTurnCountByTurnId, selection, onSelect, onClose } = props;
  const { resolvedTheme } = useTheme();
  const { settings } = useAppSettings();
  const [diffRenderMode, setDiffRenderMode] = useState<"stacked" | "split">("stacked");
  const [diffWordWrap, setDiffWordWrap] = useState(settings.diffWordWrap);
  const [collapsedFiles, setCollapsedFiles] = useState<Set<string>>(() => new Set());
  const patchViewportRef = useRef<HTMLDivElement>(null);

  const turnCountOf = useCallback(
    (summary: TurnDiffSummary) => summary.checkpointTurnCount ?? inferredCheckpointTurnCountByTurnId[summary.turnId],
    [inferredCheckpointTurnCountByTurnId],
  );
  // Newest first, as DiffPanel orders them.
  const orderedTurnDiffSummaries = useMemo(
    () =>
      [...turnDiffSummaries].toSorted((left, right) => {
        const byCount = (turnCountOf(right) ?? 0) - (turnCountOf(left) ?? 0);
        return byCount !== 0 ? byCount : right.completedAt.localeCompare(left.completedAt);
      }),
    [turnCountOf, turnDiffSummaries],
  );
  const selectedTurn = resolveSelectedTurnSummary(selection.turnId, orderedTurnDiffSummaries);
  const selectedTurnCount = selectedTurn ? turnCountOf(selectedTurn) : undefined;
  const conversationTurnCount = useMemo(() => {
    const counts = orderedTurnDiffSummaries.map(turnCountOf).filter((value): value is number => typeof value === "number");
    const latest = counts.length > 0 ? Math.max(...counts) : 0;
    return latest > 0 ? latest : undefined;
  }, [orderedTurnDiffSummaries, turnCountOf]);
  const range = selectedTurn
    ? typeof selectedTurnCount === "number"
      ? { fromTurnCount: Math.max(0, selectedTurnCount - 1), toTurnCount: selectedTurnCount }
      : null
    : typeof conversationTurnCount === "number"
      ? { fromTurnCount: 0, toTurnCount: conversationTurnCount }
      : null;
  const diffQuery = useQuery(
    checkpointDiffQueryOptions({
      threadId,
      fromTurnCount: range?.fromTurnCount ?? null,
      toTurnCount: range?.toTurnCount ?? null,
      ignoreWhitespace: true,
      cacheScope: selectedTurn ? `turn:${selectedTurn.turnId}` : resolveConversationCacheScope(conversationTurnCount),
      enabled: range !== null,
    }),
  );
  const display = resolveCheckpointDiffQueryDisplayState({
    isLoading: diffQuery.isLoading,
    isFetching: diffQuery.isFetching,
    data: diffQuery.data,
    error: diffQuery.error,
  });
  const patch = diffQuery.data?.diff;
  const renderablePatch = useMemo(() => getRenderablePatch(patch), [patch]);
  const renderableFiles = useMemo(
    () => (renderablePatch?.kind === "files" ? sortFileDiffsByPath(renderablePatch.files) : []),
    [renderablePatch],
  );
  const stats = useMemo(() => summarizeRenderablePatchStats(renderablePatch), [renderablePatch]);

  useEffect(() => {
    if (!selection.filePath) return;
    const viewport = patchViewportRef.current;
    const target = viewport?.querySelector(`[data-diff-file-path="${CSS.escape(selection.filePath)}"]`);
    target?.scrollIntoView?.({ block: "nearest" });
  }, [renderableFiles, selection.filePath]);

  const toggleFileCollapsed = useCallback((fileKey: string) => {
    setCollapsedFiles((previous) => {
      const next = new Set(previous);
      if (next.has(fileKey)) next.delete(fileKey);
      else next.add(fileKey);
      return next;
    });
  }, []);
  const chatActions = useMemo(
    () => ({
      onReferenceInChat: (filePath: string) => appendChatFileReference(threadId, { path: filePath }),
      onAskWhyChanged: (filePath: string) => appendComposerPromptText(threadId, buildWhyChangedPrompt(filePath)),
      onEditFile: (filePath: string) => {
        const turnId = selectedTurn?.turnId ?? orderedTurnDiffSummaries[0]?.turnId;
        if (turnId) emit("openTurnDiff", { threadId, turnId, filePath });
      },
    }),
    [orderedTurnDiffSummaries, selectedTurn?.turnId, threadId],
  );

  const turnLabel = (summary: TurnDiffSummary) => {
    const count = turnCountOf(summary);
    return typeof count === "number" ? `Turn ${count}` : "Turn";
  };
  const header = (
    <div className="flex w-full min-w-0 items-center gap-1.5" data-turn-diff-header="">
      <Menu>
        <MenuTrigger
          render={
            <button
              type="button"
              className="inline-flex min-w-0 items-center gap-1 rounded-full px-2 py-1 text-ui-sm font-medium text-foreground hover:bg-[var(--color-background-button-secondary-hover)]"
            >
              <span className="truncate">{selectedTurn ? turnLabel(selectedTurn) : "All turns"}</span>
              <ChevronDownIcon className="size-3 shrink-0 text-muted-foreground" />
            </button>
          }
        />
        <ComposerPickerMenuPopup align="start" side="bottom" sideOffset={6} className="w-64 min-w-64">
          <MenuItem onClick={() => onSelect({ turnId: null, filePath: null })}>
            <span className="flex-1">All turns</span>
          </MenuItem>
          {orderedTurnDiffSummaries.map((summary) => {
            const additions = summary.files.reduce((sum, file) => sum + (file.additions ?? 0), 0);
            const deletions = summary.files.reduce((sum, file) => sum + (file.deletions ?? 0), 0);
            return (
              <MenuItem key={summary.turnId} onClick={() => onSelect({ turnId: summary.turnId, filePath: null })}>
                <span className="flex-1 truncate">{turnLabel(summary)}</span>
                <DiffStat additions={additions} deletions={deletions} className="text-ui-xs tabular-nums" />
                <span className="text-ui-xs text-muted-foreground">
                  {formatShortTimestamp(summary.completedAt, settings.timestampFormat)}
                </span>
              </MenuItem>
            );
          })}
        </ComposerPickerMenuPopup>
      </Menu>
      {stats ? (
        <DiffStat additions={stats.additions} deletions={stats.deletions} className="text-ui-xs tabular-nums" />
      ) : null}
      <div className="ml-auto flex items-center gap-0.5">
        <IconButton
          variant="ghost"
          size="icon-xs"
          shape="capsule"
          className={TOOLBAR_ICON_BUTTON_TONE_CLASS_NAME}
          label={diffRenderMode === "split" ? "Stacked diff" : "Split diff"}
          onClick={() => setDiffRenderMode((mode) => (mode === "split" ? "stacked" : "split"))}
        >
          {diffRenderMode === "split" ? <Rows3Icon className="size-3.5" /> : <Columns2Icon className="size-3.5" />}
        </IconButton>
        <IconButton
          variant="ghost"
          size="icon-xs"
          shape="capsule"
          className={TOOLBAR_ICON_BUTTON_TONE_CLASS_NAME}
          label={diffWordWrap ? "Disable word wrap" : "Enable word wrap"}
          onClick={() => setDiffWordWrap((wrap) => !wrap)}
        >
          <TextWrapIcon className="size-3.5" />
        </IconButton>
        <IconButton
          variant="ghost"
          size="icon-xs"
          shape="capsule"
          className={TOOLBAR_ICON_BUTTON_TONE_CLASS_NAME}
          label="Close diff"
          onClick={onClose}
        >
          <XIcon className="size-3.5" />
        </IconButton>
      </div>
    </div>
  );

  return (
    <div className="absolute inset-0 z-30 flex" data-turn-diff-panel="" onKeyDown={(event) => event.key === "Escape" && onClose()}>
      <DiffPanelShell mode="sheet" header={header}>
        <div ref={patchViewportRef} className="diff-panel-viewport relative flex min-h-0 min-w-0 flex-1 flex-col overflow-hidden">
          <DiffPanelPatchViewport
            renderablePatch={renderablePatch}
            renderableFiles={renderableFiles}
            resolvedTheme={resolvedTheme}
            diffRenderMode={diffRenderMode}
            diffWordWrap={diffWordWrap}
            workspaceRoot={props.workspaceRoot}
            collapsedFiles={collapsedFiles}
            onToggleFileCollapsed={toggleFileCollapsed}
            chatActions={props.readOnly ? undefined : chatActions}
            isLoading={display.isLoading}
            hasNoChanges={typeof patch === "string" && patch.trim().length === 0}
            error={range === null ? "No turn diffs are available yet." : display.error}
            refreshStatus={display.refreshStatus}
            viewKind="turn"
            loadingLabel="Loading checkpoint diff..."
            emptyLabel={orderedTurnDiffSummaries.length === 0 ? "No turn diffs are available yet." : "No net changes in this selection."}
            unavailableLabel="No diff is available right now."
          />
          <DiffPanelChangeMarkers
            viewportRef={patchViewportRef}
            renderableFiles={renderableFiles}
            onSelectFilePath={(filePath) => onSelect({ turnId: selection.turnId, filePath })}
          />
        </div>
      </DiffPanelShell>
    </div>
  );
}
