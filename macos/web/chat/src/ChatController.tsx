// The chat for one Synara thread: Synara's transcript and composer, wired the way Synara's
// ChatView wires them, with what Cascade does not have left out.
//
// ChatView.tsx (apps/web/src/components/ChatView.tsx, 6.9k lines) is not vendored: it is the
// whole app's chat surface (sidebar threads, split panes, terminal drawer, git, worktrees,
// automations, voice, computer control, sidechats). This controller keeps its core and calls
// the same vendored hooks in the same order: the composer draft (useChatComposerDraft), the
// model and provider state (useChatProviderModels, useChatProviderStatus), pending approvals
// and questions (useChatPendingInteractions), the work log and timeline (useChatWorkLog,
// useChatTimelineMessages, deriveTimelineEntries), the slash/mention menu
// (useComposerDiscovery, useComposerCommandMenuItems, useComposerSlashCommands,
// useChatComposerEditing, useChatComposerCommands) and the transcript scroll
// (useChatTranscriptScroll). Sending follows useChatTurnSubmission/useChatTurnExecution
// without their worktree, handoff, automation and queue branches: attachments are saved
// through the app (`attachments.save`) instead of Synara's HTTP upload route.
import {
  MessageId,
  PROVIDER_DISPLAY_NAMES,
  PROVIDER_SEND_TURN_MAX_ATTACHMENTS,
  ThreadId,
  type ChatFileAttachment,
  type ChatImageAttachment,
  type ModelSlug,
  type ProviderKind,
  type UploadChatAttachment,
} from "@synara/contracts";
import { resolveComputerInvocationMode } from "@synara/shared/computerInvocation";
import { resolveThreadWorkspaceCwd as resolveSharedThreadWorkspaceCwd } from "@synara/shared/threadEnvironment";
import { type LegendListRef } from "@legendapp/list/react";
import { LoaderCircleIcon } from "~/lib/icons";
import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type FormEvent,
} from "react";

import {
  resolveAppModelSelection,
  resolveAssistantDeliveryMode,
  resolveDefaultProviderInstanceId,
  resolveFollowUpDispatchMode,
  useAppSettings,
} from "~/appSettings";
import { collapseExpandedComposerCursor, detectComposerTrigger } from "~/composer-logic";
import { useComposerDraftStore, type ComposerImageAttachment, type ComposerFileAttachment } from "~/composerDraftStore";
import { RuntimeUsageControls } from "~/components/BranchToolbar";
import {
  canApplyComposerFocus,
  commitAfterRuntimeModePersistence,
  deriveComposerSendState,
  derivePromptHistoryFromMessages,
  resolveCommittedProviderModel,
  resolveWorkingLabel,
  shouldEnableComposerPastedTextCollapse,
  turnStartDispatchFields,
  type TurnDispatchSettings,
} from "~/components/ChatView.logic";
import { ComposerPromptEditor } from "~/components/ComposerPromptEditor";
import { composerFooterPlanForTier } from "~/components/composerFooterLayout";
import { ChatComposerFooter } from "~/components/chat/ChatComposerFooter";
import { ChatTranscriptPane } from "~/components/chat/ChatTranscriptPane";
import { ComposerColumnFrame } from "~/components/chat/ComposerColumnFrame";
import { ComposerCommandMenu, type ComposerCommandItem } from "~/components/chat/ComposerCommandMenu";
import { ComposerExtrasPanel } from "~/components/chat/ComposerExtrasPanel";
import { ComposerExtrasTrigger } from "~/components/chat/ComposerExtrasTrigger";
import { ComposerModelPicker, type ComposerModelSelectionOptions } from "~/components/chat/ComposerModelPicker";
import { ComposerPendingApprovalPanel } from "~/components/chat/ComposerPendingApprovalPanel";
import { ComposerPendingUserInputPanel } from "~/components/chat/ComposerPendingUserInputPanel";
import { ComposerReferenceAttachments } from "~/components/chat/ComposerReferenceAttachments";
import { ContextWindowMeter } from "~/components/chat/ContextWindowMeter";
import { ExpandedImageOverlay } from "~/components/chat/ExpandedImageOverlay";
import type { MessagesTimelineController } from "~/components/chat/MessagesTimeline";
import { buildTurnDiffSummaryByAssistantMessageId } from "~/components/chat/MessagesTimeline.logic";
import { deriveAgentActivityTimelineState } from "~/components/chat/agentActivity.logic";
import {
  COMPOSER_COMMAND_MENU_FLOATING_WRAPPER_CLASS_NAME,
  COMPOSER_EDITOR_PADDING_CLASS_NAME,
  COMPOSER_INPUT_SHELL_CLASS_NAME,
  COMPOSER_INPUT_SURFACE_CLASS_NAME,
} from "~/components/chat/composerPickerStyles";
import { composerTranscriptBottomInsetPx, useComposerOverlayHeight } from "~/components/chat/composerOverlay";
import { getComposerTraitSelection } from "~/components/chat/composerTraits";
import { resolveRuntimeModelDescriptor } from "~/components/chat/runtimeModelCapabilities";
import { useChatComposerCommands } from "~/components/chat/useChatComposerCommands";
import { useChatComposerDraft } from "~/components/chat/useChatComposerDraft";
import { useChatComposerEditing } from "~/components/chat/useChatComposerEditing";
import { useChatPendingInteractions } from "~/components/chat/useChatPendingInteractions";
import { useChatProviderModels } from "~/components/chat/useChatProviderModels";
import { useChatProviderStatus } from "~/components/chat/useChatProviderStatus";
import { useChatRuntimeModes } from "~/components/chat/useChatRuntimeModes";
import { useChatTimelineMessages } from "~/components/chat/useChatTimelineMessages";
import { useChatTranscriptScroll } from "~/components/chat/useChatTranscriptScroll";
import { useChatWorkLog } from "~/components/chat/useChatWorkLog";
import { useComposerDiscovery } from "~/components/chat/useComposerDiscovery";
import { useComposerReferences } from "~/components/chat/useComposerReferences";
import { useExpandedImagePreview } from "~/components/chat/useExpandedImagePreview";
import { toastManager } from "~/components/ui/toast";
import { useComposerCommandMenuItems } from "~/hooks/useComposerCommandMenuItems";
import { splitComposerDropzoneFiles, useComposerDropzone } from "~/hooks/useComposerDropzone";
import { useComposerImageIntake } from "~/hooks/useComposerImageIntake";
import { useComposerSlashCommands } from "~/hooks/useComposerSlashCommands";
import { useStableCallback } from "~/hooks/useStableCallback";
import { useTheme } from "~/hooks/useTheme";
import { useTurnDiffSummaries } from "~/hooks/useTurnDiffSummaries";
import { appendAssistantSelectionsToPrompt } from "~/lib/assistantSelections";
import { appendBrowserAnnotationsToPrompt } from "~/lib/browserAnnotations";
import { appendComposerPromptText } from "~/lib/chatReferences";
import { formatComposerMentionToken } from "~/lib/composerMentions";
import { filterPromptProviderMentionReferences, filterPromptSkillReferences } from "~/lib/composerMentions";
import { appendPastedTextsToPrompt, createPastedTextDraft } from "~/lib/composerPastedText";
import {
  buildComposerFileAttachmentsFromFiles,
  effectiveComposerAttachmentCount,
  formatOutgoingComposerPrompt,
} from "~/lib/composerSend";
import {
  deriveComposerContextWindowLabel,
  deriveContextWindowSelectionStatus,
  deriveCumulativeCostUsd,
  deriveLatestContextWindowState,
} from "~/lib/contextWindow";
import { appendFileCommentsToPrompt } from "~/lib/fileComments";
import { findProviderStatus } from "~/lib/providerAvailability";
import { appendPullRequestContextsToPrompt } from "~/lib/pullRequestContext";
import { normalizeRuntimeModeForProvider, providerModelSupportsAutoRuntimeMode } from "~/lib/runtimeMode";
import { IMAGE_ONLY_BOOTSTRAP_PROMPT, appendTerminalContextsToPrompt } from "~/lib/terminalContext";
import { cn, newCommandId, newMessageId, randomUUID } from "~/lib/utils";
import { WorkspaceFileOpenerContext, type WorkspaceFileOpener } from "~/lib/workspaceFileOpener";
import { setPendingUserInputCustomAnswer } from "~/pendingUserInput";
import { buildModelSelection, buildNextProviderOptions } from "~/providerModelOptions";
import {
  deriveActiveWorkStartedAt,
  derivePhase,
  deriveTimelineEntries,
  hasLiveTurnTailWork,
  isLatestTurnSettled,
} from "~/session-logic";
import { useStore } from "~/store";
import { createProjectSelector, createThreadSelector } from "~/storeSelectors";
import { DEFAULT_INTERACTION_MODE, DEFAULT_RUNTIME_MODE, type ChatMessage } from "~/types";

import { emit, request, type ChatContext } from "./bridge";
import { containedPath } from "./filePaths";
import { setRouteThreadId } from "./shims/npm/@tanstack__react-router";
import { hasSnapshot, refreshSnapshot, setStreamThread } from "./threadStream";

const EMPTY_MESSAGES: ChatMessage[] = [];
const EMPTY_ACTIVITIES: never[] = [];
const COMPOSER_EXTRAS_PANEL_ID = "composer-extras-panel";

/** Saves composer images and files through the app; the turn then carries their ids. */
async function saveAttachments(
  threadId: ThreadId,
  attachments: ReadonlyArray<ComposerImageAttachment | ComposerFileAttachment>,
): Promise<Array<ChatImageAttachment | ChatFileAttachment>> {
  const saved: Array<ChatImageAttachment | ChatFileAttachment> = [];
  for (const attachment of attachments) {
    const buffer = await attachment.file.arrayBuffer();
    let binary = "";
    const bytes = new Uint8Array(buffer);
    for (let index = 0; index < bytes.length; index += 0x8000) {
      binary += String.fromCharCode(...bytes.subarray(index, index + 0x8000));
    }
    saved.push(
      await request<ChatImageAttachment | ChatFileAttachment>("attachments.save", {
        threadId,
        type: attachment.type,
        name: attachment.name,
        mimeType: attachment.mimeType,
        dataBase64: btoa(binary),
      }),
    );
  }
  return saved;
}

/**
 * Typed `/fork …` and Codex's `/review …` create another thread (Synara then reads its shell
 * snapshot and navigates to it). This page shows one thread and the backend does not fork, so
 * they are refused before anything is sent, rather than run where their result cannot be seen.
 * Both are left out of the slash menu too (canOfferForkCommand/canOfferReviewCommand). Other
 * providers' `/review` is their own text command and goes through.
 */
function refuseUnservedSlashCommand(prompt: string, provider: string): boolean {
  const match = /^\/(fork|review)(?:\s|$)/i.exec(prompt.trim());
  if (!match) return false;
  const command = match[1]!.toLowerCase();
  if (command === "review" && provider !== "codex") return false;
  toastManager.add({
    type: "warning",
    title: command === "fork" ? "Fork is unavailable" : "Review is unavailable",
    description:
      command === "fork"
        ? "Cascade's chat shows one session; start a new session to branch off."
        : "Ask for a review in a message instead.",
  });
  return true;
}

export function ChatController({ context }: { context: ChatContext }) {
  const threadId = ThreadId.makeUnsafe(context.threadId);
  const readOnly = context.readOnly;

  useEffect(() => {
    setRouteThreadId(threadId);
    setStreamThread(threadId);
    // The app pushes the thread after `ready`; a page that starts without it reads it.
    const timer = window.setTimeout(() => {
      if (!hasSnapshot()) void refreshSnapshot();
    }, 500);
    return () => window.clearTimeout(timer);
  }, [threadId]);

  const { settings } = useAppSettings();
  const assistantDeliveryMode = resolveAssistantDeliveryMode(settings);
  const { resolvedTheme } = useTheme();
  const setComposerDraftModelSelectionAndSticky = useComposerDraftStore(
    (store) => store.setModelSelectionAndSticky,
  );
  const setStoreThreadError = useStore((store) => store.setError);
  const syncServerShellSnapshot = useStore((store) => store.syncServerShellSnapshot);
  const {
    overlayRef: composerOverlayRef,
    overlayHeightPx: composerOverlayHeightPx,
    overlayBottomClearancePx: composerOverlayBottomClearancePx,
  } = useComposerOverlayHeight();
  const composerTranscriptInsetPx = composerTranscriptBottomInsetPx(composerOverlayHeightPx);

  const {
    composerDraft,
    prompt,
    composerImages,
    composerFiles,
    composerAssistantSelections,
    composerBrowserAnnotations,
    composerFileComments,
    composerTerminalContexts,
    composerPastedTexts,
    composerPullRequestContexts,
    composerSkills,
    composerMentions,
    composerSendState,
    nonPersistedComposerImageIds,
    durablyPersistedComposerImageIds,
    setComposerDraftPrompt,
    setComposerDraftPromptHistorySavedDraft,
    restoreComposerDraftPromptHistorySavedDraft,
    setComposerDraftProviderModelOptions,
    setComposerDraftInteractionMode,
    removeComposerDraftFile,
    addComposerDraftPastedTexts,
    setComposerDraftTerminalContexts,
    clearComposerDraftContent,
    promptRef,
    composerCursor,
    setComposerCursor,
    composerTrigger,
    setComposerTrigger,
    composerEditorRef,
    promptHistoryNavigationRef,
    applyingPromptHistoryNavigationRef,
    expectedPromptHistoryPromptRef,
    promptHistoryAppliedPromptRef,
    restoredQueuedSourceProposedPlanRef,
    setRestoredQueuedSourceProposedPlan,
    setPrompt,
    discardPromptHistoryNavigationForComposerMutation,
    addComposerImagesToDraft,
    addComposerFilesToDraft,
    removeComposerImageFromDraft,
    clearComposerAssistantSelectionsFromDraft,
    clearComposerFileCommentsFromDraft,
    removeComposerTerminalContextFromDraft,
    removeComposerPastedTextFromDraft,
    removeComposerPullRequestContextFromDraft,
    removeComposerBrowserAnnotationFromDraft,
    showComposerPastedTextInField,
  } = useChatComposerDraft({ threadId });

  const activeThread = useStore(useMemo(() => createThreadSelector(threadId), [threadId]));
  const activeProject = useStore(
    useMemo(() => createProjectSelector(activeThread?.projectId ?? null), [activeThread?.projectId]),
  );
  const isServerThread = activeThread !== undefined;
  const { expandedImage, setExpandedImage, closeExpandedImage, navigateExpandedImage } =
    useExpandedImagePreview();

  const [composerCommandPicker, setComposerCommandPicker] = useState<null | "fork-target" | "review-target">(null);
  const [isComposerExtrasPanelOpen, setIsComposerExtrasPanelOpen] = useState(false);
  const [composerHighlightedItemId, setComposerHighlightedItemId] = useState<string | null>(null);
  const [isModelPickerOpen, setIsModelPickerOpen] = useState(false);
  const [isContextWindowMeterOpen, setIsContextWindowMeterOpen] = useState(false);
  const [optimisticSendBusy, setOptimisticSendBusy] = useState(false);
  const legendListRef = useRef<LegendListRef | null>(null);
  const timelineControllerRef = useRef<MessagesTimelineController | null>(null);
  const composerFormRef = useRef<HTMLFormElement>(null);
  const pendingComposerFocusRef = useRef(false);
  const composerSelectLockRef = useRef(false);
  const composerMenuOpenRef = useRef(false);
  const composerMenuItemsRef = useRef<ComposerCommandItem[]>([]);
  const activeComposerMenuItemRef = useRef<ComposerCommandItem | null>(null);
  const localDirectoryMenuRef = useRef(null);
  const sendInFlightRef = useRef(false);
  const dragDepthRef = useRef(0);
  const [, setIsDragOverComposer] = useState(false);

  const runtimeMode = composerDraft.runtimeMode ?? activeThread?.runtimeMode ?? DEFAULT_RUNTIME_MODE;
  const interactionMode =
    composerDraft.interactionMode ?? activeThread?.interactionMode ?? DEFAULT_INTERACTION_MODE;
  const activeLatestTurn = activeThread?.latestTurn ?? null;
  const threadActivities = activeThread?.activities ?? EMPTY_ACTIVITIES;
  const hasLiveTurnTail = hasLiveTurnTailWork({
    latestTurn: activeLatestTurn,
    messages: activeThread?.messages ?? EMPTY_MESSAGES,
    activities: threadActivities,
    session: activeThread?.session ?? null,
  });
  const activeContextWindow = useMemo(
    () => deriveLatestContextWindowState(threadActivities).snapshot,
    [threadActivities],
  );
  const activeCumulativeCostUsd = useMemo(() => deriveCumulativeCostUsd(threadActivities), [threadActivities]);
  const latestTurnSettled =
    isLatestTurnSettled(activeLatestTurn, activeThread?.session ?? null) && !hasLiveTurnTail;
  const latestTurnLive = Boolean(activeLatestTurn?.startedAt) && !latestTurnSettled;
  const resolvedThreadWorktreePath = activeThread?.worktreePath ?? null;
  const threadWorkspaceCwd = activeProject
    ? resolveSharedThreadWorkspaceCwd({
        projectCwd: activeProject.cwd,
        envMode: activeThread?.envMode ?? null,
        worktreePath: resolvedThreadWorktreePath,
        workingDirectory: activeThread?.workingDirectory ?? null,
      })
    : (context.cwd ?? null);

  const {
    lockedProvider,
    boundProvider,
    boundProviderInstanceId,
    serverConfigQuery,
    selectedProvider,
    providerInstances,
    selectedProviderInstanceId,
    providerModelDiscoveryCwd,
    customModelsByProvider,
    modelOptionsByProvider,
    modelOptionsByProviderInstance,
    loadingModelProviders,
    refreshModels,
    discoveryErrorsByProvider,
    runtimeModelsByProvider,
    runtimeModelsByProviderInstance,
    dynamicAgents,
    composerModelOptions,
    selectedModel,
    selectedRuntimeModel,
    composerProviderState,
    selectedPromptEffort,
    selectedModelSelection,
    providerOptionsForDispatch,
    selectedModelForPickerWithCustomFallback,
    searchableModelOptions,
  } = useChatProviderModels({
    threadId,
    activeThread,
    activeProject,
    composerDraft,
    settings,
    resolvedThreadWorktreePath,
    allowProviderHandoff: false,
  });
  const {
    selectedComposerSkillsRef,
    selectedComposerMentionsRef,
    selectedComposerSkills,
    selectedComposerMentions,
    updateSelectedComposerSkills,
    updateSelectedComposerMentions,
  } = useComposerReferences({ threadId, selectedProvider, prompt, composerSkills, composerMentions });

  const phase = derivePhase(activeThread?.session ?? null);
  const isConnecting = phase === "connecting";
  const hasLiveTurn = phase === "running";
  const { workLogEntries } = useChatWorkLog({ activeThread, latestTurnSettled, latestTurnLive });
  const [openAgentActivityId, setOpenAgentActivityId] = useState<string | null>(null);
  const agentActivityTimelineState = useMemo(
    () => deriveAgentActivityTimelineState(workLogEntries),
    [workLogEntries],
  );
  const openAgentActivityDetail = openAgentActivityId
    ? (agentActivityTimelineState.detailById.get(openAgentActivityId) ?? null)
    : null;

  const {
    respondingRequestKeys,
    pendingApprovals,
    pendingUserInputs,
    pendingUserInputAnswersByRequestIdRef,
    setPendingUserInputAnswersByRequestId,
    activePendingUserInput,
    activePendingUserInputKey,
    activePendingDraftAnswers,
    activePendingQuestionIndex,
    activePendingProgress,
    activePendingQuestion,
    activePendingResolvedAnswers,
    activePendingIsResponding,
    activePendingApproval,
    onRespondToApproval,
    userInputSubmissionVersion,
    onCancelActivePendingUserInput,
    onToggleActivePendingUserInputOption,
    onChangeActivePendingUserInputCustomAnswer,
    onAdvanceActivePendingUserInput,
    onPreviousActivePendingUserInputQuestion,
  } = useChatPendingInteractions({
    threadId,
    activeThread,
    runtimeMode,
    promptRef,
    setPrompt,
    setComposerCursor,
    setComposerTrigger,
    setComposerHighlightedItemId,
  });

  const { timelineMessages, optimisticUserMessages, setOptimisticUserMessages } = useChatTimelineMessages({
    threadId,
    activeThread,
    pendingAutomationConversation: null,
  });
  const promptHistory = useMemo(
    () => derivePromptHistoryFromMessages(activeThread?.messages ?? EMPTY_MESSAGES),
    [activeThread?.messages],
  );
  const timelineEntries = useMemo(
    () =>
      deriveTimelineEntries(
        timelineMessages,
        activeThread?.proposedPlans ?? [],
        agentActivityTimelineState.timelineWorkEntries,
        { suppressCoordinatorCheckins: false },
      ),
    [activeThread?.proposedPlans, agentActivityTimelineState.timelineWorkEntries, timelineMessages],
  );
  const enteringUserMessageIds = useMemo<ReadonlySet<MessageId>>(
    () => new Set(optimisticUserMessages.map((message) => message.id)),
    [optimisticUserMessages],
  );

  const isWorking = hasLiveTurn || optimisticSendBusy || isConnecting;
  const hasStreamingAssistantText =
    activeThread?.messages.some((message) => message.role === "assistant" && message.streaming) ?? false;
  const activeWorkStartedAt = hasLiveTurnTail
    ? (activeLatestTurn?.startedAt ?? null)
    : hasLiveTurn
      ? deriveActiveWorkStartedAt(activeLatestTurn, activeThread?.session ?? null, null)
      : null;
  const activeTurnInProgress = isWorking || !latestTurnSettled;
  const isComposerApprovalState = activePendingApproval !== null;
  const isComposerEditorDisabled = isConnecting || isComposerApprovalState;
  const canCollapsePastedTextToDraft = shouldEnableComposerPastedTextCollapse({
    isComposerApprovalState,
    hasPendingUserInput: pendingUserInputs.length > 0,
    showPlanFollowUpPrompt: false,
  });

  const { turnDiffSummaries, inferredCheckpointTurnCountByTurnId } = useTurnDiffSummaries(activeThread);
  const turnDiffSummaryByAssistantMessageId = useMemo(
    () =>
      buildTurnDiffSummaryByAssistantMessageId({
        turnDiffSummaries: turnDiffSummaries.map((summary) => ({
          ...summary,
          checkpointTurnCount:
            summary.checkpointTurnCount ?? inferredCheckpointTurnCountByTurnId[summary.turnId],
        })),
        messages: timelineMessages.map((message) => ({
          id: message.id,
          role: message.role,
          turnId: message.turnId ?? null,
        })),
      }),
    [inferredCheckpointTurnCountByTurnId, turnDiffSummaries, timelineMessages],
  );
  const revertTurnCountByUserMessageId = useMemo(() => new Map<MessageId, number>(), []);

  const setThreadError = useCallback(
    (targetThreadId: ThreadId | null, error: string | null) => {
      if (targetThreadId) setStoreThreadError(targetThreadId, error);
    },
    [setStoreThreadError],
  );

  // --- focus ---------------------------------------------------------------------------
  const focusComposer = useCallback(() => {
    const editor = composerEditorRef.current;
    if (
      !editor ||
      !canApplyComposerFocus({
        windowHasFocus: document.hasFocus(),
        editorAvailable: true,
        editorDisabled: isComposerEditorDisabled,
      })
    ) {
      pendingComposerFocusRef.current = true;
      return;
    }
    pendingComposerFocusRef.current = false;
    editor.focusAtEnd();
  }, [composerEditorRef, isComposerEditorDisabled]);
  const scheduleComposerFocus = useCallback(() => {
    pendingComposerFocusRef.current = true;
    window.requestAnimationFrame(() => focusComposer());
  }, [focusComposer]);

  // --- provider status, runtime modes ----------------------------------------------------
  const { providerStatuses } = useChatProviderStatus({
    activeThread,
    settings,
    configuredProviderStatuses: serverConfigQuery.data?.providers,
  });
  const activeProviderStatus = useMemo(
    () => findProviderStatus(providerStatuses, selectedProvider, selectedProviderInstanceId),
    [selectedProvider, selectedProviderInstanceId, providerStatuses],
  );
  const { persistRuntimeModeChange, handleRuntimeModeChange, handleInteractionModeChange, resetInteractionMode } =
    useChatRuntimeModes({
      threadId,
      activeThread,
      serverThread: activeThread,
      isLocalDraftThread: false,
      runtimeMode,
      interactionMode,
      selectedProvider,
      selectedRuntimeModel,
      selectedModelSelection,
      activeProviderStatus,
      scheduleComposerFocus,
    });

  // --- attachments ---------------------------------------------------------------------
  const commitPreparedComposerImages = useCallback(
    (images: ComposerImageAttachment[]) => addComposerImagesToDraft(images),
    [addComposerImagesToDraft],
  );
  const setComposerImagePreparationError = useCallback(
    (error: string | null) => setThreadError(threadId, error),
    [setThreadError, threadId],
  );
  const composerImageAttachmentCount = useCallback(
    () => effectiveComposerAttachmentCount(useComposerDraftStore.getState().draftsByThreadId[threadId]),
    [threadId],
  );
  const {
    addImages: enqueueComposerImages,
    isPreparingImages: isPreparingComposerImages,
    pendingImageCount: pendingComposerImageCount,
    waitForPending: waitForPendingComposerImages,
  } = useComposerImageIntake({
    threadId,
    existingAttachmentCount: composerImageAttachmentCount,
    commitImages: commitPreparedComposerImages,
    onError: setComposerImagePreparationError,
  });
  const addComposerImages = useCallback(
    (files: readonly File[]) => {
      if (files.length === 0) return;
      if (pendingUserInputs.length > 0) {
        toastManager.add({ type: "error", title: "Attach images after answering plan questions." });
        return;
      }
      enqueueComposerImages(files);
    },
    [enqueueComposerImages, pendingUserInputs.length],
  );
  const addComposerFiles = useCallback(
    (files: readonly File[]) => {
      if (files.length === 0) return;
      if (pendingUserInputs.length > 0) {
        toastManager.add({ type: "error", title: "Attach files after answering plan questions." });
        return;
      }
      const { files: nextFiles, error } = buildComposerFileAttachmentsFromFiles({
        files,
        existingAttachmentCount: effectiveComposerAttachmentCount(
          useComposerDraftStore.getState().draftsByThreadId[threadId],
        ),
      });
      const insertedCount = nextFiles.length > 0 ? addComposerFilesToDraft(nextFiles) : 0;
      setThreadError(
        threadId,
        insertedCount < nextFiles.length
          ? `You can attach up to ${PROVIDER_SEND_TURN_MAX_ATTACHMENTS} references per message.`
          : error,
      );
    },
    [addComposerFilesToDraft, pendingUserInputs.length, setThreadError, threadId],
  );
  const addComposerAttachments = useCallback(
    (files: readonly File[]) => {
      const { imageFiles, genericFiles } = splitComposerDropzoneFiles(files);
      if (imageFiles.length > 0) addComposerImages(imageFiles);
      if (genericFiles.length > 0) addComposerFiles(genericFiles);
    },
    [addComposerFiles, addComposerImages],
  );
  const removeComposerFile = (fileId: string) => {
    discardPromptHistoryNavigationForComposerMutation();
    removeComposerDraftFile(threadId, fileId);
  };
  const { onComposerPaste, onComposerDragEnter, onComposerDragOver, onComposerDragLeave, onComposerDrop } =
    useComposerDropzone({
      disabled: false,
      addImages: addComposerImages,
      fileSupport: { genericFiles: "accept", addFiles: addComposerFiles },
      appendReferenceText: (referenceText) => appendComposerPromptText(threadId, referenceText),
      appendPathMentions: (paths) => {
        for (const absolutePath of paths) {
          appendComposerPromptText(threadId, formatComposerMentionToken(absolutePath));
        }
      },
      dragDepthRef,
      focusComposer,
      setIsDragOverComposer,
    });
  const addPastedTextToDraft = useCallback(
    (text: string) => {
      discardPromptHistoryNavigationForComposerMutation();
      addComposerDraftPastedTexts(threadId, [
        createPastedTextDraft({ id: randomUUID(), createdAt: new Date().toISOString(), text }),
      ]);
    },
    [addComposerDraftPastedTexts, discardPromptHistoryNavigationForComposerMutation, threadId],
  );

  // --- discovery and the slash / mention menu -------------------------------------------
  const {
    isLocalFolderBrowserOpen,
    providerPlugins,
    providerNativeCommands,
    providerArtifacts,
    providerSkills,
    workspaceEntries,
    effectiveComposerTrigger,
    effectiveComposerTriggerKind,
    supportsTextNativeReviewCommand,
    isComposerMenuLoading,
    canCompactThread,
  } = useComposerDiscovery({
    threadId,
    selectedProvider,
    selectedProviderInstanceId,
    composerTrigger,
    composerCommandPicker,
    providerModelDiscoveryCwd,
    providerOptionsForDispatch,
    gitCwd: threadWorkspaceCwd,
    piAgentDir: settings.piAgentDir,
    ompAgentDir: settings.ompAgentDir,
    discoverNativeCompaction:
      selectedProvider === "claudeAgent" && (isContextWindowMeterOpen || activeThread?.claudeCacheReview != null),
  });
  const selectedModelCaps = composerTraitCapsOf(selectedProvider, selectedModel);
  const supportsFastSlashCommand = selectedModelCaps.supportsFastMode;
  const currentProviderModelOptions = composerModelOptions?.[selectedProvider];
  const fastModeEnabled =
    supportsFastSlashCommand &&
    (currentProviderModelOptions as { fastMode?: boolean } | undefined)?.fastMode === true;
  const canOfferCompactCommand =
    canCompactThread &&
    isServerThread &&
    activeThread?.session !== null &&
    activeThread?.session?.status !== "closed";
  const composerThreadSummaries = useMemo(() => [], []);
  const composerThreadProjects = useStore((state) => state.projects);
  const composerMenuItems = useComposerCommandMenuItems({
    composerTrigger: effectiveComposerTrigger,
    provider: selectedProvider,
    providerPlugins,
    providerNativeCommands,
    providerSkills,
    workspaceEntries,
    searchableModelOptions,
    supportsFastSlashCommand,
    canOfferCompactCommand,
    canOfferReviewCommand: false,
    canOfferForkCommand: false,
    canOfferSideCommand: false,
    canOfferExportCommand: false,
    providerArtifacts,
    dynamicAgents,
    threadMentionSources: {
      threads: composerThreadSummaries,
      projects: composerThreadProjects,
      currentThreadId: threadId,
    },
  });
  const composerMenuOpen = Boolean(composerTrigger || composerCommandPicker);
  const composerExtrasPanelOpen = isComposerExtrasPanelOpen && !composerMenuOpen;
  const composerOverlayOpen = composerMenuOpen || composerExtrasPanelOpen;
  const activeComposerMenuItem = useMemo(
    () => composerMenuItems.find((item) => item.id === composerHighlightedItemId) ?? composerMenuItems[0] ?? null,
    [composerHighlightedItemId, composerMenuItems],
  );
  useLayoutEffect(() => {
    composerMenuOpenRef.current = composerMenuOpen;
    composerMenuItemsRef.current = composerMenuItems;
    activeComposerMenuItemRef.current = activeComposerMenuItem;
  }, [composerMenuOpen, composerMenuItems, activeComposerMenuItem]);
  const nonPersistedComposerImageIdSet = useMemo(() => {
    const durableBlobIds = new Set(
      durablyPersistedComposerImageIds.filter((attachment) => Boolean(attachment.blobKey)).map((a) => a.id),
    );
    return new Set(nonPersistedComposerImageIds.filter((id) => !durableBlobIds.has(id)));
  }, [durablyPersistedComposerImageIds, nonPersistedComposerImageIds]);

  // --- model selection -----------------------------------------------------------------
  const onProviderModelSelect = useCallback(
    async (provider: ProviderKind, model: ModelSlug, selectionOptions?: ComposerModelSelectionOptions) => {
      if (!activeThread) return;
      if (lockedProvider !== null && provider !== lockedProvider) {
        scheduleComposerFocus();
        return;
      }
      const resolvedInstanceId = selectionOptions?.instanceId ?? resolveDefaultProviderInstanceId(settings, provider);
      const instanceLockedProvider = lockedProvider ?? boundProvider;
      const lockedInstanceId =
        instanceLockedProvider !== null && provider === instanceLockedProvider
          ? (activeThread.session?.providerInstanceId ?? activeThread.modelSelection.instanceId ?? selectedProviderInstanceId)
          : undefined;
      if (lockedInstanceId && resolvedInstanceId !== lockedInstanceId) {
        scheduleComposerFocus();
        return;
      }
      const resolvedModel = resolveCommittedProviderModel({
        selectedModel: model,
        availableOptions: modelOptionsByProviderInstance[resolvedInstanceId] ?? modelOptionsByProvider[provider],
        fallback: () => resolveAppModelSelection(provider, customModelsByProvider, model),
      });
      const runtimeModel = resolveRuntimeModelDescriptor({
        provider,
        model: resolvedModel,
        runtimeModels: runtimeModelsByProviderInstance[resolvedInstanceId] ?? runtimeModelsByProvider[provider],
      });
      const nextModelSelection = buildModelSelection(
        provider,
        resolvedModel,
        selectionOptions?.modelOptions,
        provider === "claudeAgent" ? runtimeModel?.supportsAutoMode : undefined,
        { instanceId: resolvedInstanceId },
      );
      const providerStatus = findProviderStatus(providerStatuses, provider, resolvedInstanceId);
      const nextRuntimeMode =
        runtimeMode === "auto" && !providerModelSupportsAutoRuntimeMode(provider, runtimeModel, providerStatus)
          ? "approval-required"
          : normalizeRuntimeModeForProvider(runtimeMode, provider);
      await commitAfterRuntimeModePersistence({
        currentRuntimeMode: runtimeMode,
        nextRuntimeMode,
        persistRuntimeMode: persistRuntimeModeChange,
        commit: () => {
          setComposerDraftModelSelectionAndSticky(activeThread.id, nextModelSelection);
        },
      });
      scheduleComposerFocus();
    },
    [
      activeThread,
      boundProvider,
      customModelsByProvider,
      lockedProvider,
      modelOptionsByProvider,
      modelOptionsByProviderInstance,
      persistRuntimeModeChange,
      providerStatuses,
      runtimeMode,
      runtimeModelsByProvider,
      runtimeModelsByProviderInstance,
      scheduleComposerFocus,
      selectedProviderInstanceId,
      setComposerDraftModelSelectionAndSticky,
      settings,
    ],
  );

  // --- editing, slash commands, menu commands -------------------------------------------
  const {
    applyPromptReplacement,
    resolveActiveComposerTrigger,
    applyComposerTriggerReplacement,
    handleNavigateLocalFolder,
    setComposerPromptValue,
    clearComposerSlashDraft,
  } = useChatComposerEditing({
    threadId,
    promptRef,
    activePendingProgress,
    activePendingUserInputKey,
    pendingUserInputAnswersByRequestIdRef,
    setPendingUserInputAnswersByRequestId,
    setPrompt,
    setComposerCursor,
    setComposerTrigger,
    composerEditorRef,
    composerCursor,
    composerTerminalContexts,
    setComposerHighlightedItemId,
    setRestoredQueuedSourceProposedPlan,
    clearComposerDraftContent,
    scheduleComposerFocus,
  });
  const slashEditorActions = useMemo(
    () => ({
      resolveActiveComposerTrigger,
      applyPromptReplacement,
      clearComposerSlashDraft,
      setComposerPromptValue,
      scheduleComposerFocus,
      setComposerHighlightedItemId,
    }),
    [applyPromptReplacement, clearComposerSlashDraft, resolveActiveComposerTrigger, scheduleComposerFocus, setComposerPromptValue],
  );
  const { handleForkTargetSelection, handleReviewTargetSelection, handleStandaloneSlashCommand, handleSlashCommandSelection } =
    useComposerSlashCommands({
      activeProject,
      activeThread,
      activeRootBranch: null,
      isServerThread,
      isLocalDraftThread: false,
      supportsFastSlashCommand,
      canOfferCompactCommand,
      canExecuteSideCommand: false,
      sidechatTargetProviders: [],
      canOfferExportCommand: false,
      supportsTextNativeReviewCommand,
      fastModeEnabled,
      providerNativeCommands,
      providerCommandDiscoveryCwd: providerModelDiscoveryCwd,
      selectedProvider,
      currentProviderModelOptions,
      selectedModelSelection,
      environmentMode: activeThread?.envMode ?? null,
      runtimeMode,
      interactionMode,
      threadId,
      syncServerShellSnapshot,
      navigateToThread: async () => undefined,
      handleClearConversation: () => {
        toastManager.add({ type: "warning", title: "Clear is unavailable", description: "Start a new session instead." });
      },
      handleInteractionModeChange,
      openForkTargetPicker: () => undefined,
      openReviewTargetPicker: () => undefined,
      setComposerDraftProviderModelOptions,
      editorActions: slashEditorActions,
    });

  // --- send ----------------------------------------------------------------------------
  const turnDispatchSettings = useMemo<TurnDispatchSettings>(
    () => ({
      modelSelection: selectedModelSelection,
      providerOptions: providerOptionsForDispatch,
      enableComputerControl: false,
      computerControlMode: "off",
      computerControlGeneration: 0,
      assistantDeliveryMode,
      runtimeMode,
      interactionMode,
      envMode: activeThread?.envMode ?? "local",
    }),
    [activeThread?.envMode, assistantDeliveryMode, interactionMode, providerOptionsForDispatch, runtimeMode, selectedModelSelection],
  );

  const onSend = useCallback(
    async (event?: { preventDefault: () => void }, requestedDispatchMode?: "queue" | "steer"): Promise<boolean> => {
      event?.preventDefault();
      if (readOnly || !activeThread || sendInFlightRef.current || isConnecting) return false;
      if (activeThread.claudeCacheReview != null) return false;
      const dispatchMode =
        requestedDispatchMode ?? resolveFollowUpDispatchMode({ behavior: settings.followUpBehavior, hasLiveTurn });
      await waitForPendingComposerImages();
      if (activePendingProgress) {
        const activeQuestion = activePendingProgress.activeQuestion;
        const liveText = composerEditorRef.current?.readSnapshot()?.value ?? promptRef.current;
        const currentDraftAnswer =
          activePendingUserInputKey && activeQuestion
            ? pendingUserInputAnswersByRequestIdRef.current[activePendingUserInputKey]?.[activeQuestion.id]
            : undefined;
        const answerOverrides =
          activeQuestion && liveText.trim().length > 0
            ? { [activeQuestion.id]: setPendingUserInputCustomAnswer(currentDraftAnswer, liveText) }
            : undefined;
        if (activePendingUserInputKey && answerOverrides) {
          const next = {
            ...pendingUserInputAnswersByRequestIdRef.current[activePendingUserInputKey],
            ...answerOverrides,
          };
          pendingUserInputAnswersByRequestIdRef.current = {
            ...pendingUserInputAnswersByRequestIdRef.current,
            [activePendingUserInputKey]: next,
          };
          setPendingUserInputAnswersByRequestId((existing) => ({ ...existing, [activePendingUserInputKey]: next }));
        }
        return onAdvanceActivePendingUserInput(answerOverrides);
      }

      const promptForSend = composerEditorRef.current?.readSnapshot()?.value ?? promptRef.current;
      const draft = useComposerDraftStore.getState().draftsByThreadId[activeThread.id];
      const imagesForSend = draft?.images ?? composerImages;
      const filesForSend = composerFiles;
      const sendState = deriveComposerSendState({
        prompt: promptForSend,
        imageCount: imagesForSend.length,
        fileCount: filesForSend.length,
        assistantSelectionCount: composerAssistantSelections.length,
        browserAnnotationCount: composerBrowserAnnotations.length,
        fileCommentCount: composerFileComments.length,
        terminalContexts: composerTerminalContexts,
        pastedTexts: composerPastedTexts,
        pullRequestContexts: composerPullRequestContexts,
      });
      const hasNoStructuredContext =
        imagesForSend.length === 0 &&
        filesForSend.length === 0 &&
        composerAssistantSelections.length === 0 &&
        composerBrowserAnnotations.length === 0 &&
        composerFileComments.length === 0 &&
        sendState.sendableTerminalContexts.length === 0 &&
        sendState.sendablePastedTexts.length === 0 &&
        selectedComposerMentionsRef.current.length === 0;
      if (hasNoStructuredContext && refuseUnservedSlashCommand(sendState.trimmedPrompt, selectedProvider)) {
        clearComposerSlashDraft();
        return true;
      }
      if (hasNoStructuredContext && (await handleStandaloneSlashCommand(sendState.trimmedPrompt))) return true;
      if (!sendState.hasSendableContent) return false;

      const messageId = newMessageId();
      const messageText = appendBrowserAnnotationsToPrompt(
        appendPullRequestContextsToPrompt(
          appendPastedTextsToPrompt(
            appendFileCommentsToPrompt(
              appendTerminalContextsToPrompt(
                appendAssistantSelectionsToPrompt(promptForSend, composerAssistantSelections),
                composerTerminalContexts,
              ),
              composerFileComments,
            ),
            composerPastedTexts,
          ),
          composerPullRequestContexts,
        ),
        composerBrowserAnnotations,
        messageId,
      );
      const createdAt = new Date().toISOString();
      const outgoingText = formatOutgoingComposerPrompt({
        provider: selectedProvider,
        model: selectedModel,
        effort: selectedPromptEffort,
        text: messageText || (imagesForSend.length > 0 ? IMAGE_ONLY_BOOTSTRAP_PROMPT : ""),
      });
      const skills = filterPromptSkillReferences(outgoingText, selectedComposerSkillsRef.current, selectedProvider);
      const mentions = filterPromptProviderMentionReferences(outgoingText, selectedComposerMentionsRef.current);
      const computerMode = resolveComputerInvocationMode({ messageText: outgoingText, enableComputerControl: false });
      const dispatchSettings = { ...turnDispatchSettings, computerControlMode: computerMode };

      sendInFlightRef.current = true;
      setOptimisticSendBusy(true);
      setOptimisticUserMessages((existing) => [
        ...existing,
        {
          id: messageId,
          role: "user",
          text: outgoingText,
          dispatchMode,
          ...(imagesForSend.length + filesForSend.length > 0
            ? {
                attachments: [
                  ...imagesForSend.map((image) => ({
                    type: "image" as const,
                    id: image.id,
                    name: image.name,
                    mimeType: image.mimeType,
                    sizeBytes: image.sizeBytes,
                    previewUrl: image.previewUrl,
                  })),
                  ...filesForSend.map((file) => ({
                    type: "file" as const,
                    id: file.id,
                    name: file.name,
                    mimeType: file.mimeType,
                    sizeBytes: file.sizeBytes,
                  })),
                ],
              }
            : {}),
          ...(skills.length > 0 ? { skills } : {}),
          ...(mentions.length > 0 ? { mentions } : {}),
          createdAt,
          streaming: false,
          source: "native",
        } as ChatMessage,
      ]);
      setThreadError(activeThread.id, null);
      promptHistoryNavigationRef.current = null;
      applyingPromptHistoryNavigationRef.current = false;
      expectedPromptHistoryPromptRef.current = null;
      promptRef.current = "";
      clearComposerDraftContent(activeThread.id, { preservePreviewUrls: true });
      setComposerHighlightedItemId(null);
      setComposerCursor(0);
      setComposerTrigger(null);
      scheduleComposerFocus();
      try {
        const attachments: UploadChatAttachment[] = [
          ...composerAssistantSelections.map((selection) => ({
            type: "assistant-selection" as const,
            assistantMessageId: MessageId.makeUnsafe(selection.assistantMessageId),
            text: selection.text,
          })),
          ...(await saveAttachments(activeThread.id, [...imagesForSend, ...filesForSend])),
        ];
        await request("orchestration.dispatchCommand", {
          command: {
            type: "thread.turn.start",
            commandId: newCommandId(),
            threadId: activeThread.id,
            message: {
              messageId,
              role: "user",
              text: outgoingText,
              attachments,
              ...(skills.length > 0 ? { skills } : {}),
              ...(mentions.length > 0 ? { mentions } : {}),
            },
            ...turnStartDispatchFields(dispatchSettings, dispatchMode),
            createdAt,
          },
        });
        return true;
      } catch (error) {
        // The message goes back into the composer, as Synara's failed send does.
        setOptimisticUserMessages((existing) => existing.filter((message) => message.id !== messageId));
        promptRef.current = promptForSend;
        setComposerDraftPrompt(activeThread.id, promptForSend);
        setThreadError(activeThread.id, error instanceof Error ? error.message : "The message could not be sent.");
        return false;
      } finally {
        sendInFlightRef.current = false;
        setOptimisticSendBusy(false);
      }
    },
    [
      activePendingProgress,
      activePendingUserInputKey,
      activeThread,
      applyingPromptHistoryNavigationRef,
      clearComposerDraftContent,
      clearComposerSlashDraft,
      composerAssistantSelections,
      composerBrowserAnnotations,
      composerEditorRef,
      composerFileComments,
      composerFiles,
      composerImages,
      composerPastedTexts,
      composerPullRequestContexts,
      composerTerminalContexts,
      expectedPromptHistoryPromptRef,
      handleStandaloneSlashCommand,
      hasLiveTurn,
      isConnecting,
      onAdvanceActivePendingUserInput,
      pendingUserInputAnswersByRequestIdRef,
      promptHistoryNavigationRef,
      promptRef,
      readOnly,
      scheduleComposerFocus,
      selectedComposerMentionsRef,
      selectedComposerSkillsRef,
      selectedModel,
      selectedPromptEffort,
      selectedProvider,
      setComposerCursor,
      setComposerDraftPrompt,
      setComposerTrigger,
      setOptimisticUserMessages,
      setPendingUserInputAnswersByRequestId,
      setThreadError,
      settings.followUpBehavior,
      turnDispatchSettings,
      waitForPendingComposerImages,
    ],
  );

  const { onSelectComposerItem, onComposerMenuItemHighlighted, onPromptChange, onComposerCommandKey } =
    useChatComposerCommands({
      threadId,
      composerSelectLockRef,
      setComposerCommandPicker,
      setComposerHighlightedItemId,
      handleForkTargetSelection,
      handleReviewTargetSelection,
      resolveActiveComposerTrigger,
      applyComposerTriggerReplacement,
      handleNavigateLocalFolder,
      localFolderBrowseRootPath: null,
      handleSlashCommandSelection,
      selectedProvider,
      scheduleComposerFocus,
      updateSelectedComposerSkills,
      updateSelectedComposerMentions,
      onProviderModelSelect,
      composerMenuItems,
      composerHighlightedItemId,
      activePendingQuestion,
      activePendingUserInput,
      promptHistoryNavigationRef,
      restoreComposerDraftPromptHistorySavedDraft,
      promptRef,
      setPrompt,
      expectedPromptHistoryPromptRef,
      onChangeActivePendingUserInputCustomAnswer,
      setComposerDraftPromptHistorySavedDraft,
      applyingPromptHistoryNavigationRef,
      promptHistory,
      promptHistoryAppliedPromptRef,
      restoredQueuedSourceProposedPlanRef,
      setRestoredQueuedSourceProposedPlan,
      composerCommandPicker,
      composerTerminalContexts,
      setComposerDraftTerminalContexts,
      setComposerCursor,
      setComposerTrigger,
      clearComposerSlashDraft,
      composerMenuOpenRef,
      onSend,
      settings,
      hasLiveTurn,
      isLocalFolderBrowserOpen,
      localDirectoryMenuRef,
      composerMenuItemsRef,
      activeComposerMenuItemRef,
      activePendingProgress,
      isComposerApprovalState,
      pendingUserInputs,
      composerDraft,
    });

  const onInterrupt = useCallback(() => {
    if (!activeThread) return;
    void request("orchestration.dispatchCommand", {
      command: {
        type: "thread.turn.interrupt",
        commandId: newCommandId(),
        threadId: activeThread.id,
        createdAt: new Date().toISOString(),
      },
    }).catch((error: unknown) => {
      toastManager.add({
        type: "error",
        title: "Could not stop the current response",
        description: error instanceof Error ? error.message : "The interrupt request failed. Try again in a moment.",
      });
    });
  }, [activeThread]);

  const setPromptFromTraits = useCallback(
    (nextPrompt: string) => {
      if (nextPrompt === promptRef.current) {
        scheduleComposerFocus();
        return;
      }
      promptRef.current = nextPrompt;
      setPrompt(nextPrompt);
      setComposerCursor(collapseExpandedComposerCursor(nextPrompt, nextPrompt.length));
      setComposerTrigger(detectComposerTrigger(nextPrompt, nextPrompt.length));
      scheduleComposerFocus();
    },
    [promptRef, scheduleComposerFocus, setComposerCursor, setComposerTrigger, setPrompt],
  );
  const toggleFastMode = useCallback(() => {
    const selection = getComposerTraitSelection(selectedProvider, selectedModel, prompt, currentProviderModelOptions);
    if (!selection.caps.supportsFastMode) {
      scheduleComposerFocus();
      return;
    }
    setComposerDraftProviderModelOptions(
      threadId,
      selectedProvider,
      buildNextProviderOptions(selectedProvider, currentProviderModelOptions, {
        fastMode: !selection.fastModeEnabled,
      }),
      { instanceId: selectedProviderInstanceId, persistSticky: true },
    );
    scheduleComposerFocus();
  }, [
    currentProviderModelOptions,
    prompt,
    scheduleComposerFocus,
    selectedModel,
    selectedProvider,
    selectedProviderInstanceId,
    setComposerDraftProviderModelOptions,
    threadId,
  ]);

  // --- transcript scroll ---------------------------------------------------------------
  const {
    showScrollToBottom,
    isUserScrollDetached,
    onTranscriptNavigate,
    onIsAtEndChange,
    onScrollToBottom,
    onMessagesClickCaptureBase,
    onMessagesPointerDownBase,
    onMessagesPointerUpBase,
    onMessagesPointerCancelBase,
    onMessagesScrollBase,
    onMessagesTouchEndBase,
    onMessagesTouchMoveBase,
    onMessagesTouchStartBase,
    onMessagesWheelBase,
  } = useChatTranscriptScroll({
    activeThreadId: activeThread?.id ?? null,
    legendListRef,
    timelineEntries,
    hasStreamingAssistantText,
    composerTranscriptInsetPx,
    isInactiveSplitPane: false,
  });

  const fileOpener = useMemo<WorkspaceFileOpener>(
    () => ({
      openFile: (path) => {
        const match = /^(.*?):(\d+)(?::\d+)?$/.exec(path);
        const file = containedPath(match ? match[1]! : path, context);
        // A file outside the workspace and the home folder is not handed to the app.
        if (!file) return false;
        emit("openFile", match ? { path: file, line: Number(match[2]) } : { path: file });
        return true;
      },
    }),
    [context],
  );

  const handlePromptChange = useStableCallback(onPromptChange);
  const handleComposerCommandKey = useStableCallback(onComposerCommandKey);
  const handleComposerPaste = useStableCallback(onComposerPaste);
  const handleCollapsePastedText = useStableCallback(addPastedTextToDraft);
  const handleProviderModelChange = useStableCallback(onProviderModelSelect);

  if (!activeThread) {
    return (
      <div className="flex h-full items-center justify-center text-ui text-muted-foreground" data-chat-loading="">
        <LoaderCircleIcon className="size-4 animate-spin" />
      </div>
    );
  }

  const composerTraitSelection = getComposerTraitSelection(
    selectedProvider,
    selectedModel,
    prompt,
    currentProviderModelOptions,
  );
  const contextWindowSelectionStatus = deriveContextWindowSelectionStatus({
    activeSnapshot: activeContextWindow,
    selectedValue: selectedProvider === "claudeAgent" ? composerTraitSelection.contextWindow : null,
  });
  const composerContextWindowLabel = deriveComposerContextWindowLabel({
    provider: selectedProvider,
    model: selectedModel,
    snapshot: activeContextWindow,
    status: contextWindowSelectionStatus,
  });
  const composerFooterControlsPlan = composerFooterPlanForTier(0, Boolean(activeContextWindow));

  const transcript = (
    <ChatTranscriptPane
      activeThreadId={activeThread.id}
      activeTurnId={activeThread.session?.activeTurnId ?? activeLatestTurn?.turnId ?? null}
      agentActivityDetail={openAgentActivityDetail}
      hasMessages={timelineEntries.length > 0}
      isWorking={isWorking}
      workingLabel={resolveWorkingLabel({
        isSettlingTurnDispatch: false,
        isSendBusy: optimisticSendBusy,
        turnTakenOver: false,
        isConnecting,
        providerName: PROVIDER_DISPLAY_NAMES[activeThread.session?.provider ?? selectedProvider],
      })}
      worktreeSetup={null}
      activeTurnInProgress={activeTurnInProgress}
      collapseFinishedTurns={settings.collapseFinishedTurns}
      activeTurnStartedAt={activeWorkStartedAt}
      listRef={legendListRef}
      timelineControllerRef={timelineControllerRef}
      enteringUserMessageIds={enteringUserMessageIds}
      timelineEntries={timelineEntries}
      messageChangeSignal={timelineMessages}
      turnDiffSummaryByAssistantMessageId={turnDiffSummaryByAssistantMessageId}
      threadError={activeThread.error ?? null}
      onDismissThreadError={() => setThreadError(activeThread.id, null)}
      onOpenTurnDiff={(turnId, filePath) =>
        emit("openTurnDiff", { threadId: activeThread.id, turnId, ...(filePath ? { filePath } : {}) })
      }
      onOpenThread={() => undefined}
      revertTurnCountByUserMessageId={revertTurnCountByUserMessageId}
      onRevertUserMessage={() => undefined}
      isRevertingCheckpoint={false}
      onExpandTimelineImage={setExpandedImage}
      followLiveOutput={hasStreamingAssistantText && !isUserScrollDetached}
      onIsAtEndChange={onIsAtEndChange}
      onNavigate={onTranscriptNavigate}
      markdownCwd={threadWorkspaceCwd ?? undefined}
      resolvedTheme={resolvedTheme}
      chatFontSizePx={context.chatFontSizePx ?? settings.chatFontSizePx}
      timestampFormat={settings.timestampFormat}
      workspaceRoot={threadWorkspaceCwd ?? undefined}
      emptyStateProjectName={activeProject?.name ?? context.projectName}
      terminalWorkspaceTerminalTabActive={false}
      onMessagesScroll={onMessagesScrollBase}
      onMessagesClickCapture={onMessagesClickCaptureBase}
      onMessagesMouseUp={() => undefined}
      onMessagesWheel={onMessagesWheelBase}
      onMessagesPointerDown={onMessagesPointerDownBase}
      onMessagesPointerUp={onMessagesPointerUpBase}
      onMessagesPointerCancel={onMessagesPointerCancelBase}
      onMessagesTouchStart={onMessagesTouchStartBase}
      onMessagesTouchMove={onMessagesTouchMoveBase}
      onMessagesTouchEnd={onMessagesTouchEndBase}
      onOpenAgentActivity={setOpenAgentActivityId}
      onCloseAgentActivityDetail={() => setOpenAgentActivityId(null)}
      scrollButtonVisible={showScrollToBottom}
      onScrollToBottom={onScrollToBottom}
      contentInsetBottomPx={composerTranscriptInsetPx}
      contentInsetBottomClearancePx={composerOverlayBottomClearancePx}
    />
  );

  const composerPickerControls = (
    <ComposerModelPicker
      hideModelLabel={!composerFooterControlsPlan.showModelLabel}
      hideStatusLabel={!composerFooterControlsPlan.showTraitsLabel}
      contextWindowLabel={composerContextWindowLabel}
      effortControl={settings.composerEffortSlider ? "slider" : "menu"}
      provider={selectedProvider}
      model={selectedModelForPickerWithCustomFallback}
      lockedProvider={lockedProvider}
      boundProviderInstance={
        lockedProvider === null && boundProvider !== null && boundProviderInstanceId !== null
          ? { provider: boundProvider, instanceId: boundProviderInstanceId }
          : null
      }
      providers={providerStatuses}
      modelOptionsByProvider={modelOptionsByProvider}
      modelOptionsByProviderInstance={modelOptionsByProviderInstance}
      loadingModelProviders={loadingModelProviders}
      onRefreshModels={refreshModels}
      discoveryErrorsByProvider={discoveryErrorsByProvider}
      hiddenProviders={settings.hiddenProviders}
      providerOrder={settings.providerOrder}
      providerInstances={providerInstances}
      selectedProviderInstanceId={selectedProviderInstanceId}
      threadId={threadId}
      runtimeModel={selectedRuntimeModel}
      runtimeModelsByProvider={runtimeModelsByProvider}
      runtimeAgents={dynamicAgents}
      modelOptions={currentProviderModelOptions}
      prompt={prompt}
      onPromptChange={setPromptFromTraits}
      onProviderModelChange={handleProviderModelChange}
      onSelectionCommitted={scheduleComposerFocus}
      open={isModelPickerOpen}
      onOpenChange={setIsModelPickerOpen}
    />
  );

  // The request the agent waits on. A read-only host (the terminal session) has no editor, but
  // the agent still waits on this answer, so the panel is drawn there too, without the editor.
  const pendingPanel = activePendingApproval ? (
    <div className="pb-2">
      <ComposerPendingApprovalPanel
        approval={activePendingApproval}
        pendingCount={pendingApprovals.length}
        isResponding={respondingRequestKeys.includes(
          `${activePendingApproval.requestId}:${activePendingApproval.lifecycleGeneration ?? ""}`,
        ) || respondingRequestKeys.some((key) => key.startsWith(activePendingApproval.requestId))}
        onRespond={onRespondToApproval}
      />
    </div>
  ) : pendingUserInputs.length > 0 ? (
    <div className="pb-2">
      <ComposerPendingUserInputPanel
        pendingUserInputs={pendingUserInputs}
        submissionVersion={userInputSubmissionVersion}
        isResponding={activePendingIsResponding}
        answers={activePendingDraftAnswers}
        questionIndex={activePendingQuestionIndex}
        onToggleOption={onToggleActivePendingUserInputOption}
        onAdvance={onAdvanceActivePendingUserInput}
        onPrevious={onPreviousActivePendingUserInputQuestion}
        onCancel={onCancelActivePendingUserInput}
      />
    </div>
  ) : null;

  const composer = readOnly ? (
    pendingPanel ? (
      <div ref={composerOverlayRef} className="pointer-events-none absolute inset-x-0 bottom-0 z-10" data-chat-composer-slot="" data-chat-pending-only="">
        <div className="pointer-events-auto relative z-10 w-full overflow-visible">
          <ComposerColumnFrame>{pendingPanel}</ComposerColumnFrame>
        </div>
      </div>
    ) : null
  ) : (
    <div ref={composerOverlayRef} className="pointer-events-none absolute inset-x-0 bottom-0 z-10" data-chat-composer-slot="">
      <form
        ref={composerFormRef}
        onSubmit={(event: FormEvent) => void onSend(event)}
        className="pointer-events-auto relative z-10 w-full overflow-visible"
        data-chat-composer-form="true"
      >
        <ComposerColumnFrame>
          <div>
            {pendingPanel}
          </div>
          <div
            className={cn(
              COMPOSER_INPUT_SHELL_CLASS_NAME,
              composerProviderState.composerFrameClassName,
              composerOverlayOpen && !isComposerApprovalState && "overflow-visible",
            )}
            onDragEnter={onComposerDragEnter}
            onDragOver={onComposerDragOver}
            onDragLeave={onComposerDragLeave}
            onDrop={onComposerDrop}
          >
            <div
              className={cn(
                COMPOSER_INPUT_SURFACE_CLASS_NAME,
                composerProviderState.composerSurfaceClassName,
                composerOverlayOpen && !isComposerApprovalState && "overflow-visible",
              )}
            >
              <div
                className={cn(
                  COMPOSER_EDITOR_PADDING_CLASS_NAME,
                  composerOverlayOpen && !isComposerApprovalState && "overflow-visible",
                )}
              >
                {composerOverlayOpen && !isComposerApprovalState ? (
                  <div className={COMPOSER_COMMAND_MENU_FLOATING_WRAPPER_CLASS_NAME}>
                    {composerExtrasPanelOpen ? (
                      <ComposerExtrasPanel
                        panelId={COMPOSER_EXTRAS_PANEL_ID}
                        interactionMode={interactionMode}
                        supportsFastMode={composerTraitSelection.caps.supportsFastMode}
                        fastModeEnabled={composerTraitSelection.fastModeEnabled}
                        threadId={threadId}
                        onAddAttachments={addComposerAttachments}
                        onToggleFastMode={toggleFastMode}
                        onInteractionModeChange={handleInteractionModeChange}
                        onInsertGoal={() => undefined}
                        onClose={() => {
                          setIsComposerExtrasPanelOpen(false);
                          scheduleComposerFocus();
                        }}
                      />
                    ) : (
                      <ComposerCommandMenu
                        items={composerMenuItems}
                        resolvedTheme={resolvedTheme}
                        isLoading={isComposerMenuLoading}
                        triggerKind={effectiveComposerTriggerKind}
                        activeItemId={activeComposerMenuItem?.id ?? null}
                        onHighlightedItemChange={onComposerMenuItemHighlighted}
                        onSelect={onSelectComposerItem}
                      />
                    )}
                  </div>
                ) : null}
                {!isComposerApprovalState && pendingUserInputs.length === 0 && isPreparingComposerImages ? (
                  <div className="flex items-center gap-1.5 px-1 text-ui leading-snug text-muted-foreground" role="status">
                    <LoaderCircleIcon className="size-3.5 animate-spin" />
                    Optimizing {pendingComposerImageCount === 1 ? "image" : "images"}…
                  </div>
                ) : null}
                {!isComposerApprovalState &&
                pendingUserInputs.length === 0 &&
                (composerAssistantSelections.length > 0 ||
                  composerBrowserAnnotations.length > 0 ||
                  composerFileComments.length > 0 ||
                  composerPastedTexts.length > 0 ||
                  composerPullRequestContexts.length > 0 ||
                  composerFiles.length > 0 ||
                  composerImages.length > 0) ? (
                  <ComposerReferenceAttachments
                    assistantSelections={composerAssistantSelections}
                    browserAnnotations={composerBrowserAnnotations}
                    fileComments={composerFileComments}
                    pastedTexts={composerPastedTexts}
                    pullRequestContexts={composerPullRequestContexts}
                    files={composerFiles}
                    images={composerImages}
                    nonPersistedImageIdSet={nonPersistedComposerImageIdSet}
                    onExpandImage={setExpandedImage}
                    onRemoveAssistantSelections={clearComposerAssistantSelectionsFromDraft}
                    onRemoveBrowserAnnotation={removeComposerBrowserAnnotationFromDraft}
                    onRemoveFileComments={clearComposerFileCommentsFromDraft}
                    onRemovePastedText={removeComposerPastedTextFromDraft}
                    onShowPastedTextInField={showComposerPastedTextInField}
                    onRemovePullRequestContext={removeComposerPullRequestContextFromDraft}
                    onRemoveFile={removeComposerFile}
                    onRemoveImage={removeComposerImageFromDraft}
                  />
                ) : null}
                <ComposerPromptEditor
                  key={threadId}
                  ref={composerEditorRef}
                  value={isComposerApprovalState ? "" : activePendingProgress ? activePendingProgress.customAnswer : prompt}
                  cursor={composerCursor}
                  terminalContexts={!isComposerApprovalState && pendingUserInputs.length === 0 ? composerTerminalContexts : []}
                  mentionReferences={selectedComposerMentions}
                  onRemoveTerminalContext={removeComposerTerminalContextFromDraft}
                  onChange={handlePromptChange}
                  onCommandKeyDown={handleComposerCommandKey}
                  onPaste={handleComposerPaste}
                  {...(canCollapsePastedTextToDraft ? { onCollapsePastedText: handleCollapsePastedText } : {})}
                  placeholder={
                    isComposerApprovalState
                      ? "Resolve this approval request to continue"
                      : activePendingProgress
                        ? activePendingProgress.activeQuestion?.options.length === 0
                          ? "Type your answer to continue"
                          : "Type your own answer, or leave this blank to use the selected option"
                        : hasLiveTurn
                          ? "Ask for follow-up changes"
                          : "Ask anything, @tag files/folders, or use / to show available commands"
                  }
                  disabled={isComposerEditorDisabled}
                />
              </div>
              {activePendingApproval ? null : (
                <ChatComposerFooter
                  isComposerFooterCompact={false}
                  leadingControls={
                    <>
                      <ComposerExtrasTrigger
                        open={isComposerExtrasPanelOpen}
                        panelId={COMPOSER_EXTRAS_PANEL_ID}
                        onToggle={() => {
                          setIsComposerExtrasPanelOpen((open) => !open);
                          scheduleComposerFocus();
                        }}
                      />
                      <RuntimeUsageControls
                        provider={selectedProvider}
                        runtimeModel={selectedRuntimeModel}
                        providerStatus={activeProviderStatus}
                        runtimeMode={runtimeMode}
                        onRuntimeModeChange={handleRuntimeModeChange}
                        contextWindow={activeContextWindow}
                        cumulativeCostUsd={activeCumulativeCostUsd}
                        activeContextWindowLabel={contextWindowSelectionStatus.activeLabel}
                        pendingContextWindowLabel={contextWindowSelectionStatus.pendingSelectedLabel}
                        className="shrink-0"
                      />
                    </>
                  }
                  composerPickerControls={composerPickerControls}
                  contextMeter={
                    activeContextWindow && composerFooterControlsPlan.showContextMeter ? (
                      <ContextWindowMeter
                        usage={activeContextWindow}
                        showClaudeCache={activeThread.session?.provider === "claudeAgent"}
                        onOpenChange={setIsContextWindowMeterOpen}
                        {...(activeCumulativeCostUsd != null ? { cumulativeCostUsd: activeCumulativeCostUsd } : {})}
                        {...(contextWindowSelectionStatus.activeLabel !== undefined
                          ? { activeWindowLabel: contextWindowSelectionStatus.activeLabel }
                          : {})}
                        {...(contextWindowSelectionStatus.pendingSelectedLabel !== undefined
                          ? { pendingWindowLabel: contextWindowSelectionStatus.pendingSelectedLabel }
                          : {})}
                      />
                    ) : null
                  }
                  interactionMode={interactionMode}
                  resetInteractionMode={resetInteractionMode}
                  sidebarAction={null}
                  voice={NO_VOICE}
                  pendingInput={
                    activePendingProgress
                      ? {
                          progress: activePendingProgress,
                          responding: activePendingIsResponding,
                          answersComplete: Boolean(activePendingResolvedAnswers),
                        }
                      : null
                  }
                  submission={{
                    phase,
                    busy: optimisticSendBusy,
                    connecting: isConnecting,
                    expired: false,
                    hasPendingCacheReview: activeThread.claudeCacheReview != null,
                    preparingImages: isPreparingComposerImages,
                    preparingWorktree: false,
                    hasContent: composerSendState.hasSendableContent,
                    hasPendingUserInputs: pendingUserInputs.length > 0,
                    showPlanFollowUp: false,
                    hasPrompt: prompt.trim().length > 0,
                    onInterrupt,
                    onImplementInNewThread: () => undefined,
                  }}
                />
              )}
            </div>
          </div>
        </ComposerColumnFrame>
      </form>
    </div>
  );

  return (
    <WorkspaceFileOpenerContext.Provider value={fileOpener}>
      <div className="relative flex h-full min-h-0 flex-1 flex-col overflow-hidden" data-chat-root="" data-read-only={readOnly ? "true" : undefined}>
        {transcript}
        {composer}
      </div>
      {expandedImage ? (
        <ExpandedImageOverlay
          expandedImage={expandedImage}
          onClose={closeExpandedImage}
          onNavigate={navigateExpandedImage}
        />
      ) : null}
    </WorkspaceFileOpenerContext.Provider>
  );
}

const NO_VOICE = {
  enabled: false,
  recording: false,
  starting: false,
  waitingForAudio: false,
  transcribing: false,
  durationLabel: "",
  waveformLevels: [] as readonly number[],
  onCancel: () => undefined,
  onSubmit: () => undefined,
  onToggle: () => undefined,
};

function composerTraitCapsOf(provider: ProviderKind, model: string | null) {
  return getComposerTraitSelection(provider, model as ModelSlug, "", undefined).caps;
}
