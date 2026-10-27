//! `instant` and the person's stop (rules.md 5.8, 5.2), on the commands a
//! player receives: what a scenario trace does not show, such as sounds, clip
//! kinds and the clipless-cycle guard.

use masko_player_engine::{load, At, ClipKind, Command, Engine, Value};

const SETTLED: bool = false;
const INSTANT: bool = true;

/// A graph of poses with 2 s loops. `idle` loops with a looping sound, and
/// each move is a 1 s clip unless `videos` is empty.
fn engine(nodes: &[&str], inputs: &str, edges: &str) -> Engine {
    let poses: Vec<String> = nodes
        .iter()
        .map(|n| format!(r#"{{"id": "{n}", "name": "{n}"}}"#))
        .collect();
    let loops: Vec<String> = nodes
        .iter()
        .map(|n| {
            let sound = if *n == "idle" {
                r#", "sound": {"url": "hum.mp3", "loop": true}"#
            } else {
                ""
            };
            format!(
                r#"{{"id": "loop-{n}", "source": "{n}", "target": "{n}", "isLoop": true,
                    "duration": 2, "videos": {{"webm": "{n}.webm"}}{sound}}}"#
            )
        })
        .collect();
    let json = format!(
        r#"{{
  "deliverySchemaVersion": 1,
  "playerContract": 1,
  "requires": ["any-state"],
  "runtimeGraph": {{
    "runtimeGraphSchemaVersion": 1,
    "initialNode": "idle",
    "nodes": [{}],
    "inputs": [{inputs}],
    "edges": [{}{edges}]
  }}
}}"#,
        poses.join(", "),
        loops.join(", ")
    );
    let mut e = load(&json).unwrap();
    e.start(0);
    e.clip_shown("loop-idle", 0);
    e
}

fn mv(id: &str, from: &str, to: &str, conditions: &str, extra: &str) -> String {
    format!(
        r#", {{"id": "{id}", "source": "{from}", "target": "{to}", "isLoop": false, "duration": 1,
             "videos": {{"webm": "{id}.webm"}}, "conditions": [{conditions}]{extra}}}"#
    )
}

fn shown(commands: &[Command]) -> Vec<(String, ClipKind)> {
    commands
        .iter()
        .filter_map(|c| match c {
            Command::ShowClip { edge, kind, .. } => Some((edge.clone(), *kind)),
            _ => None,
        })
        .collect()
}

fn entered(commands: &[Command]) -> usize {
    commands
        .iter()
        .filter(|c| matches!(c, Command::PoseEntered { .. }))
        .count()
}

const WORKING: &str = r#"{"input": "behavior::working"}"#;

/// An Any State edge to `target`.
fn any(id: &str, target: &str, conditions: &str, extra: &str) -> String {
    format!(
        r#", {{"id": "{id}", "source": "*", "target": "{target}", "isLoop": false,
             "duration": 0, "videos": {{}}, "conditions": [{conditions}]{extra}}}"#
    )
}

const WHOOSH: &str = r#", "sound": {"url": "whoosh.mp3"}"#;
const FIRST: &str = r#", "priority": 1"#;

#[test]
fn an_instant_any_state_start_shows_no_move_and_plays_no_move_sound() {
    let edges = mv("to-work", "idle", "working", WORKING, WHOOSH)
        + &any("any-work", "working", WORKING, FIRST);
    let mut e = engine(&["idle", "working"], "", &edges);
    let c = e.set("working", Value::Bool(true), INSTANT, 700);
    assert_eq!(shown(&c), [("loop-working".to_owned(), ClipKind::Pose)]);
    assert!(c.contains(&Command::PoseEntered {
        pose: "working".into()
    }));
    assert!(
        !c.iter().any(|c| matches!(c, Command::PlaySound { .. })),
        "no move sound"
    );
    // Entering stops looping sounds and lets one-shot sounds finish.
    assert!(c.contains(&Command::StopSounds { only_looping: true }));
    assert!(!c.contains(&Command::StopSounds {
        only_looping: false
    }));
    assert_eq!(e.state().pose.as_deref(), Some("working"));
}

#[test]
fn an_instant_move_plays_its_own_clip_at_once() {
    let edges = mv("to-work", "idle", "working", WORKING, WHOOSH);
    let mut e = engine(&["idle", "working"], "", &edges);
    // Mid-loop: the move starts now, as a person's start does, with its clip
    // and its sound.
    let c = e.set("working", Value::Bool(true), INSTANT, 700);
    assert_eq!(shown(&c), [("to-work".to_owned(), ClipKind::Move)]);
    assert!(c.contains(&Command::StopSounds {
        only_looping: false
    }));
    assert!(c.contains(&Command::PlaySound {
        edge: "to-work".into()
    }));
    assert_eq!(e.state().pose.as_deref(), Some("idle"));
}

#[test]
fn an_instant_any_state_start_reaches_a_pose_no_route_reaches() {
    let edges = any("any-work", "working", WORKING, "");
    let mut e = engine(&["idle", "working"], "", &edges);
    // No move leads to working: without instant the edge is skipped (rules.md 6.3).
    let c = e.set("working", Value::Bool(true), SETTLED, 300);
    assert!(shown(&c).is_empty());
    assert!(e.state().next.is_none());
    let c = e.set("working", Value::Bool(true), INSTANT, 400);
    assert!(!c.iter().any(|c| matches!(c, Command::Error { .. })));
    assert_eq!(shown(&c), [("loop-working".to_owned(), ClipKind::Pose)]);
}

#[test]
fn a_value_set_off_is_never_instant() {
    let edges = mv("to-work", "idle", "working", WORKING, "")
        + &any("any-work", "working", WORKING, FIRST)
        + &mv(
            "to-idle",
            "working",
            "idle",
            r#"{"input": "behavior::working", "value": false}"#,
            "",
        );
    let mut e = engine(&["idle", "working"], "", &edges);
    e.set("working", Value::Bool(true), INSTANT, 100);
    e.clip_shown("loop-working", 100);
    // The way back holds because working is off: off is never instant, so it
    // waits for the end of the loop and plays its clip.
    let c = e.set("working", Value::Bool(false), INSTANT, 600);
    assert!(shown(&c).is_empty());
    let next = e.state().next.unwrap();
    assert_eq!((next.clip.as_str(), next.at), ("to-idle", At::End));
}

#[test]
fn firing_a_pending_name_again_with_instant_makes_it_instant() {
    let edges = mv(
        "to-work",
        "idle",
        "working",
        r#"{"input": "action::wave"}"#,
        "",
    ) + &any(
        "any-work",
        "working",
        r#"{"input": "action::wave"}"#,
        r#", "priority": 5"#,
    );
    let mut e = engine(&["idle", "working"], "", &edges);
    e.fire("wave", SETTLED, 100);
    let next = e.state().next.unwrap();
    assert_eq!((next.clip.as_str(), next.at), ("to-work", At::End));
    let c = e.fire("wave", INSTANT, 200);
    assert_eq!(shown(&c), [("loop-working".to_owned(), ClipKind::Pose)]);
    // The start claimed it: it lasts through the target's first loop.
    assert_eq!(e.pending_fires(), ["action::wave"]);
}

#[test]
fn a_trigger_set_with_instant_fires_with_instant() {
    let inputs = r#"{"name": "action::wave", "type": "trigger", "default": false}"#;
    let edges = mv(
        "to-work",
        "idle",
        "working",
        r#"{"input": "action::wave"}"#,
        "",
    );
    let mut e = engine(&["idle", "working"], inputs, &edges);
    // An app's fire waits for the end of the loop; with instant it starts now.
    let c = e.set("wave", Value::Bool(true), INSTANT, 300);
    assert_eq!(shown(&c), [("to-work".to_owned(), ClipKind::Move)]);
    assert_eq!(e.pending_fires(), ["action::wave"]);
}

#[test]
fn reset_ends_instant() {
    let edges =
        mv("to-work", "idle", "working", WORKING, "") + &any("any-work", "working", WORKING, FIRST);
    let mut e = engine(&["idle", "working"], "", &edges);
    e.set("working", Value::Bool(true), INSTANT, 100);
    assert_eq!(e.state().pose.as_deref(), Some("working"));
    e.reset(200);
    e.clip_shown("loop-idle", 200);
    // Without instant again, the route waits for the end of the loop.
    let c = e.set("working", Value::Bool(true), SETTLED, 300);
    assert!(shown(&c).is_empty());
    let next = e.state().next.unwrap();
    assert_eq!((next.clip.as_str(), next.at), ("to-work", At::End));
}

#[test]
fn instant_starts_count_toward_the_clipless_cycle_guard() {
    // An instant cut to away, and a way back that has no clip.
    let spin = r#"{"input": "behavior::spin"}"#;
    let edges = any("any-away", "away", spin, "")
        + r#", {"id": "back", "source": "away", "target": "idle", "isLoop": false,
        "duration": 1, "videos": {}, "conditions": [{"input": "behavior::spin"}], "priority": 1}"#;
    let mut e = engine(&["idle", "away"], "", &edges);
    let c = e.set("behavior::spin", Value::Bool(true), INSTANT, 100);
    // With idle entered at the start, the 33rd pose within the second stops
    // the chain there, and its loop shows (rules.md 9.4).
    assert_eq!(entered(&c), 32);
    assert!(c.contains(&Command::Error {
        code: "clipless_cycle".into(),
        detail: Some("idle".into())
    }));
    assert_eq!(shown(&c), [("loop-idle".to_owned(), ClipKind::Pose)]);
}

#[test]
fn the_persons_stop_waits_for_a_move_then_starts_at_its_end() {
    let edges = mv("to-work", "idle", "working", WORKING, "")
        + &mv(
            "work-to-focus",
            "working",
            "focus",
            r#"{"input": "behavior::pointerHover", "value": false}, {"input": "behavior::focus"}"#,
            "",
        );
    let mut e = engine(&["idle", "working", "focus"], "", &edges);
    e.hover(true, 100);
    e.set("focus", Value::Bool(true), SETTLED, 200);
    e.set("working", Value::Bool(true), SETTLED, 300);
    let c = e.clip_ended("loop-idle", 2000);
    assert_eq!(shown(&c), [("to-work".to_owned(), ClipKind::Move)]);
    e.clip_shown("to-work", 2000);
    // The pointer leaves mid-move: only an instant start cuts a move, so the
    // move plays on (rules.md 10).
    let c = e.hover(false, 2400);
    assert!(!c.iter().any(|c| matches!(c, Command::Interrupted { .. })));
    assert!(shown(&c).is_empty());
    // Its end is a boundary: the way to focus starts there at once.
    let c = e.clip_ended("to-work", 3000);
    assert_eq!(shown(&c), [("work-to-focus".to_owned(), ClipKind::Move)]);
}

#[test]
fn a_persons_start_during_a_move_waits_and_an_instant_one_cuts_it() {
    let hover = r#"{"input": "behavior::pointerHover"}"#;
    let edges = mv("to-work", "idle", "working", WORKING, "")
        + &mv("to-wave", "idle", "wave", hover, r#", "priority": 1"#);
    let mut e = engine(&["idle", "working", "wave"], "", &edges);
    e.set("working", Value::Bool(true), SETTLED, 100);
    e.clip_ended("loop-idle", 2000);
    e.clip_shown("to-work", 2000);
    let c = e.hover(true, 2300);
    assert!(c.is_empty(), "the hover waits for the move's end");
    let c = e.set("behavior::pointerHover", Value::Bool(true), INSTANT, 2400);
    assert!(c.contains(&Command::Interrupted {
        edge: "to-work".into()
    }));
    assert_eq!(shown(&c), [("to-wave".to_owned(), ClipKind::Move)]);
}

#[test]
fn the_persons_stop_keeps_the_moment_of_a_start_already_decided() {
    let edges = mv("to-work", "idle", "working", WORKING, "");
    let mut e = engine(&["idle", "working"], "", &edges);
    e.set("working", Value::Bool(true), SETTLED, 100);
    e.hover(true, 200);
    let c = e.hover(false, 300);
    assert!(shown(&c).is_empty(), "a passing pointer does not hurry it");
    let next = e.state().next.unwrap();
    assert_eq!((next.clip.as_str(), next.at), ("to-work", At::End));
}
