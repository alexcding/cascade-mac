//! Resolving an accessibility label to the point that taps it, and planning the scroll that
//! brings it into view. Ported from `apps/server/src/device/uiTreeTargeting.test.ts`.

use crate::device::{
    contracts::{DeviceUiFrame, DeviceUiNode, DeviceUiPoint},
    ui_targeting::{
        find_target, plan_scroll_step, read_tap_request, DeviceTapInput, DeviceTapRequest, DeviceUiTarget,
        DeviceUiTargetError,
    },
};

fn frame(x: f64, y: f64, width: f64, height: f64) -> DeviceUiFrame {
    DeviceUiFrame { x, y, width, height }
}

fn point(x: f64, y: f64) -> DeviceUiPoint {
    DeviceUiPoint { x, y }
}

/// A node with the TS helper's defaults: a full-screen frame and nothing else.
fn node(role: &str) -> DeviceUiNode {
    DeviceUiNode {
        role: role.into(),
        subrole: None,
        label: None,
        value: None,
        frame: frame(0.0, 0.0, 402.0, 874.0),
        activation_point: None,
        identifier: None,
        enabled: Some(true),
        focused: None,
        selected: None,
        placeholder: None,
        unframed: None,
        children: Vec::new(),
    }
}

trait TargetNodeExt: Sized {
    fn subrole(self, subrole: &str) -> Self;
    fn label(self, label: &str) -> Self;
    fn value(self, value: &str) -> Self;
    fn frame(self, x: f64, y: f64, width: f64, height: f64) -> Self;
    fn activation_point(self, x: f64, y: f64) -> Self;
    fn children(self, children: Vec<DeviceUiNode>) -> Self;
}

impl TargetNodeExt for DeviceUiNode {
    fn subrole(mut self, subrole: &str) -> Self {
        self.subrole = Some(subrole.into());
        self
    }

    fn label(mut self, label: &str) -> Self {
        self.label = Some(label.into());
        self
    }

    fn value(mut self, value: &str) -> Self {
        self.value = Some(value.into());
        self
    }

    fn frame(mut self, x: f64, y: f64, width: f64, height: f64) -> Self {
        self.frame = frame(x, y, width, height);
        self
    }

    fn activation_point(mut self, x: f64, y: f64) -> Self {
        self.activation_point = Some(point(x, y));
        self
    }

    fn children(mut self, children: Vec<DeviceUiNode>) -> Self {
        self.children = children;
        self
    }
}

fn target(label: &str) -> DeviceUiTarget {
    DeviceUiTarget { label: Some(label.into()), ..DeviceUiTarget::default() }
}

/// The real Settings > Developer screen, measured on an iPhone 17 Pro.
fn dark_appearance() -> DeviceUiNode {
    node("CheckBox")
        .subrole("Switch")
        .label("Dark Appearance")
        .value("0")
        .frame(36.0, 184.0, 330.0, 28.0)
        .activation_point(336.5, 198.0)
}

fn settings_screen() -> DeviceUiNode {
    node("Application").label("Settings").children(vec![
        dark_appearance(),
        node("Button").label("L4S").frame(20.0, 692.0, 362.0, 53.0),
    ])
}

fn refusal(root: &DeviceUiNode, target: &DeviceUiTarget) -> DeviceUiTargetError {
    find_target(root, target).expect_err("expected a refusal")
}

#[test]
fn finds_a_switch_by_label_and_returns_its_own_tap_point_and_state() {
    let screen = settings_screen();
    let found = find_target(&screen, &target("Dark Appearance")).unwrap();
    assert_eq!(found.point, point(336.5, 198.0));
    assert_eq!(found.node.value.as_deref(), Some("0"));
    assert_eq!(found.node.subrole.as_deref(), Some("Switch"));
}

#[test]
fn matches_case_insensitively_and_ignores_surrounding_space() {
    let screen = settings_screen();
    assert_eq!(find_target(&screen, &target("  dark appearance ")).unwrap().point, point(336.5, 198.0));
}

#[test]
fn prefers_an_exact_label_over_a_longer_one_that_merely_contains_it() {
    // "Developer" must not be ambiguous just because "Developer Mode" exists.
    let screen = node("Application").children(vec![
        node("Button").label("Developer").frame(0.0, 100.0, 402.0, 50.0),
        node("Button").label("Developer Mode").frame(0.0, 200.0, 402.0, 50.0),
    ]);
    assert_eq!(find_target(&screen, &target("Developer")).unwrap().point, point(201.0, 125.0));
}

#[test]
fn uses_role_to_disambiguate_a_label_that_appears_twice() {
    let screen = node("Application").children(vec![
        node("Heading").label("Wi-Fi").frame(0.0, 100.0, 402.0, 40.0),
        node("CheckBox")
            .subrole("Switch")
            .label("Wi-Fi")
            .value("1")
            .frame(0.0, 200.0, 402.0, 44.0)
            .activation_point(336.0, 222.0),
    ]);
    let error = refusal(&screen, &target("Wi-Fi"));
    assert!(error.message.contains("2 elements match"), "{}", error.message);
    assert!(!error.not_found);

    let with_role = |role: &str| DeviceUiTarget { role: Some(role.into()), ..target("Wi-Fi") };
    assert_eq!(find_target(&screen, &with_role("Switch")).unwrap().point, point(336.0, 222.0));
    assert_eq!(find_target(&screen, &with_role("Heading")).unwrap().point, point(201.0, 120.0));
}

#[test]
fn names_the_elements_on_screen_when_the_label_matches_nothing() {
    let screen = settings_screen();
    let error = refusal(&screen, &target("Airplane Mode"));
    // The list has to reach the agent through the message: every transport between here and the
    // model carries only that.
    assert!(error.message.contains("Dark Appearance"), "{}", error.message);
    assert!(!error.candidates.is_empty());
    assert!(error.not_found);
}

#[test]
fn rejects_an_empty_label_rather_than_matching_everything() {
    let screen = settings_screen();
    let error = refusal(&screen, &target("   "));
    assert!(error.message.contains("non-empty label"), "{}", error.message);
}

#[test]
fn accepts_a_label_with_or_without_a_role() {
    assert_eq!(
        read_tap_request(&DeviceTapInput { label: Some("Dark Appearance".into()), ..Default::default() }),
        Ok(DeviceTapRequest::Element(DeviceUiTarget { label: Some("Dark Appearance".into()), identifier: None, role: None }))
    );
    let with_role =
        read_tap_request(&DeviceTapInput { label: Some("Wi-Fi".into()), role: Some("Switch".into()), ..Default::default() });
    match with_role {
        Ok(DeviceTapRequest::Element(found)) => assert_eq!(found.role.as_deref(), Some("Switch")),
        other => panic!("expected an element request, got {other:?}"),
    }
}

#[test]
fn accepts_an_explicit_point() {
    assert_eq!(
        read_tap_request(&DeviceTapInput { x: Some(10.0), y: Some(20.0), ..Default::default() }),
        Ok(DeviceTapRequest::Point { x: 10.0, y: 20.0 })
    );
}

#[test]
fn refuses_shapes_that_are_neither_and_says_which_to_use() {
    let neither = read_tap_request(&DeviceTapInput::default()).unwrap_err();
    assert!(neither.message.contains("an element (identifier or label"), "{}", neither.message);
    assert!(neither.message.contains("or both x and y"), "{}", neither.message);

    let half = read_tap_request(&DeviceTapInput { x: Some(10.0), ..Default::default() }).unwrap_err();
    assert!(half.message.contains("both x and y"), "{}", half.message);

    // Both forms at once is ambiguous: silently preferring one would make the other's presence a
    // lie about what got tapped.
    let both = read_tap_request(&DeviceTapInput {
        label: Some("A".into()),
        x: Some(1.0),
        y: Some(2.0),
        ..Default::default()
    })
    .unwrap_err();
    assert!(both.message.contains("not both"), "{}", both.message);
}

fn screen() -> DeviceUiNode {
    node("Application").frame(0.0, 0.0, 402.0, 874.0)
}

#[test]
fn ignores_a_keyboard_with_no_usable_frame_when_planning_a_swipe() {
    let unframed = {
        let mut keyboard = node("Keyboard").frame(0.0, 0.0, 0.0, 0.0);
        keyboard.unframed = Some(true);
        keyboard
    };
    let flat = node("Keyboard").frame(0.0, 0.0, 402.0, 0.0);
    for keyboard in [unframed, flat] {
        let obscured = screen().children(vec![keyboard]);
        let below = node("Button").frame(0.0, 1_500.0, 402.0, 44.0);
        let step = plan_scroll_step(&below, &obscured).unwrap().expect("a swipe");
        assert!(step.from_y >= 0.0);
        assert!(step.to_y >= 0.0);
        assert!(step.from_y <= 874.0);
        assert!(step.to_y <= 874.0);
    }
}

#[test]
fn refuses_a_swipe_when_a_high_keyboard_covers_the_safe_band() {
    let obscured = screen().children(vec![node("Keyboard").frame(0.0, 50.0, 402.0, 824.0)]);
    let below = node("Button").frame(0.0, 1_500.0, 402.0, 44.0);
    let error = plan_scroll_step(&below, &obscured).unwrap_err();
    assert!(error.message.contains("dismiss it before scrolling"), "{}", error.message);
}

#[test]
fn treats_a_row_under_the_status_bar_as_needing_a_scroll_not_as_visible() {
    // On screen by coordinates, untappable in practice: the band exists so a target does not end
    // up beneath the status bar or home indicator.
    let under_status_bar = node("Button").frame(0.0, 10.0, 402.0, 30.0);
    assert!(plan_scroll_step(&under_status_bar, &screen()).unwrap().is_some());
}

#[test]
fn swipes_upward_to_pull_a_target_below_the_fold_into_view() {
    let below = node("Button").frame(0.0, 1_500.0, 402.0, 44.0);
    let step = plan_scroll_step(&below, &screen()).unwrap().expect("a swipe");
    // Content follows the finger, so reaching downward means dragging up.
    assert!(step.to_y < step.from_y);
}

#[test]
fn swipes_downward_to_pull_a_target_above_the_fold_into_view() {
    let above = node("Button").frame(0.0, -600.0, 402.0, 44.0);
    let step = plan_scroll_step(&above, &screen()).unwrap().expect("a swipe");
    assert!(step.to_y > step.from_y);
}

#[test]
fn never_swipes_further_than_the_gap_so_a_near_target_is_not_flung_past() {
    let just_below = node("Button").frame(0.0, 800.0, 402.0, 44.0);
    let step = plan_scroll_step(&just_below, &screen()).unwrap().expect("a swipe");
    let travelled = (step.to_y - step.from_y).abs();
    let gap = (822.0_f64 - 437.0).abs();
    assert!(travelled <= gap + 1.0, "travelled {travelled}, gap {gap}");
}

#[test]
fn keeps_the_swipe_inside_the_screen_so_the_gesture_is_deliverable() {
    let far_below = node("Button").frame(0.0, 5_000.0, 402.0, 44.0);
    let step = plan_scroll_step(&far_below, &screen()).unwrap().expect("a swipe");
    for y in [step.from_y, step.to_y] {
        assert!(y >= 0.0);
        assert!(y <= 874.0);
    }
}

#[test]
fn reports_an_off_screen_match_rather_than_refusing_it_outright() {
    let root = screen().children(vec![node("Button").label("Far Below").frame(0.0, 1_800.0, 402.0, 50.0)]);
    let found = find_target(&root, &target("Far Below")).unwrap();
    assert!(!found.on_screen);
}

#[test]
fn prefers_the_visible_match_when_a_label_repeats_down_a_long_list() {
    let root = screen().children(vec![
        node("Button").label("Row").frame(0.0, 400.0, 402.0, 44.0),
        node("Button").label("Row").frame(0.0, 2_000.0, 402.0, 44.0),
    ]);
    assert_eq!(find_target(&root, &target("Row")).unwrap().node.frame.y, 400.0);
}
