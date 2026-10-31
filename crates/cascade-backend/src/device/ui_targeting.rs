//! Resolving an accessibility node to the point that actually taps it.
//!
//! Port of Synara's `apps/server/src/device/uiTreeTargeting.ts`. Agents are bad at coordinate
//! arithmetic and worse at knowing which coordinate of a node is the live one, so this is the one
//! place that answers "where do I tap to hit the thing called X":
//!
//! - The tap point is the node's activation point when it has one (a switch row's frame centre is
//!   dead space).
//! - A match scrolled out of view is reported as such rather than tapped: its frame is still in
//!   the tree, and tapping it would hit whatever is at that position instead.
//!
//! The matching itself is `tree_targeting.rs`; what stays here is what UIKit needs: labels
//! compared with case and surrounding space ignored, a subrole that counts as a role, and "on
//! screen" meaning the tap point falls inside the display's frame.

use regex::Regex;

use super::{
    contracts::{DeviceUiNode, DeviceUiPoint},
    tree_targeting::{flatten_ui_tree, resolve_ui_tree_target, ui_tree_activation_point, UiTreeQuery, UiTreeTargetSpec},
};

/// What the caller asked for: a label, an accessibility identifier, or both. Role narrows an
/// ambiguous match. The identifier is the handle a test should prefer: it survives localization.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct DeviceUiTarget {
    pub label: Option<String>,
    pub identifier: Option<String>,
    pub role: Option<String>,
}

/// `labelled "Sign in"` or `with identifier #login-button`, for error messages.
pub fn target_phrase(target: &DeviceUiTarget) -> String {
    match &target.identifier {
        None => format!("labelled {}", json_string(target.label.as_deref().unwrap_or(""))),
        Some(_) => format!("with identifier {}", describe_target(target)),
    }
}

/// How a target reads in messages: `"Sign in"`, `#login-button`, or both.
pub fn describe_target(target: &DeviceUiTarget) -> String {
    let mut parts = Vec::new();
    if let Some(identifier) = &target.identifier {
        parts.push(format!("#{identifier}"));
    }
    if let Some(label) = &target.label {
        parts.push(json_string(label));
    }
    if parts.is_empty() {
        "(no target)".into()
    } else {
        parts.join(" ")
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct DeviceUiTargetMatch<'a> {
    pub point: DeviceUiPoint,
    pub node: &'a DeviceUiNode,
    /// False when the match is in the tree but scrolled out of the display.
    pub on_screen: bool,
}

/// A target that could not be resolved. The candidates are in the message too, since every
/// transport between here and the agent carries only the message.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeviceUiTargetError {
    pub message: String,
    /// Candidate descriptions, so the agent can retry with a real label.
    pub candidates: Vec<String>,
    /// Nothing matched at all. Long lists are virtualized, so a row further down is absent until
    /// scrolling reaches it: a scroll loop keeps looking, while an ambiguity is not retried.
    pub not_found: bool,
}

impl DeviceUiTargetError {
    pub fn new(message: impl Into<String>, candidates: Vec<String>, not_found: bool) -> Self {
        let message = message.into();
        let message = if candidates.is_empty() {
            message
        } else {
            format!("{message} Elements on screen: {}.", candidates.join("; "))
        };
        Self { message, candidates, not_found }
    }

    fn plain(message: impl Into<String>) -> Self {
        Self::new(message, Vec::new(), false)
    }
}

impl std::fmt::Display for DeviceUiTargetError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for DeviceUiTargetError {}

/// How many near-misses to name; a whole screen of labels is noise, not help.
const MAX_REPORTED_CANDIDATES: usize = 12;

pub(crate) fn children_of(node: &DeviceUiNode) -> &[DeviceUiNode] {
    &node.children
}

/// A string as `JSON.stringify` writes it.
pub(crate) fn json_string(value: &str) -> String {
    serde_json::to_string(value).unwrap_or_default()
}

/// Whether a tap could ever land on this node. An element with no usable frame, or no area and
/// no activation point, would aim at the screen origin, which is somebody else's control.
pub fn is_targetable(node: &DeviceUiNode) -> bool {
    if node.is_unframed() {
        return false;
    }
    (node.frame.width > 0.0 && node.frame.height > 0.0) || node.activation_point.is_some()
}

/// Only a node with a label of its own can be named, or usefully listed back.
fn labelled_nodes(root: &DeviceUiNode) -> Vec<&DeviceUiNode> {
    flatten_ui_tree(root, children_of)
        .into_iter()
        .filter(|node| node.label.as_deref().is_some_and(|label| !label.is_empty()) && is_targetable(node))
        .collect()
}

fn identified_nodes<'a>(root: &'a DeviceUiNode, identifier: &str) -> Vec<&'a DeviceUiNode> {
    flatten_ui_tree(root, children_of)
        .into_iter()
        .filter(|node| node.identifier.as_deref() == Some(identifier) && is_targetable(node))
        .collect()
}

/// Every label currently rendered, used to tell a moving list from a stuck one.
pub fn visible_labels(root: &DeviceUiNode) -> Vec<String> {
    labelled_nodes(root).into_iter().filter_map(|node| node.label.clone()).collect()
}

/// Where a tap on this node lands: its own control point, else the frame centre.
pub fn tap_point(node: &DeviceUiNode) -> DeviceUiPoint {
    ui_tree_activation_point(&node.frame, node.activation_point)
}

fn normalize(value: &str) -> String {
    value.trim().to_lowercase()
}

fn matches_role(node: &DeviceUiNode, role: &str) -> bool {
    let wanted = normalize(role);
    normalize(&node.role) == wanted || node.subrole.as_deref().is_some_and(|subrole| normalize(subrole) == wanted)
}

/// A node is on screen when the point a tap would use is inside the root's frame.
pub fn is_on_screen(node: &DeviceUiNode, root: &DeviceUiNode) -> bool {
    let point = tap_point(node);
    point.x >= root.frame.x
        && point.x <= root.frame.x + root.frame.width
        && point.y >= root.frame.y
        && point.y <= root.frame.y + root.frame.height
}

fn describe(node: &DeviceUiNode) -> String {
    let role = match &node.subrole {
        None => node.role.clone(),
        Some(subrole) => format!("{}/{subrole}", node.role),
    };
    let value = node.value.as_deref().map(|value| format!(" value={}", json_string(value))).unwrap_or_default();
    let identifier = node
        .identifier
        .as_deref()
        .filter(|identifier| !identifier.is_empty())
        .map(|identifier| format!(" #{identifier}"))
        .unwrap_or_default();
    format!("{role} {}{identifier}{value}", json_string(node.label.as_deref().unwrap_or("")))
}

/// Locates the one node a target refers to, whether or not it is on screen. Exact label matches
/// win outright; ambiguity is judged among visible matches first, so a list that repeats a label
/// down its length resolves to the row the human can see.
pub fn find_target<'a>(root: &'a DeviceUiNode, target: &DeviceUiTarget) -> Result<DeviceUiTargetMatch<'a>, DeviceUiTargetError> {
    let query = UiTreeQuery { label: target.label.as_deref(), role: target.role.as_deref() };
    if let Some(identifier) = target.identifier.as_deref().map(str::trim).filter(|identifier| !identifier.is_empty()) {
        // An identifier is exact by contract, so it picks the pool and a label only narrows it.
        let pool = identified_nodes(root, identifier);
        let spec = DeviceTargetSpec { root, target, identifier_candidates: true };
        let found = resolve_ui_tree_target(&pool, query, &spec)?;
        return Ok(DeviceUiTargetMatch { point: tap_point(found.node), node: found.node, on_screen: found.on_screen });
    }
    if target.label.as_deref().is_none_or(|label| normalize(label).is_empty()) {
        return Err(DeviceUiTargetError::plain("A tap target needs a non-empty label or identifier."));
    }
    let pool = labelled_nodes(root);
    let spec = DeviceTargetSpec { root, target, identifier_candidates: false };
    let found = resolve_ui_tree_target(&pool, query, &spec)?;
    Ok(DeviceUiTargetMatch { point: tap_point(found.node), node: found.node, on_screen: found.on_screen })
}

/// Identifiers on screen, for an identifier that matched nothing.
fn identifier_candidates(root: &DeviceUiNode) -> Vec<String> {
    flatten_ui_tree(root, children_of)
        .into_iter()
        .filter(|node| {
            node.identifier.as_deref().is_some_and(|identifier| !identifier.is_empty())
                && is_targetable(node)
                && is_on_screen(node, root)
        })
        .map(describe)
        .collect()
}

struct DeviceTargetSpec<'r> {
    root: &'r DeviceUiNode,
    target: &'r DeviceUiTarget,
    identifier_candidates: bool,
}

impl UiTreeTargetSpec<DeviceUiNode> for DeviceTargetSpec<'_> {
    type Error = DeviceUiTargetError;

    fn label_of<'n>(&self, node: &'n DeviceUiNode) -> &'n str {
        node.label.as_deref().unwrap_or("")
    }

    fn matches_role(&self, node: &DeviceUiNode, role: &str) -> bool {
        matches_role(node, role)
    }

    fn match_key(&self, label: &str) -> String {
        normalize(label)
    }

    fn exact_key(&self, label: &str) -> String {
        normalize(label)
    }

    fn is_on_screen(&self, node: &DeviceUiNode) -> bool {
        is_on_screen(node, self.root)
    }

    fn prefer_on_screen(&self) -> bool {
        true
    }

    fn no_match(&self, pool: &[&DeviceUiNode]) -> DeviceUiTargetError {
        let role_note = self.target.role.as_deref().map(|role| format!(" with role {}", json_string(role))).unwrap_or_default();
        let candidates = if self.identifier_candidates {
            identifier_candidates(self.root).into_iter().take(MAX_REPORTED_CANDIDATES).collect()
        } else {
            pool.iter().take(MAX_REPORTED_CANDIDATES).map(|node| describe(node)).collect()
        };
        DeviceUiTargetError::new(
            format!(
                "No element {}{role_note} is in the accessibility tree. It may belong to a screen you have not opened \
                 yet; call device_describe_ui and use a label or identifier listed there.",
                target_phrase(self.target)
            ),
            candidates,
            true,
        )
    }

    fn ambiguous(&self, matches: &[&DeviceUiNode]) -> DeviceUiTargetError {
        DeviceUiTargetError::new(
            format!(
                "{} elements match {}. Pass identifier or role to narrow it, or tap explicit coordinates from \
                 device_describe_ui.",
                matches.len(),
                describe_target(self.target)
            ),
            matches.iter().take(MAX_REPORTED_CANDIDATES).map(|node| describe(node)).collect(),
            false,
        )
    }
}

fn is_keyboard_role(value: &str) -> bool {
    Regex::new(r"(?i)^(?:AX)?Keyboard$").expect("valid pattern").is_match(value)
}

/// Where the system keyboard starts, if one is up: a node whose role or subrole is `Keyboard`
/// (the highest wins), or failing that, Xcode 27's flattened full-width `GenericElement` overlay
/// that holds the `space`, `delete` and `Return` keys (the tightest wins) — never an app's own
/// one-character buttons.
pub fn device_keyboard_top(root: &DeviceUiNode) -> Option<f64> {
    let nodes = flatten_ui_tree(root, children_of);
    let keyboards: Vec<&DeviceUiNode> = nodes
        .iter()
        .copied()
        .filter(|node| {
            if node.is_unframed()
                || node.frame.width <= 0.0
                || node.frame.height <= 0.0
                || !node.frame.y.is_finite()
                || node.frame.y < root.frame.y
                || node.frame.y >= root.frame.y + root.frame.height
            {
                return false;
            }
            if is_keyboard_role(&node.role) || is_keyboard_role(node.subrole.as_deref().unwrap_or("")) {
                return true;
            }
            if node.role != "GenericElement" || node.frame.width < root.frame.width * 0.8 {
                return false;
            }
            let controls: std::collections::HashSet<&str> = nodes
                .iter()
                .filter(|key| key.role == "Button" && is_on_screen(key, node))
                .filter_map(|key| key.identifier.as_deref().filter(|identifier| !identifier.is_empty()))
                .collect();
            controls.contains("space") && controls.contains("delete") && controls.contains("Return")
        })
        .collect();
    let explicit: Vec<f64> = keyboards
        .iter()
        .filter(|node| is_keyboard_role(&node.role) || is_keyboard_role(node.subrole.as_deref().unwrap_or("")))
        .map(|node| node.frame.y)
        .collect();
    if !explicit.is_empty() {
        return explicit.into_iter().reduce(f64::min);
    }
    keyboards
        .into_iter()
        .reduce(|smallest, candidate| {
            if candidate.frame.width * candidate.frame.height < smallest.frame.width * smallest.frame.height {
                candidate
            } else {
                smallest
            }
        })
        .map(|overlay| overlay.frame.y)
}

/// The band a target must land in to count as usable: not the whole screen, since a row under
/// the status bar or behind the home indicator is visible but untappable.
const SAFE_BAND_INSET_FRACTION: f64 = 0.12;
/// One swipe covers most of a screen, but not so much that it overshoots.
const SCROLL_INCREMENT_FRACTION: f64 = 0.6;
/// Long enough to read as a drag rather than a flick, which would coast past.
pub const SCROLL_SWIPE_DURATION_MS: u32 = 400;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DeviceScrollStep {
    pub from_x: f64,
    pub from_y: f64,
    pub to_x: f64,
    pub to_y: f64,
    pub duration_ms: u32,
}

/// The swipe that moves a target toward the safe band, or none when it is already there. Content
/// moves opposite to the finger, so to bring up something below the fold the finger travels up.
pub fn plan_scroll_step(node: &DeviceUiNode, root: &DeviceUiNode) -> Result<Option<DeviceScrollStep>, DeviceUiTargetError> {
    let inset = root.frame.height * SAFE_BAND_INSET_FRACTION;
    let band_top = root.frame.y + inset;
    let band_bottom = (root.frame.y + root.frame.height - inset)
        .min(device_keyboard_top(root).unwrap_or(f64::INFINITY) - inset);
    if band_bottom <= band_top {
        return Err(DeviceUiTargetError::plain(
            "The software keyboard leaves no safe scrolling area; dismiss it before scrolling.",
        ));
    }
    let centre = node.frame.y + node.frame.height / 2.0;
    if centre >= band_top && centre <= band_bottom {
        return Ok(None);
    }
    let increment = root.frame.height * SCROLL_INCREMENT_FRACTION;
    let mid_x = root.frame.x + root.frame.width / 2.0;
    let screen_centre = (band_top + band_bottom) / 2.0;
    // Never further than the gap: a target just past the band is not flung to the other side.
    let distance = increment.min((centre - screen_centre).abs());
    let below = centre > band_bottom;
    let from = if below { screen_centre + distance / 2.0 } else { screen_centre - distance / 2.0 };
    let to = if below { from - distance } else { from + distance };
    Ok(Some(DeviceScrollStep { from_x: mid_x, from_y: from, to_x: mid_x, to_y: to, duration_ms: SCROLL_SWIPE_DURATION_MS }))
}

/// The two shapes a tap request can take, once validated.
#[derive(Clone, Debug, PartialEq)]
pub enum DeviceTapRequest {
    Point { x: f64, y: f64 },
    Element(DeviceUiTarget),
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct DeviceTapInput {
    pub x: Option<f64>,
    pub y: Option<f64>,
    pub label: Option<String>,
    pub identifier: Option<String>,
    pub role: Option<String>,
}

/// Whether a tap names a point or an element, refusing shapes that are neither (or both: silently
/// preferring one would make the other's presence a lie about what got tapped).
pub fn read_tap_request(input: &DeviceTapInput) -> Result<DeviceTapRequest, DeviceUiTargetError> {
    let point = input.x.zip(input.y);
    if input.label.is_some() || input.identifier.is_some() {
        if point.is_some() {
            return Err(DeviceUiTargetError::plain(
                "A tap takes either an element (identifier or label, with optional role) or x and y, not both. Pass \
                 the element alone to let Cascade resolve its own tap point.",
            ));
        }
        return Ok(DeviceTapRequest::Element(DeviceUiTarget {
            label: input.label.clone(),
            identifier: input.identifier.clone(),
            role: input.role.clone(),
        }));
    }
    let Some((x, y)) = point else {
        return Err(DeviceUiTargetError::plain(
            "A tap needs an element (identifier or label, with optional role) or both x and y. Prefer the element: \
             Cascade then resolves its own tap point from the accessibility tree.",
        ));
    };
    Ok(DeviceTapRequest::Point { x, y })
}
