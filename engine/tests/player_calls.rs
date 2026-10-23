//! Calls a real player makes that the scenarios do not: a clip that fails
//! while it is on screen, sounds, a late or stale end report, seeded rolls.

use masko_player_engine::{load, ClipKind, Command, Value};

fn delivery(extra_edges: &str) -> String {
    format!(
        r#"{{
  "deliverySchemaVersion": 1,
  "playerContract": 1,
  "requires": ["any-state"],
  "target": "web",
  "mode": "selected",
  "runtimeGraph": {{
    "runtimeGraphSchemaVersion": 1,
    "version": "2.1",
    "name": "Test",
    "initialNode": "idle",
    "autoPlay": true,
    "nodes": [{{"id": "idle", "name": "Idle"}}, {{"id": "working", "name": "Working"}}],
    "inputs": [{{"name": "behavior::working", "type": "boolean", "default": false}}],
    "edges": [
      {{"id": "idle-loop", "source": "idle", "target": "idle", "isLoop": true, "duration": 2,
        "videos": {{"webm": "a.webm"}}, "sound": {{"url": "hum.mp3", "loop": true}}}},
      {{"id": "work-loop", "source": "working", "target": "working", "isLoop": true, "duration": 2,
        "videos": {{"webm": "b.webm"}}}},
      {{"id": "to-work", "source": "idle", "target": "working", "isLoop": false, "duration": 1,
        "conditions": [{{"input": "behavior::working"}}], "videos": {{"webm": "c.webm"}},
        "sound": {{"url": "whoosh.mp3"}}}},
      {{"id": "to-idle", "source": "working", "target": "idle", "isLoop": false, "duration": 1,
        "conditions": [{{"input": "behavior::working", "value": false}}], "videos": {{"webm": "d.webm"}}}}
      {extra_edges}
    ]
  }}
}}"#
    )
}

fn shown(commands: &[Command]) -> Vec<String> {
    commands
        .iter()
        .filter_map(|c| match c {
            Command::ShowClip { edge, .. } => Some(edge.clone()),
            Command::ShowStill { pose } => Some(format!("still:{pose}")),
            _ => None,
        })
        .collect()
}

#[test]
fn start_shows_the_initial_loop_and_preloads_its_moves() {
    let mut e = load(&delivery("")).unwrap();
    let c = e.start(0);
    assert_eq!(shown(&c), ["idle-loop"]);
    assert!(c.contains(&Command::PoseEntered {
        pose: "idle".into()
    }));
    assert!(c.contains(&Command::Preload {
        edge: "to-work".into()
    }));
    assert!(c.contains(&Command::ShowClip {
        edge: "idle-loop".into(),
        kind: ClipKind::Pose,
        rate: 1.0
    }));
}

#[test]
fn a_move_that_fails_on_screen_skips_to_its_target() {
    let mut e = load(&delivery("")).unwrap();
    e.start(0);
    e.set("working", Value::Bool(true), 100);
    // An app's move waits for the loop to end.
    assert_eq!(e.state().next.map(|n| n.clip), Some("to-work".into()));
    let c = e.clip_ended("idle-loop", 2000);
    assert_eq!(shown(&c), ["to-work"]);
    let c = e.clip_failed("to-work", 2050);
    assert!(c.contains(&Command::Error {
        code: "clip_failed".into()
    }));
    assert!(c.contains(&Command::PoseEntered {
        pose: "working".into()
    }));
    assert_eq!(shown(&c), ["work-loop"]);
}

#[test]
fn a_pose_clip_that_fails_on_screen_becomes_a_still_that_keeps_counting() {
    let mut e = load(&delivery("")).unwrap();
    e.start(0);
    let c = e.clip_failed("idle-loop", 10);
    assert_eq!(shown(&c), ["still:idle"]);
    // The still lasts the failed clip's length, then counts as one loop and
    // the main loop is not asked for again.
    assert_eq!(e.next_wake(), Some(10 + 2000));
    let c = e.advance(2010);
    assert_eq!(shown(&c), ["still:idle"]);
    assert_eq!(e.value("node::loopCount"), Value::Number(1.0));
}

#[test]
fn sounds_follow_the_clips() {
    let mut e = load(&delivery("")).unwrap();
    let c = e.start(0);
    assert!(c.contains(&Command::PlaySound {
        edge: "idle-loop".into()
    }));
    // The looping sound is not started again on the next loop.
    let c = e.clip_ended("idle-loop", 2000);
    assert!(!c.iter().any(|c| matches!(c, Command::PlaySound { .. })));
    e.set("working", Value::Bool(true), 2100);
    let c = e.clip_ended("idle-loop", 4000);
    let stop = c.iter().position(|c| {
        *c == Command::StopSounds {
            only_looping: false,
        }
    });
    let play = c.iter().position(|c| {
        *c == Command::PlaySound {
            edge: "to-work".into(),
        }
    });
    assert!(
        stop.is_some() && play.is_some() && stop < play,
        "a move stops every sound before its own"
    );
}

#[test]
fn a_stale_end_report_is_ignored() {
    let mut e = load(&delivery("")).unwrap();
    e.start(0);
    let c = e.clip_ended("to-work", 500);
    assert!(c.is_empty());
    assert_eq!(e.state().clip.as_deref(), Some("idle-loop"));
}

#[test]
fn a_missing_end_report_is_covered_by_the_safety_net() {
    let mut e = load(&delivery("")).unwrap();
    e.start(0);
    e.clip_shown("idle-loop", 0);
    assert_eq!(e.next_wake(), Some(3000));
    let c = e.advance(3000);
    assert!(c.contains(&Command::Error {
        code: "missing_end".into()
    }));
    assert_eq!(shown(&c), ["idle-loop"]);
}

#[test]
fn seeded_rolls_repeat() {
    let extras = r#",
      {"id": "idle-yawn", "source": "idle", "target": "idle", "isLoop": true, "duration": 2, "videos": {"webm": "y.webm"}},
      {"id": "idle-stretch", "source": "idle", "target": "idle", "isLoop": true, "duration": 2, "videos": {"webm": "s.webm"}}"#;
    let run = |seed: u64| {
        let mut e = load(&delivery(extras)).unwrap();
        e.seed(seed);
        e.start(0);
        let mut seen = Vec::new();
        let mut t = 0;
        for _ in 0..30 {
            let clip = e.state().clip.unwrap();
            t += 2000;
            seen.extend(shown(&e.clip_ended(&clip, t)));
        }
        seen
    };
    assert_eq!(run(7), run(7));
    let picks = run(7);
    assert!(picks.iter().any(|c| c != "idle-loop"), "some extras play");
    assert!(
        picks.iter().filter(|c| *c == "idle-loop").count() > 10,
        "the main loop plays most"
    );
}

#[test]
fn a_late_call_runs_what_was_due_first() {
    let mut e = load(&delivery("")).unwrap();
    e.start(0);
    e.clip_shown("idle-loop", 0);
    // The player missed its wake-up: the safety net at 3000 runs before the
    // set at 3500.
    let c = e.set("working", Value::Bool(true), 3500);
    assert!(c.contains(&Command::Error {
        code: "missing_end".into()
    }));
    assert_eq!(e.clock(), 3500);
}

#[test]
fn the_safety_net_counts_from_when_the_clip_is_on_screen() {
    let mut e = load(&delivery("")).unwrap();
    e.start(0);
    e.clip_shown("idle-loop", 0);
    e.set("working", Value::Bool(true), 100);
    e.clip_ended("idle-loop", 2000);
    assert_eq!(e.state().clip.as_deref(), Some("to-work"));
    // The move's file takes 2.5 s to arrive: no safety net while it loads.
    assert_eq!(e.next_wake(), Some(2000 + 10_000));
    let c = e.clip_shown("to-work", 4500);
    assert!(c.is_empty());
    assert_eq!(e.state().shown_at, 4500);
    // 1 s clip plus the 1 s net, from when it showed.
    assert_eq!(e.next_wake(), Some(6500));
    let c = e.clip_ended("to-work", 5500);
    assert!(!c.iter().any(|c| matches!(c, Command::Error { .. })));
    assert_eq!(e.state().pose.as_deref(), Some("working"));
}

#[test]
fn a_clip_never_shown_counts_as_failed_after_10_seconds() {
    let mut e = load(&delivery("")).unwrap();
    e.start(0);
    e.clip_shown("idle-loop", 0);
    e.set("working", Value::Bool(true), 100);
    e.clip_ended("idle-loop", 2000);
    let c = e.advance(12_000);
    assert!(c.contains(&Command::Error {
        code: "clip_timeout".into()
    }));
    assert_eq!(e.state().pose.as_deref(), Some("working"));
}

#[test]
fn a_late_shown_report_for_another_clip_is_ignored() {
    let mut e = load(&delivery("")).unwrap();
    e.start(0);
    e.clip_shown("to-work", 10);
    assert_eq!(e.next_wake(), Some(10_000), "idle-loop still waits to show");
}

#[test]
fn a_failed_pose_clip_with_no_length_becomes_a_one_second_still() {
    let mut e = load(
        r#"{"deliverySchemaVersion":1,"playerContract":1,"requires":[],"target":"web","mode":"selected",
        "runtimeGraph":{"runtimeGraphSchemaVersion":1,"version":"2.1","name":"T","initialNode":"a","autoPlay":true,
        "nodes":[{"id":"a","name":"A"}],
        "edges":[{"id":"a-loop","source":"a","target":"a","isLoop":true,"duration":0,"videos":{"webm":"a.webm"}}]}}"#,
    )
    .unwrap();
    e.start(0);
    e.clip_failed("a-loop", 0);
    assert_eq!(e.state().clip.as_deref(), Some("still:a"));
    assert_eq!(e.next_wake(), Some(1000));
    let c = e.advance(5000);
    assert!(c.len() < 50, "a few stills, not an endless loop");
    assert_eq!(e.clock(), 5000);
}
