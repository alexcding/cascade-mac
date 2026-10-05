//! The contract every CLI adapter implements. Ported from Synara
//! `apps/server/src/provider/Services/ProviderAdapter.ts`.
//!
//! Synara's adapter is an Effect service with one method per operation. Here a started session
//! is a task that owns its CLI process, and the methods are messages to it
//! ([`ProviderSessionHandle`]): what the CLI says comes out as [`ProviderRuntimeEvent`]s on the
//! sink the session was started with, in the order it said them.

use std::sync::Arc;

use anyhow::{anyhow, Result};
use serde::Serialize;
use tokio::sync::{mpsc, oneshot};

use crate::contracts::{
    base::{ApprovalRequestId, ThreadId, TurnId},
    orchestration::{ProviderApprovalDecision, ProviderKind, ProviderReviewTarget, ProviderUserInputAnswers, RuntimeMode},
    provider::{ProviderSendTurnInput, ProviderSessionStartInput, ProviderTurnStartResult},
    provider_runtime::ProviderRuntimeEvent,
};

use super::process::Spawner;

/// Synara `PROVIDER_ADAPTER_RUNTIME_EVENT_BUFFER_CAPACITY`: a slow consumer holds the CLI back
/// rather than growing memory without bound.
pub const PROVIDER_ADAPTER_RUNTIME_EVENT_BUFFER_CAPACITY: usize = 2_048;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum ProviderSessionModelSwitchMode {
    InSession,
    RestartSession,
    Unsupported,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum ProviderConversationRollbackMode {
    Native,
    RestartSession,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderAdapterCapabilities {
    pub session_model_switch: ProviderSessionModelSwitchMode,
    pub conversation_rollback: ProviderConversationRollbackMode,
    pub supports_turn_steering: bool,
    pub supports_native_slash_command_discovery: bool,
    pub supports_live_turn_diff_patch: bool,
}

pub type EventSink = mpsc::Sender<ProviderRuntimeEvent>;
type Reply<T> = oneshot::Sender<Result<T>>;

/// What a running session is asked to do.
pub enum SessionCommand {
    SendTurn { input: ProviderSendTurnInput, reply: Reply<ProviderTurnStartResult> },
    /// Redirect the live turn. Only for adapters whose capabilities say they steer.
    SteerTurn { input: ProviderSendTurnInput, reply: Reply<ProviderTurnStartResult> },
    /// Synara `startReview`: a native review run on the session's conversation. Only for
    /// adapters that have one (Codex's `review/start`); the others answer with an error.
    StartReview { target: ProviderReviewTarget, reply: Reply<ProviderTurnStartResult> },
    InterruptTurn { turn_id: Option<TurnId>, reply: Reply<()> },
    RespondToRequest { request_id: ApprovalRequestId, decision: ProviderApprovalDecision, reply: Reply<()> },
    RespondToUserInput { request_id: ApprovalRequestId, answers: ProviderUserInputAnswers, reply: Reply<()> },
    SetRuntimeMode { mode: RuntimeMode, reply: Reply<()> },
    /// Ends the CLI. The session emits `session.exited` and its task finishes.
    Stop { reply: Reply<()> },
}

/// The handle to a started session. Cloning it is cheap; the session lives until it is stopped
/// or its CLI exits, whichever comes first.
#[derive(Clone)]
pub struct ProviderSessionHandle {
    pub thread_id: ThreadId,
    commands: mpsc::UnboundedSender<SessionCommand>,
}

impl ProviderSessionHandle {
    pub fn new(thread_id: ThreadId, commands: mpsc::UnboundedSender<SessionCommand>) -> Self {
        Self { thread_id, commands }
    }

    pub fn is_alive(&self) -> bool {
        !self.commands.is_closed()
    }

    async fn ask<T>(&self, command: impl FnOnce(Reply<T>) -> SessionCommand) -> Result<T> {
        let (reply, answer) = oneshot::channel();
        self.commands
            .send(command(reply))
            .map_err(|_| anyhow!("the provider session has ended"))?;
        answer.await.map_err(|_| anyhow!("the provider session ended before it answered"))?
    }

    pub async fn send_turn(&self, input: ProviderSendTurnInput) -> Result<ProviderTurnStartResult> {
        self.ask(|reply| SessionCommand::SendTurn { input, reply }).await
    }

    pub async fn steer_turn(&self, input: ProviderSendTurnInput) -> Result<ProviderTurnStartResult> {
        self.ask(|reply| SessionCommand::SteerTurn { input, reply }).await
    }

    pub async fn start_review(&self, target: ProviderReviewTarget) -> Result<ProviderTurnStartResult> {
        self.ask(|reply| SessionCommand::StartReview { target, reply }).await
    }

    pub async fn interrupt_turn(&self, turn_id: Option<TurnId>) -> Result<()> {
        self.ask(|reply| SessionCommand::InterruptTurn { turn_id, reply }).await
    }

    pub async fn respond_to_request(
        &self,
        request_id: ApprovalRequestId,
        decision: ProviderApprovalDecision,
    ) -> Result<()> {
        self.ask(|reply| SessionCommand::RespondToRequest { request_id, decision, reply }).await
    }

    pub async fn respond_to_user_input(
        &self,
        request_id: ApprovalRequestId,
        answers: ProviderUserInputAnswers,
    ) -> Result<()> {
        self.ask(|reply| SessionCommand::RespondToUserInput { request_id, answers, reply }).await
    }

    pub async fn set_runtime_mode(&self, mode: RuntimeMode) -> Result<()> {
        self.ask(|reply| SessionCommand::SetRuntimeMode { mode, reply }).await
    }

    pub async fn stop(&self) -> Result<()> {
        self.ask(|reply| SessionCommand::Stop { reply }).await
    }
}

/// A model a provider offers, for the composer's picker.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderModel {
    pub slug: String,
    pub name: String,
    pub is_default: bool,
}

/// Synara `ProviderAdapterShape`, the part a session-less caller needs. Starting a session
/// spawns the CLI and returns at once; a launch that fails reports itself as `runtime.error`
/// and `session.exited` on the sink, as a crash later on would.
pub trait ProviderAdapter: Send + Sync {
    fn provider(&self) -> ProviderKind;
    fn capabilities(&self) -> ProviderAdapterCapabilities;
    fn models(&self) -> Vec<ProviderModel>;
    fn start_session(
        &self,
        input: ProviderSessionStartInput,
        events: EventSink,
        spawner: Arc<dyn Spawner>,
    ) -> ProviderSessionHandle;
}
