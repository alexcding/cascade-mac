//! Ported from Synara `packages/contracts/src/baseSchemas.ts`: the branded ids and the timestamp.
//! `ProviderDriverKind` and `ProviderInstanceId` come from `providerInstance.ts`, which has no
//! file of its own here. Ids that only belong to the families this crate leaves out (spaces,
//! automations, goals, project tasks) are not ported.

use std::fmt;

use chrono::{SecondsFormat, Utc};
use serde::{Deserialize, Serialize};

/// Synara `IsoDateTime` (baseSchemas.ts:21)
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct IsoDateTime(String);

impl IsoDateTime {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for IsoDateTime {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// The current time as Synara writes it: UTC, millisecond precision, `Z` suffix.
pub fn now_iso() -> IsoDateTime {
    IsoDateTime(Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true))
}

macro_rules! entity_id {
    ($(#[$meta:meta])* $name:ident) => {
        $(#[$meta])*
        #[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
        #[serde(transparent)]
        pub struct $name(String);

        impl $name {
            pub fn new(value: impl Into<String>) -> Self {
                Self(value.into())
            }

            pub fn as_str(&self) -> &str {
                &self.0
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str(&self.0)
            }
        }
    };
}

entity_id! {
    /// Synara `ThreadId` (baseSchemas.ts:30)
    ThreadId
}
entity_id! {
    /// Synara `ProjectId` (baseSchemas.ts:32)
    ProjectId
}
entity_id! {
    /// Synara `CommandId` (baseSchemas.ts:40)
    CommandId
}
entity_id! {
    /// Synara `EventId` (baseSchemas.ts:42)
    EventId
}
entity_id! {
    /// Synara `MessageId` (baseSchemas.ts:44)
    MessageId
}
entity_id! {
    /// Synara `TurnId` (baseSchemas.ts:52)
    TurnId
}
entity_id! {
    /// Synara `ProviderItemId` (baseSchemas.ts:69)
    ProviderItemId
}
entity_id! {
    /// Synara `RuntimeSessionId` (baseSchemas.ts:71)
    RuntimeSessionId
}
entity_id! {
    /// Synara `RuntimeItemId` (baseSchemas.ts:73)
    RuntimeItemId
}
entity_id! {
    /// Synara `RuntimeRequestId` (baseSchemas.ts:75)
    RuntimeRequestId
}
entity_id! {
    /// Synara `RuntimeTaskId` (baseSchemas.ts:77)
    RuntimeTaskId
}
entity_id! {
    /// Synara `ApprovalRequestId` (baseSchemas.ts:79)
    ApprovalRequestId
}
entity_id! {
    /// Synara `CheckpointRef` (baseSchemas.ts:81)
    CheckpointRef
}
entity_id! {
    /// Synara `ProviderDriverKind` (providerInstance.ts:31): names the implementation (`codex`,
    /// `claudeAgent`, ...) as a slug, so it is a string rather than the closed `ProviderKind`.
    ProviderDriverKind
}
entity_id! {
    /// Synara `ProviderInstanceId` (providerInstance.ts:38)
    ProviderInstanceId
}

/// Rust has no `Schema.optional(Schema.NullOr(T))`: this is `Option<Option<T>>`, where the outer
/// level is "field present" and the inner is `null`. Use as
/// `#[serde(default, with = "optional_nullable", skip_serializing_if = "Option::is_none")]`.
pub mod optional_nullable {
    use serde::{Deserialize, Deserializer, Serialize, Serializer};

    pub fn serialize<S, T>(value: &Option<Option<T>>, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
        T: Serialize,
    {
        match value {
            Some(inner) => inner.serialize(serializer),
            None => serializer.serialize_none(),
        }
    }

    pub fn deserialize<'de, D, T>(deserializer: D) -> Result<Option<Option<T>>, D::Error>
    where
        D: Deserializer<'de>,
        T: Deserialize<'de>,
    {
        Ok(Some(Option::<T>::deserialize(deserializer)?))
    }
}
