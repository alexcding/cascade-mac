//! The shared label-resolution algorithm: exact labels win, ambiguity is refused, never guessed.
//! Ported from `packages/shared/src/uiTreeTargeting.test.ts`.

use crate::device::{
    contracts::{DeviceUiFrame, DeviceUiPoint},
    tree_targeting::{flatten_ui_tree, resolve_ui_tree_target, ui_tree_activation_point, UiTreeQuery, UiTreeTargetSpec},
};

#[derive(Clone, Debug)]
struct TestNode {
    label: String,
    role: String,
    on_screen: bool,
    children: Vec<TestNode>,
}

fn node(label: &str) -> TestNode {
    TestNode { label: label.into(), role: "button".into(), on_screen: true, children: Vec::new() }
}

impl TestNode {
    fn role(mut self, role: &str) -> Self {
        self.role = role.into();
        self
    }

    fn on_screen(mut self, on_screen: bool) -> Self {
        self.on_screen = on_screen;
        self
    }

    fn children(mut self, children: Vec<TestNode>) -> Self {
        self.children = children;
        self
    }
}

#[derive(Debug, PartialEq, Eq)]
enum Refusal {
    NoMatch { pool: Vec<String> },
    Ambiguous { matches: Vec<String> },
}

fn labels(nodes: &[&TestNode]) -> Vec<String> {
    nodes.iter().map(|entry| entry.label.clone()).collect()
}

/// The TS test's default spec, with the same overrides as slots.
struct TestSpec {
    verbatim_match_key: bool,
    strict_exact_key: bool,
    prefer_on_screen: bool,
}

impl Default for TestSpec {
    fn default() -> Self {
        Self { verbatim_match_key: false, strict_exact_key: false, prefer_on_screen: true }
    }
}

impl UiTreeTargetSpec<TestNode> for TestSpec {
    type Error = Refusal;

    fn label_of<'n>(&self, node: &'n TestNode) -> &'n str {
        &node.label
    }

    fn matches_role(&self, node: &TestNode, role: &str) -> bool {
        node.role == role
    }

    fn match_key(&self, label: &str) -> String {
        if self.verbatim_match_key {
            label.to_owned()
        } else {
            label.trim().to_lowercase()
        }
    }

    fn exact_key(&self, label: &str) -> String {
        if self.verbatim_match_key || self.strict_exact_key {
            label.to_owned()
        } else {
            label.trim().to_lowercase()
        }
    }

    fn is_on_screen(&self, node: &TestNode) -> bool {
        node.on_screen
    }

    fn prefer_on_screen(&self) -> bool {
        self.prefer_on_screen
    }

    fn no_match(&self, pool: &[&TestNode]) -> Refusal {
        Refusal::NoMatch { pool: labels(pool) }
    }

    fn ambiguous(&self, matches: &[&TestNode]) -> Refusal {
        Refusal::Ambiguous { matches: labels(matches) }
    }
}

/// What a successful resolution is, reduced to what the tests compare.
#[derive(Debug, PartialEq, Eq)]
struct Resolved {
    label: String,
    role: String,
    on_screen: bool,
    node_on_screen: bool,
}

fn resolve_with(pool: &[TestNode], label: Option<&str>, role: Option<&str>, spec: &TestSpec) -> Result<Resolved, Refusal> {
    let refs: Vec<&TestNode> = pool.iter().collect();
    resolve_ui_tree_target(&refs, UiTreeQuery { label, role }, spec).map(|found| Resolved {
        label: found.node.label.clone(),
        role: found.node.role.clone(),
        on_screen: found.on_screen,
        node_on_screen: found.node.on_screen,
    })
}

fn resolve(pool: &[TestNode], label: Option<&str>, role: Option<&str>) -> Result<Resolved, Refusal> {
    resolve_with(pool, label, role, &TestSpec::default())
}

fn children_of(entry: &TestNode) -> &[TestNode] {
    &entry.children
}

#[test]
fn visits_parents_before_their_children_depth_first() {
    let root = node("root").children(vec![
        node("a").children(vec![node("a1"), node("a2")]),
        node("b"),
    ]);
    let flat = flatten_ui_tree(&root, children_of);
    assert_eq!(labels(&flat), ["root", "a", "a1", "a2", "b"]);
}

#[test]
fn prefers_a_nodes_own_control_point_over_the_centre_of_its_frame() {
    let point = ui_tree_activation_point(
        &DeviceUiFrame { x: 36.0, y: 184.0, width: 330.0, height: 28.0 },
        Some(DeviceUiPoint { x: 336.5, y: 198.0 }),
    );
    assert_eq!(point, DeviceUiPoint { x: 336.5, y: 198.0 });
}

#[test]
fn falls_back_to_the_frame_centre_for_an_absent_control_point() {
    let frame = DeviceUiFrame { x: 10.0, y: 20.0, width: 100.0, height: 40.0 };
    assert_eq!(ui_tree_activation_point(&frame, None), DeviceUiPoint { x: 60.0, y: 40.0 });
}

#[test]
fn prefers_an_exact_label_over_a_longer_one_that_merely_contains_it() {
    let pool = [node("Developer"), node("Developer Mode")];
    assert_eq!(resolve(&pool, Some("Developer"), None).unwrap().label, "Developer");
}

#[test]
fn falls_back_to_substring_only_when_nothing_matches_exactly() {
    let pool = [node("Developer Mode")];
    assert_eq!(resolve(&pool, Some("Developer"), None).unwrap().label, "Developer Mode");
}

#[test]
fn refuses_several_matches_rather_than_taking_the_first() {
    let pool = [node("Row A"), node("Row B")];
    let error = resolve(&pool, Some("Row"), None).unwrap_err();
    assert_eq!(error, Refusal::Ambiguous { matches: vec!["Row A".into(), "Row B".into()] });
}

#[test]
fn hands_the_whole_pool_not_the_near_misses_to_the_no_match_refusal() {
    let pool = [node("Wi-Fi"), node("Bluetooth")];
    let error = resolve(&pool, Some("Airplane Mode"), None).unwrap_err();
    assert_eq!(error, Refusal::NoMatch { pool: vec!["Wi-Fi".into(), "Bluetooth".into()] });
}

#[test]
fn narrows_by_role_before_matching_the_label() {
    let pool = [node("Wi-Fi").role("heading"), node("Wi-Fi").role("switch")];
    assert!(matches!(resolve(&pool, Some("Wi-Fi"), None), Err(Refusal::Ambiguous { .. })));
    assert_eq!(resolve(&pool, Some("Wi-Fi"), Some("switch")).unwrap().role, "switch");
}

#[test]
fn matches_on_role_alone_when_the_query_names_no_label() {
    let pool = [node("Wi-Fi").role("heading"), node("Save").role("menu")];
    assert_eq!(resolve(&pool, None, Some("menu")).unwrap().label, "Save");
}

#[test]
fn compares_both_sides_through_the_familys_own_keys() {
    let pool = [node("Dark Appearance")];
    // The default spec trims and lowercases; a family that does neither sees these as different
    // strings, which is exactly why the keys are a slot.
    assert_eq!(resolve(&pool, Some("  dark appearance "), None).unwrap().label, "Dark Appearance");
    let verbatim = TestSpec { verbatim_match_key: true, ..TestSpec::default() };
    assert!(matches!(resolve_with(&pool, Some("  dark appearance "), None, &verbatim), Err(Refusal::NoMatch { .. })));
}

#[test]
fn promotes_an_exact_match_by_exact_key_even_when_match_key_is_looser() {
    // The desktop family's shape: substring is case-insensitive, exactness is not, so a
    // differently-cased query stays ambiguous.
    let pool = [node("Save"), node("Save As")];
    let strict_exact = TestSpec { strict_exact_key: true, ..TestSpec::default() };
    assert_eq!(resolve_with(&pool, Some("Save"), None, &strict_exact).unwrap().label, "Save");
    assert!(matches!(resolve_with(&pool, Some("save"), None, &strict_exact), Err(Refusal::Ambiguous { .. })));
}

#[test]
fn narrows_an_ambiguity_to_the_visible_matches_when_the_family_asks_it_to() {
    let pool = [node("Row").on_screen(true), node("Row").on_screen(false)];
    let found = resolve(&pool, Some("Row"), None).unwrap();
    assert!(found.on_screen);
    assert!(found.node_on_screen);
}

#[test]
fn reports_an_off_screen_sole_match_rather_than_refusing_it_here() {
    let pool = [node("Far Below").on_screen(false)];
    assert!(!resolve(&pool, Some("Far Below"), None).unwrap().on_screen);
}

#[test]
fn leaves_an_ambiguity_ambiguous_when_the_family_does_not_prefer_visible_ones() {
    // Without the narrowing a repeated label stays a refusal, which is what a family whose
    // refusal is meant to name every match wants.
    let pool = [node("Row").on_screen(true), node("Row").on_screen(false)];
    let spec = TestSpec { prefer_on_screen: false, ..TestSpec::default() };
    assert!(matches!(resolve_with(&pool, Some("Row"), None, &spec), Err(Refusal::Ambiguous { .. })));
}
