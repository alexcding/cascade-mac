//! Resolving a label to the one accessibility node it means, for any tree.
//!
//! Port of Synara's `packages/shared/src/uiTreeTargeting.ts`, where the iOS simulator's tree and
//! the Linux desktop's share one algorithm; each family supplies only what differs (what a
//! node's label is, what counts as its role, how labels compare, what "on screen" means). Two
//! rules carry most of the value:
//!
//! - An exact label wins outright over a longer one that merely contains it.
//! - Ambiguity is refused, never guessed; the refusal names the candidates.
//!
//! Nothing here builds an error: both refusals come from the calling family.

use super::contracts::{DeviceUiFrame, DeviceUiPoint};

/// Depth-first, parents before children — the order candidate lists are capped in.
pub fn flatten_ui_tree<'a, T>(root: &'a T, children_of: impl Fn(&'a T) -> &'a [T] + Copy) -> Vec<&'a T> {
    let mut nodes = Vec::new();
    fn visit<'a, T>(node: &'a T, children_of: impl Fn(&'a T) -> &'a [T] + Copy, nodes: &mut Vec<&'a T>) {
        nodes.push(node);
        for child in children_of(node) {
            visit(child, children_of, nodes);
        }
    }
    visit(root, children_of, &mut nodes);
    nodes
}

/// Where an interaction with a node lands: its own control point when it has one, else the
/// centre of its frame. UIKit merges a settings row and its switch into one element whose frame
/// spans the row, so the frame centre of a switch row is dead space.
pub fn ui_tree_activation_point(frame: &DeviceUiFrame, activation_point: Option<DeviceUiPoint>) -> DeviceUiPoint {
    activation_point.unwrap_or(DeviceUiPoint { x: frame.x + frame.width / 2.0, y: frame.y + frame.height / 2.0 })
}

/// What the caller asked for. Both parts are optional; a family may require either.
#[derive(Clone, Copy, Debug, Default)]
pub struct UiTreeQuery<'q> {
    pub label: Option<&'q str>,
    pub role: Option<&'q str>,
}

#[derive(Debug)]
pub struct UiTreeTargetMatch<'a, T> {
    /// False when the match is real but outside the usable area of the display.
    pub on_screen: bool,
    pub node: &'a T,
}

/// Everything the families disagree about, and nothing they agree on.
pub trait UiTreeTargetSpec<T> {
    type Error;
    /// The text this node answers to; empty for a node with none.
    fn label_of<'n>(&self, node: &'n T) -> &'n str;
    fn matches_role(&self, node: &T, role: &str) -> bool;
    /// Both sides of "did this label match at all".
    fn match_key(&self, label: &str) -> String;
    /// Both sides of "is this the label, exactly"; separate because families disagree on how
    /// strict promotion to an exact match is.
    fn exact_key(&self, label: &str) -> String;
    fn is_on_screen(&self, node: &T) -> bool;
    /// Judge ambiguity among the on-screen matches first.
    fn prefer_on_screen(&self) -> bool;
    /// The refusal for a query nothing matched; `pool` is everything considered.
    fn no_match(&self, pool: &[&T]) -> Self::Error;
    /// The refusal for a query more than one node matched, after ranking.
    fn ambiguous(&self, matches: &[&T]) -> Self::Error;
}

/// The one node `query` names, or the family's refusal. `pool` is already flattened and scoped,
/// because that scope is also what the "nothing matched" refusal lists.
pub fn resolve_ui_tree_target<'a, T, S: UiTreeTargetSpec<T>>(
    pool: &[&'a T],
    query: UiTreeQuery<'_>,
    spec: &S,
) -> Result<UiTreeTargetMatch<'a, T>, S::Error> {
    let by_role: Vec<&'a T> = match query.role {
        Some(role) => pool.iter().copied().filter(|node| spec.matches_role(node, role)).collect(),
        None => pool.to_vec(),
    };
    let matches = match query.label {
        Some(label) => matches_for_label(&by_role, label, spec),
        None => by_role,
    };
    if matches.is_empty() {
        return Err(spec.no_match(pool));
    }
    let ranked = if spec.prefer_on_screen() { prefer_on_screen_matches(matches, spec) } else { matches };
    if ranked.len() > 1 {
        return Err(spec.ambiguous(&ranked));
    }
    let node = ranked[0];
    Ok(UiTreeTargetMatch { on_screen: spec.is_on_screen(node), node })
}

fn matches_for_label<'a, T, S: UiTreeTargetSpec<T>>(nodes: &[&'a T], label: &str, spec: &S) -> Vec<&'a T> {
    let exact = spec.exact_key(label);
    let exact_matches: Vec<&'a T> =
        nodes.iter().copied().filter(|node| spec.exact_key(spec.label_of(node)) == exact).collect();
    if !exact_matches.is_empty() {
        return exact_matches;
    }
    let wanted = spec.match_key(label);
    nodes.iter().copied().filter(|node| spec.match_key(spec.label_of(node)).contains(&wanted)).collect()
}

fn prefer_on_screen_matches<'a, T, S: UiTreeTargetSpec<T>>(matches: Vec<&'a T>, spec: &S) -> Vec<&'a T> {
    let visible: Vec<&'a T> = matches.iter().copied().filter(|node| spec.is_on_screen(node)).collect();
    if visible.is_empty() {
        matches
    } else {
        visible
    }
}
