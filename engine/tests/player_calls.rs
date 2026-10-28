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
    e.set("working", Value::Bool(true), false, 100);
    // An app's move waits for the loop to end.
    assert_eq!(e.state().next.map(|n| n.clip), Some("to-work".into()));
    let c = e.clip_ended("idle-loop", 2000);
    assert_eq!(shown(&c), ["to-work"]);
    let c = e.clip_failed("to-work", 2050);
    assert!(c.contains(&Command::Error {
        code: "clip_failed".into(),
        detail: Some("to-work".into())
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
    e.set("working", Value::Bool(true), false, 2100);
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
        code: "missing_end".into(),
        detail: Some("idle-loop".into())
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
    let c = e.set("working", Value::Bool(true), false, 3500);
    assert!(c.contains(&Command::Error {
        code: "missing_end".into(),
        detail: Some("idle-loop".into())
    }));
    assert_eq!(e.clock(), 3500);
}

#[test]
fn the_safety_net_counts_from_when_the_clip_is_on_screen() {
    let mut e = load(&delivery("")).unwrap();
    e.start(0);
    e.clip_shown("idle-loop", 0);
    e.set("working", Value::Bool(true), false, 100);
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
    e.set("working", Value::Bool(true), false, 100);
    e.clip_ended("idle-loop", 2000);
    let c = e.advance(12_000);
    assert!(c.contains(&Command::Error {
        code: "clip_timeout".into(),
        detail: Some("to-work".into())
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

fn sounds(commands: &[Command]) -> Vec<Command> {
    commands
        .iter()
        .filter(|c| matches!(c, Command::PlaySound { .. } | Command::StopSounds { .. }))
        .cloned()
        .collect()
}

fn release(nodes: &str, inputs: &str, edges: &str) -> String {
    format!(
        r#"{{"deliverySchemaVersion":1,"playerContract":1,"requires":[],
        "runtimeGraph":{{"runtimeGraphSchemaVersion":1,"initialNode":"idle",
        "nodes":[{nodes}],"inputs":[{inputs}],"edges":[{edges}]}}}}"#
    )
}

const WAVE: &str = r#",
      {"id": "idle-wave", "source": "idle", "target": "idle", "isLoop": true, "duration": 1,
        "conditions": [{"input": "action::wave"}], "videos": {"webm": "w.webm"}}"#;

#[test]
fn a_named_clip_that_fails_on_screen_spends_its_fire_after_its_stand_in() {
    let mut e = load(&delivery(WAVE)).unwrap();
    e.start(0);
    e.clip_shown("idle-loop", 0);
    e.fire("wave", false, 100);
    let c = e.clip_ended("idle-loop", 2000);
    assert_eq!(shown(&c), ["idle-wave"]);
    e.clip_shown("idle-wave", 2000);
    // The named clip fails on screen: the clip that ended last plays in its
    // place, and the fire it claimed waits for that clip's end.
    let c = e.clip_failed("idle-wave", 2100);
    assert_eq!(shown(&c), ["idle-loop"]);
    assert!(!c.iter().any(|c| matches!(c, Command::Spent { .. })));
    assert_eq!(e.pending_fires(), ["action::wave"]);
    let c = e.clip_ended("idle-loop", 4100);
    assert!(c.contains(&Command::Spent {
        name: "action::wave".into(),
        used: true
    }));
    assert_eq!(shown(&c), ["idle-loop"]);
    assert!(e.pending_fires().is_empty());
    // The next fire is not swallowed: it chooses the named clip again.
    e.fire("wave", false, 4200);
    let c = e.clip_ended("idle-loop", 6100);
    assert!(c.contains(&Command::Error {
        code: "clip_failed".into(),
        detail: Some("idle-wave".into())
    }));
    assert_eq!(shown(&c), ["idle-loop"]);
    let c = e.clip_ended("idle-loop", 8100);
    assert!(c.contains(&Command::Spent {
        name: "action::wave".into(),
        used: true
    }));
}

#[test]
fn set_refuses_numbers_that_are_not_finite() {
    let mut e = load(&release(
        r#"{"id": "idle"}"#,
        r#"{"name": "pace", "type": "number", "default": 1}"#,
        r#"{"id": "idle-loop", "source": "idle", "target": "idle", "isLoop": true, "duration": 2,
            "speed": 2, "speedInput": "pace", "videos": {"webm": "a.webm"}}"#,
    ))
    .unwrap();
    e.start(0);
    for v in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
        let c = e.set("pace", Value::Number(v), false, 10);
        assert_eq!(
            c,
            [Command::Error {
                code: "bad_value".into(),
                detail: Some("pace".into())
            }]
        );
        assert_eq!(e.value("pace"), Value::Number(1.0));
        let c = e.set("working", Value::Number(v), false, 10);
        assert_eq!(
            c,
            [Command::Error {
                code: "bad_value".into(),
                detail: Some("working".into())
            }]
        );
        assert_eq!(e.value("working"), Value::Bool(false));
    }
    // A finite number too large for the rate still gives a finite rate.
    e.set("pace", Value::Number(f64::MAX), false, 20);
    let c = e.clip_ended("idle-loop", 1000);
    assert!(c.contains(&Command::ShowClip {
        edge: "idle-loop".into(),
        kind: ClipKind::Pose,
        rate: 4.0
    }));
}

#[test]
fn a_priority_of_minus_zero_ranks_as_zero() {
    let mut e = load(&release(
        r#"{"id": "idle"}, {"id": "a"}, {"id": "b"}"#,
        r#"{"name": "behavior::working", "type": "boolean", "default": false}"#,
        r#"{"id": "idle-loop", "source": "idle", "target": "idle", "isLoop": true, "duration": 2, "videos": {"webm": "i.webm"}},
           {"id": "to-a", "source": "idle", "target": "a", "isLoop": false, "duration": 1, "priority": -0.0,
            "conditions": [{"input": "behavior::working"}], "videos": {"webm": "a.webm"}},
           {"id": "to-b", "source": "idle", "target": "b", "isLoop": false, "duration": 1, "priority": 0,
            "conditions": [{"input": "behavior::working"}], "videos": {"webm": "b.webm"}}"#,
    ))
    .unwrap();
    e.start(0);
    e.set("working", Value::Bool(true), false, 10);
    // Equal priorities: canvas order decides.
    assert_eq!(e.state().next.map(|n| n.clip), Some("to-a".into()));
}

const YAWN: &str = r#",
      {"id": "idle-yawn", "source": "idle", "target": "idle", "isLoop": true, "duration": 2,
        "videos": {"webm": "y.webm"}, "sound": {"url": "yawn.mp3", "loop": true}}"#;

#[test]
fn each_looping_sound_plays_once_while_the_mascot_stays_on_its_pose() {
    let mut e = load(&delivery(YAWN)).unwrap();
    // Main loop, extra, main loop, main loop, extra.
    e.use_rolls(vec![0.1, 0.9, 0.1]);
    let mut heard = sounds(&e.start(0));
    let mut t = 0;
    for _ in 0..4 {
        let clip = e.state().clip.unwrap();
        t += 2000;
        heard.extend(sounds(&e.clip_ended(&clip, t)));
    }
    assert_eq!(e.state().clip.as_deref(), Some("idle-yawn"));
    assert_eq!(
        heard,
        [
            Command::PlaySound {
                edge: "idle-loop".into()
            },
            Command::PlaySound {
                edge: "idle-yawn".into()
            }
        ]
    );
    // Entering another pose stops them; coming back starts them once more.
    e.set("working", Value::Bool(true), false, t);
    t += 2000;
    let c = e.clip_ended("idle-yawn", t);
    assert_eq!(
        sounds(&c),
        [
            Command::StopSounds {
                only_looping: false
            },
            Command::PlaySound {
                edge: "to-work".into()
            }
        ]
    );
    e.clip_ended("to-work", t + 1000);
    e.set("working", Value::Bool(false), false, t + 1000);
    e.clip_ended("work-loop", t + 3000);
    let c = e.clip_ended("to-idle", t + 4000);
    assert_eq!(
        sounds(&c),
        [Command::PlaySound {
            edge: "idle-loop".into()
        }]
    );
}

const DANCE: &str = r#",
      {"id": "dance", "source": "idle", "target": "working", "isLoop": false, "duration": 3,
        "conditions": [{"input": "action::dance"}], "videos": {"webm": "d.webm"},
        "sound": {"url": "drum.mp3", "loop": true}}"#;

/// Fires `dance` and plays the idle loop to its end: the dance move is on
/// screen with its looping drum.
fn dancing(e: &mut masko_player_engine::Engine, t: u64) {
    e.fire("dance", false, t);
    let c = e.clip_ended("idle-loop", t + 2000);
    assert_eq!(shown(&c), ["dance"]);
}

#[test]
fn calls_that_cut_a_move_report_it_and_stop_its_looping_sound() {
    let interrupted = Command::Interrupted {
        edge: "dance".into(),
    };
    let stop_looping = Command::StopSounds { only_looping: true };
    let mut e = load(&delivery(DANCE)).unwrap();
    e.start(0);

    dancing(&mut e, 0);
    let c = e.preview_show_pose("idle", 2500);
    assert_eq!(c.first(), Some(&interrupted));
    assert!(c.contains(&stop_looping));
    assert_eq!(e.state().pose.as_deref(), Some("idle"));

    dancing(&mut e, 2500);
    let c = e.reset(5000);
    assert_eq!(c.first(), Some(&interrupted));
    assert!(c.contains(&stop_looping));
    assert!(e.pending_fires().is_empty());

    // A second start keeps the fire the dance claimed for its target, no
    // longer claimed: entering the first pose starts the dance again at
    // once, and the fire is spent as usual, here when `working` is left.
    dancing(&mut e, 5000);
    let c = e.start(7500);
    assert_eq!(c.first(), Some(&interrupted));
    assert!(c.contains(&stop_looping));
    assert_eq!(shown(&c), ["dance"]);
    let c = e.clip_ended("dance", 10_500);
    assert!(c.contains(&Command::PoseEntered {
        pose: "working".into()
    }));
    assert!(c.contains(&Command::Spent {
        name: "action::dance".into(),
        used: true
    }));
    assert!(e.pending_fires().is_empty());
}

#[test]
fn preview_show_pose_stops_the_looping_sounds_of_the_pose_it_leaves() {
    let mut e = load(&delivery("")).unwrap();
    e.start(0);
    let c = e.preview_show_pose("working", 500);
    assert!(c.contains(&Command::StopSounds { only_looping: true }));
}

#[test]
fn fixed_rolls_that_run_out_fall_back_to_the_seeded_ones() {
    let extras = r#",
      {"id": "idle-yawn", "source": "idle", "target": "idle", "isLoop": true, "duration": 2, "videos": {"webm": "y.webm"}}"#;
    let mut e = load(&delivery(extras)).unwrap();
    e.use_rolls(vec![0.1]);
    e.start(0);
    let mut seen = Vec::new();
    let mut t = 0;
    for _ in 0..40 {
        let clip = e.state().clip.unwrap();
        t += 2000;
        seen.extend(shown(&e.clip_ended(&clip, t)));
    }
    assert_eq!(seen[0], "idle-yawn", "the fixed roll comes first");
    assert!(
        seen[1..].iter().any(|c| c == "idle-yawn"),
        "then seeded rolls"
    );
}

#[test]
fn play_times_at_the_end_of_the_clock_do_not_overflow() {
    let end = u64::MAX;
    let mut e = load(&delivery(DANCE)).unwrap();
    e.start(end - 10);
    e.clip_shown("idle-loop", end - 10);
    e.set("working", Value::Bool(true), false, end - 5);
    e.fire("dance", false, end - 5);
    e.fire("action::click", false, end - 4);
    e.set("behavior::pointerHover", Value::Bool(true), false, end - 3);
    e.clip_ended("idle-loop", end - 2);
    let clip = e.state().clip.unwrap();
    e.clip_shown(&clip, end - 1);
    e.clip_failed(&clip, end);
    e.advance(end);
    e.preview_show_pose("working", end);
    e.preview_play_move("to-idle", end);
    e.reset(end);
    e.advance(end);
    assert_eq!(e.clock(), end);
    assert!(e.next_wake().is_none_or(|t| t == end));
}
