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

#[test]
fn an_instant_move_shows_no_move_and_plays_no_move_sound() {
    let edges = mv(
        "to-work",
        "idle",
        "working",
        WORKING,
        r#", "sound": {"url": "whoosh.mp3"}"#,
    );
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
fn an_instant_move_needs_no_clip() {
    let edges = r#", {"id": "to-work", "source": "idle", "target": "working", "isLoop": false,
        "duration": 1, "videos": {}, "conditions": [{"input": "behavior::working"}]}"#;
    let mut e = engine(&["idle", "working"], "", edges);
    let c = e.set("working", Value::Bool(true), INSTANT, 700);
    assert!(!c.iter().any(|c| matches!(c, Command::Error { .. })));
    assert_eq!(shown(&c), [("loop-working".to_owned(), ClipKind::Pose)]);
}

#[test]
fn a_value_set_off_is_never_instant() {
    let edges = mv("to-work", "idle", "working", WORKING, "")
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
    ) + r#", {"id": "any-work", "source": "*", "target": "working", "isLoop": false,
        "duration": 0, "videos": {}, "conditions": [{"input": "action::wave"}], "priority": 5}"#;
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
    let c = e.set("wave", Value::Bool(true), INSTANT, 300);
    assert_eq!(shown(&c), [("loop-working".to_owned(), ClipKind::Pose)]);
    assert_eq!(e.pending_fires(), ["action::wave"]);
}

#[test]
fn reset_ends_instant() {
    let edges = mv("to-work", "idle", "working", WORKING, "");
    let mut e = engine(&["idle", "working"], "", &edges);
    e.set("working", Value::Bool(true), INSTANT, 100);
    assert_eq!(e.state().pose.as_deref(), Some("working"));
    e.reset(200);
    e.clip_shown("loop-idle", 200);
    // Without instant again, the move waits for the end of the loop.
    let c = e.set("working", Value::Bool(true), SETTLED, 300);
    assert!(shown(&c).is_empty());
    let next = e.state().next.unwrap();
    assert_eq!((next.clip.as_str(), next.at), ("to-work", At::End));
}

#[test]
fn instant_starts_count_toward_the_clipless_cycle_guard() {
    let edges = mv(
        "there",
        "idle",
        "away",
        r#"{"input": "behavior::spin"}"#,
        "",
    ) + &mv("back", "away", "idle", r#"{"input": "behavior::spin"}"#, "");
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
fn the_persons_stop_interrupts_a_move_with_a_new_start() {
    let edges = mv("to-work", "idle", "working", WORKING, "")
        + &mv(
            "to-focus",
            "idle",
            "focus",
            r#"{"input": "behavior::pointerHover", "value": false}, {"input": "behavior::focus"}"#,
            r#", "priority": 1"#,
        );
    let mut e = engine(&["idle", "working", "focus"], "", &edges);
    e.hover(true, 100);
    e.set("focus", Value::Bool(true), SETTLED, 200);
    e.set("working", Value::Bool(true), SETTLED, 300);
    let c = e.clip_ended("loop-idle", 2000);
    assert_eq!(shown(&c), [("to-work".to_owned(), ClipKind::Move)]);
    e.clip_shown("to-work", 2000);
    // The pointer leaves mid-move: the way to focus is a new start, so it
    // interrupts the move at once and plays its own clip.
    let c = e.hover(false, 2400);
    assert!(c.contains(&Command::Interrupted {
        edge: "to-work".into()
    }));
    assert_eq!(shown(&c), [("to-focus".to_owned(), ClipKind::Move)]);
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
