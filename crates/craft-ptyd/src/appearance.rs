use serde::{Deserialize, Serialize};

/// Native defaults, retained by the daemon while every renderer is detached.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TerminalAppearance {
    pub values: Vec<u32>,
}
impl TerminalAppearance {
    pub fn validate(&self) -> Result<(), String> {
        if self.values.len() != 260 || self.values[..258].iter().any(|v| *v > 0xFFFFFF)
            || (self.values[258] > 0xFFFFFF && self.values[258] != u32::MAX) || self.values[259] > 1 {
            return Err("invalid native terminal appearance".into());
        }
        Ok(())
    }
    #[cfg(feature = "terminal-snapshots")]
    pub fn runtime(&self) -> Result<craft_vt::Appearance, String> {
        craft_vt::Appearance::from_values(&self.values).map_err(|e| e.to_string())
    }
}
