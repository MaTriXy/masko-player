//! Every rule of `spec/rules.md`, sections 2 to 13, with no video, network or
//! screen. A player calls the engine with play time in milliseconds and
//! carries out the commands it returns; it reports when a clip ends or fails.
//!
//! The engine owns the clock-driven work: node timers, the safety net and the
//! end of a still. Only the player can say when a video clip ends.

use crate::format::{Condition, Edge, Op, RawValue, Release};
use serde::Serialize;
use std::collections::{HashMap, HashSet, VecDeque};

/// A still pose (no clip) is shown for this long before it counts as one
/// loop (rules.md 7.4).
const STILL_MS: u64 = 1000;
/// A clip whose end is not reported is ended this long after its expected
/// length (rules.md 9.3).
const SAFETY_MS: u64 = 1000;
/// A clip not on screen this long after the engine asked for it counts as a
/// clip that cannot play (rules.md 9.3).
const LOAD_MS: u64 = 10_000;
/// Poses entered within one second of play time before the engine stops
/// following moves from them for the rest of that second (rules.md 9.4).
const MAX_CHAIN: u32 = 32;
const CHAIN_MS: u64 = 1000;

const FAMILIES: &[&str] = &[
    "rest",
    "attention",
    "working",
    "focus",
    "celebrate",
    "error",
    "waiting",
    "pointerHover",
    "heldContact",
    "heldShake",
    "falling",
    "ambient",
    "rhythm",
];

/// Inputs set by the person, whose starts happen at once (rules.md 5.2).
const PERSON: &[&str] = &[
    "behavior::pointerHover",
    "action::click",
    "behavior::heldContact",
    "behavior::heldShake",
    "behavior::falling",
];

/// A value the app sets or a condition reads.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(untagged)]
pub enum Value {
    Bool(bool),
    Number(f64),
}

impl Value {
    pub fn number(self) -> f64 {
        match self {
            Value::Bool(b) => f64::from(u8::from(b)),
            Value::Number(n) => n,
        }
    }
}

impl From<RawValue> for Value {
    fn from(v: RawValue) -> Self {
        match v {
            RawValue::Bool(b) => Value::Bool(b),
            RawValue::Number(n) => Value::Number(n),
        }
    }
}

/// What a clip on screen is for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ClipKind {
    /// A pose's own clip (a loop, a named clip or an extra).
    Pose,
    /// A move from one pose to another.
    Move,
}

/// What the player must do, in order. As JSON: `{"type": "showClip", ...}`.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum Command {
    /// Show this edge's clip from its first frame now, at this rate. Showing
    /// the clip already on screen again means: loop it.
    ShowClip {
        edge: String,
        kind: ClipKind,
        rate: f64,
    },
    /// Show this pose's still image now: it has no clip that can play.
    ShowStill { pose: String },
    /// Load this edge's clip so it can show without delay (rules.md 9.7).
    Preload { edge: String },
    /// Play this edge's sound (rules.md 9.6).
    PlaySound { edge: String },
    /// Stop sounds: only looping ones, or all of them (rules.md 9.6).
    StopSounds { only_looping: bool },
    /// The mascot is on this pose now.
    PoseEntered { pose: String },
    /// A person's start stopped this move (rules.md 10.1).
    Interrupted { edge: String },
    /// A fire is used up: by a start, or unused (rules.md 3.3).
    Spent { name: String, used: bool },
    /// Something went wrong, with a code from rules.md and what it is about:
    /// the edge of a clip error, the name of a refused value, the pose of a
    /// pose error.
    Error {
        code: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        detail: Option<String>,
    },
}

/// When a decided start happens. As JSON: a play time, or `"end"`.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(untagged)]
pub enum At {
    Time(u64),
    /// At the end of the clip on screen.
    #[serde(serialize_with = "end")]
    End,
}

fn end<S: serde::Serializer>(s: S) -> Result<S::Ok, S::Error> {
    s.serialize_str("end")
}

/// The engine's view of what is on screen, for players, tests and tools.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct State {
    pub clock: u64,
    pub pose: Option<String>,
    /// The edge on screen, or `still:<pose>`.
    pub clip: Option<String>,
    /// Whether the clip on screen is a move (else a pose clip or a still).
    pub moving: bool,
    /// When the clip on screen was shown, in play time.
    pub shown_at: u64,
    /// How long it should last at its rate, in milliseconds.
    pub expected_ms: u64,
    /// The decided start not yet shown.
    pub next: Option<Next>,
}

/// A decided start: its first clip and its moment.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Next {
    pub clip: String,
    pub at: At,
}

#[derive(Debug, Clone, PartialEq)]
struct Claim {
    pose: String,
    clip: Option<usize>,
    route: bool,
}

#[derive(Debug, Clone, Copy)]
struct Plan {
    edge: usize,
    hop: usize,
    route: bool,
}

impl Plan {
    fn target<'a>(&self, g: &'a Graph) -> &'a str {
        &g.edges[self.edge].target
    }
}

enum Decision {
    Stay,
    Start(Plan),
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum ScreenKind {
    Pose,
    Move,
    Still,
}

#[derive(Debug, Clone, Copy)]
struct Screen {
    kind: ScreenKind,
    edge: Option<usize>,
    /// When the clip was asked for, then when the player reported it on
    /// screen (`visible`).
    shown: u64,
    visible: bool,
    /// When a still ends, or how long the clip should last at its rate.
    nominal: u64,
}

#[derive(Debug, Clone, Copy)]
struct Decided {
    plan: Plan,
    at: At,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Due {
    StillEnd,
    Safety,
    LoadTimeout,
    Wake,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Boundary {
    None,
    Entry,
    End,
}

/// Where the extra-clip rolls come from (rules.md 7.3): the fixed numbers
/// first, for scenarios, then xorshift64* once they run out.
struct Rolls {
    fixed: VecDeque<f64>,
    seed: u64,
}

impl Rolls {
    fn next(&mut self) -> f64 {
        if let Some(r) = self.fixed.pop_front() {
            return r;
        }
        let mut x = self.seed;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.seed = x;
        let r = x.wrapping_mul(0x2545_F491_4F6C_DD1D) >> 11;
        r as f64 / (1u64 << 53) as f64
    }
}

struct Graph {
    initial: String,
    nodes: HashSet<String>,
    inputs: HashMap<String, (String, RawValue)>,
    edges: Vec<Edge>,
    /// Each edge's expected length at its own speed, in milliseconds.
    length: Vec<u64>,
    by_id: HashMap<String, usize>,
}

impl Graph {
    fn new(r: Release) -> Self {
        let length = r
            .edges
            .iter()
            .map(|e| round_ms(e.duration / e.speed * 1000.0))
            .collect();
        let by_id = r
            .edges
            .iter()
            .enumerate()
            .map(|(i, e)| (e.id.clone(), i))
            .collect();
        Graph {
            initial: r.initial_node,
            nodes: r.nodes.into_iter().collect(),
            inputs: r
                .inputs
                .into_iter()
                .map(|i| (i.name, (i.kind, i.default)))
                .collect(),
            edges: r.edges,
            length,
            by_id,
        }
    }

    fn moves_from<'a>(&'a self, pose: &'a str) -> impl Iterator<Item = usize> + 'a {
        self.edges
            .iter()
            .enumerate()
            .filter(move |(_, e)| e.source.as_deref() == Some(pose) && !e.is_loop)
            .map(|(i, _)| i)
    }

    fn pose_clips<'a>(&'a self, pose: &'a str) -> impl Iterator<Item = usize> + 'a {
        self.edges
            .iter()
            .enumerate()
            .filter(move |(_, e)| e.source.as_deref() == Some(pose) && e.is_loop)
            .map(|(i, _)| i)
    }

    fn is_number(&self, name: &str) -> bool {
        self.inputs.get(name).is_some_and(|(k, _)| k == "number")
    }

    /// Fewest moves with clips from `start` to `target`, never through the
    /// poses in `seen` (rules.md 6.2).
    fn hops(&self, start: &str, target: &str, seen: &[&str]) -> Option<u32> {
        let mut visited: HashSet<&str> = seen.iter().copied().collect();
        visited.insert(start);
        let mut queue: VecDeque<(&str, u32)> = VecDeque::from([(start, 0)]);
        while let Some((node, n)) = queue.pop_front() {
            if node == target {
                return Some(n);
            }
            for i in self.moves_from(node) {
                let e = &self.edges[i];
                if e.has_video && !visited.contains(e.target.as_str()) {
                    visited.insert(e.target.as_str());
                    queue.push_back((e.target.as_str(), n + 1));
                }
            }
        }
        None
    }

    /// Highest priority, then shortest clip, then id (rules.md 6.1).
    fn best(&self, mut edges: Vec<usize>) -> Option<usize> {
        edges.sort_by(|&a, &b| {
            let (ea, eb) = (&self.edges[a], &self.edges[b]);
            eb.priority
                .total_cmp(&ea.priority)
                .then(self.length[a].cmp(&self.length[b]))
                .then(ea.id.cmp(&eb.id))
        });
        edges.first().copied()
    }
}

/// Whole milliseconds, halves to even, as every player computes them.
fn round_ms(x: f64) -> u64 {
    x.round_ties_even().max(0.0) as u64
}

/// The engine of one loaded release.
pub struct Engine {
    g: Graph,
    rolls: Rolls,
    now: u64,
    out: Vec<Command>,
    unplayable: HashSet<usize>,
    last_extra: HashMap<String, usize>,
    chain: (u32, u64),
    held: HashMap<String, Value>,
    fires: Vec<(String, Option<Claim>)>,
    pose: Option<String>,
    screen: Option<Screen>,
    decided: Option<Decided>,
    loop_count: u32,
    entered_at: u64,
    /// The pose clip that ended last on this pose (rules.md 9.5).
    last_ended: Option<usize>,
    /// The edges whose looping sound is playing (rules.md 9.6).
    looping: HashSet<usize>,
}

impl Engine {
    pub(crate) fn new(release: Release) -> Self {
        let mut e = Engine {
            g: Graph::new(release),
            rolls: Rolls {
                fixed: VecDeque::new(),
                seed: 0x9E37_79B9_7F4A_7C15,
            },
            now: 0,
            out: Vec::new(),
            unplayable: HashSet::new(),
            last_extra: HashMap::new(),
            chain: (0, 0),
            held: HashMap::new(),
            fires: Vec::new(),
            pose: None,
            screen: None,
            decided: None,
            loop_count: 0,
            entered_at: 0,
            last_ended: None,
            looping: HashSet::new(),
        };
        e.reset_values();
        e
    }

    /// Seeds the extra-clip rolls (rules.md 7.3).
    pub fn seed(&mut self, seed: u64) {
        self.rolls = Rolls {
            fixed: VecDeque::new(),
            seed: seed.max(1),
        };
    }

    /// Uses these numbers, in order, for the extra-clip rolls, then the
    /// seeded ones once they run out. For scenarios.
    pub fn use_rolls(&mut self, rolls: Vec<f64>) {
        self.rolls.fixed = rolls.into();
    }

    // ---------------------------------------------------------------- calls

    /// Enters the first pose (rules.md 11.1).
    pub fn start(&mut self, now: u64) -> Vec<Command> {
        self.run_until(now, true);
        self.cut_move();
        self.begin();
        self.take()
    }

    /// Starts again from the defaults (rules.md 11.3).
    pub fn reset(&mut self, now: u64) -> Vec<Command> {
        self.run_until(now, true);
        self.cut_move();
        self.reset_values();
        self.begin();
        self.take()
    }

    /// `set(name, value)` (rules.md 3.2).
    pub fn set(&mut self, name: &str, value: Value, now: u64) -> Vec<Command> {
        self.run_until(now, true);
        self.set_value(name, value);
        self.take()
    }

    /// `fire(name)` (rules.md 3.3).
    pub fn fire(&mut self, name: &str, now: u64) -> Vec<Command> {
        self.run_until(now, true);
        self.fire_name(name);
        self.take()
    }

    /// The person clicked the mascot: always `action::click`, whatever the
    /// canvas declares (rules.md 3.5).
    pub fn click(&mut self, now: u64) -> Vec<Command> {
        self.fire("action::click", now)
    }

    /// The pointer entered or left the mascot: always
    /// `behavior::pointerHover` (rules.md 3.5).
    pub fn hover(&mut self, on: bool, now: u64) -> Vec<Command> {
        self.set("behavior::pointerHover", Value::Bool(on), now)
    }

    /// Play time moved on: runs every timer and safety net due.
    pub fn advance(&mut self, now: u64) -> Vec<Command> {
        self.run_until(now, true);
        self.take()
    }

    /// The player reports that the clip on screen reached its end.
    pub fn clip_ended(&mut self, edge: &str, now: u64) -> Vec<Command> {
        self.run_until(now, false);
        self.now = self.now.max(now);
        if let (Some(s), Some(&i)) = (self.screen, self.g.by_id.get(edge)) {
            if s.edge == Some(i) && s.kind != ScreenKind::Still {
                self.screen_ended();
            }
        }
        self.take()
    }

    /// The player reports that the clip it was asked to show is on screen,
    /// its first frame visible. The clip's safety net counts from now
    /// (rules.md 9.3).
    pub fn clip_shown(&mut self, edge: &str, now: u64) -> Vec<Command> {
        self.run_until(now, false);
        self.now = self.now.max(now);
        let at = self.now;
        if let (Some(s), Some(&i)) = (self.screen.as_mut(), self.g.by_id.get(edge)) {
            if s.edge == Some(i) && !s.visible {
                s.visible = true;
                s.shown = at;
            }
        }
        self.take()
    }

    /// The player could not play the clip it was asked to show (rules.md 9.4).
    /// It is not asked to show that clip again unless it reports it playable.
    pub fn clip_failed(&mut self, edge: &str, now: u64) -> Vec<Command> {
        self.run_until(now, false);
        self.now = self.now.max(now);
        let Some(&i) = self.g.by_id.get(edge) else {
            return self.take();
        };
        self.unplayable.insert(i);
        if self.screen.is_some_and(|s| s.edge == Some(i)) {
            self.fail_on_screen(i, "clip_failed");
        }
        self.take()
    }

    /// The clip on screen cannot play: a move skips to its target (9.4), a
    /// pose clip gives way to a stand-in (9.5).
    fn fail_on_screen(&mut self, i: usize, code: &str) {
        let Some(s) = self.screen else {
            return;
        };
        match s.kind {
            ScreenKind::Move => {
                let id = self.g.edges[i].id.clone();
                self.push_error(code, Some(&id));
                let target = self.g.edges[i].target.clone();
                self.enter(&target);
            }
            ScreenKind::Pose => {
                let id = self.g.edges[i].id.clone();
                self.push_error(code, Some(&id));
                self.stand_in(i);
                // A start decided for the end of the failed clip leaves the
                // still at once (rules.md 5.3).
                if self.screen.is_some_and(|s| s.kind == ScreenKind::Still) {
                    self.consider(Boundary::None, false);
                }
            }
            ScreenKind::Still => {}
        }
    }

    /// The player found it cannot load this clip, before it was shown.
    pub fn mark_unplayable(&mut self, edge: &str) {
        if let Some(&i) = self.g.by_id.get(edge) {
            self.unplayable.insert(i);
        }
    }

    /// The player can load this clip again.
    pub fn mark_playable(&mut self, edge: &str) {
        if let Some(&i) = self.g.by_id.get(edge) {
            self.unplayable.remove(&i);
        }
    }

    /// Editors and tools: show a pose at once (rules.md 13).
    pub fn preview_show_pose(&mut self, pose: &str, now: u64) -> Vec<Command> {
        self.run_until(now, true);
        self.show_pose_now(pose);
        self.take()
    }

    /// Editors and tools: play one move from the current pose (rules.md 13).
    pub fn preview_play_move(&mut self, edge: &str, now: u64) -> Vec<Command> {
        self.run_until(now, true);
        self.play_move_now(edge);
        self.take()
    }

    /// The next play time at which the engine has work, if any.
    pub fn next_wake(&self) -> Option<u64> {
        self.next_due().map(|(t, _)| t)
    }

    /// What is on screen and what is decided.
    pub fn state(&self) -> State {
        let clip = self.screen.map(|s| match s.edge {
            Some(i) => self.g.edges[i].id.clone(),
            None => format!("still:{}", self.pose.as_deref().unwrap_or("")),
        });
        State {
            clock: self.now,
            pose: self.pose.clone(),
            clip,
            moving: self.screen.is_some_and(|s| s.kind == ScreenKind::Move),
            shown_at: self.screen.map_or(0, |s| s.shown),
            expected_ms: self.screen.map_or(0, |s| s.nominal),
            next: self.decided.map(|d| Next {
                clip: self.g.edges[d.plan.hop].id.clone(),
                at: d.at,
            }),
        }
    }

    /// A name's value now, as `set` resolves it (rules.md 2.3, 3.1).
    pub fn value(&self, name: &str) -> Value {
        self.read(&self.resolve(name))
    }

    /// The fires still pending, sorted.
    pub fn pending_fires(&self) -> Vec<String> {
        let mut names: Vec<String> = self.fires.iter().map(|(n, _)| n.clone()).collect();
        names.sort();
        names
    }

    pub fn clock(&self) -> u64 {
        self.now
    }

    // ---------------------------------------------------------------- values

    fn reset_values(&mut self) {
        self.held = self
            .g
            .inputs
            .iter()
            .filter(|(n, (k, _))| {
                k != "trigger" && !n.starts_with("node::") && n.as_str() != "behavior::rest"
            })
            .map(|(n, (_, d))| (n.clone(), Value::from(*d)))
            .collect();
        self.fires.clear();
        self.pose = None;
        self.screen = None;
        self.decided = None;
        self.loop_count = 0;
        self.entered_at = self.now;
    }

    fn resolve(&self, name: &str) -> String {
        if name.contains("::") || self.g.inputs.contains_key(name) {
            return name.to_owned();
        }
        let behavior = format!("behavior::{name}");
        if FAMILIES.contains(&name) || self.g.inputs.contains_key(&behavior) {
            behavior
        } else {
            format!("action::{name}")
        }
    }

    fn fire_index(&self, name: &str) -> Option<usize> {
        self.fires.iter().position(|(n, _)| n == name)
    }

    fn on(&self, name: &str) -> bool {
        self.fire_index(name).is_some() || self.held.get(name).is_some_and(|v| v.number() != 0.0)
    }

    fn read(&self, name: &str) -> Value {
        match name {
            "node::loopCount" => Value::Number(f64::from(self.loop_count)),
            "node::nodeTime" => Value::Number(self.now.saturating_sub(self.entered_at) as f64),
            "behavior::rest" => Value::Bool(
                !self
                    .held
                    .keys()
                    .chain(self.fires.iter().map(|(n, _)| n))
                    .any(|n| n.starts_with("behavior::") && n != "behavior::rest" && self.on(n)),
            ),
            _ if self.fire_index(name).is_some() => Value::Bool(true),
            _ => self.held.get(name).copied().unwrap_or(Value::Bool(false)),
        }
    }

    fn holds(&self, c: &Condition) -> bool {
        let left = self.read(&c.input).number();
        let right = Value::from(c.value).number();
        match c.op {
            Op::Eq => left == right,
            Op::Ne => left != right,
            Op::Gt => left > right,
            Op::Lt => left < right,
            Op::Ge => left >= right,
            Op::Le => left <= right,
        }
    }

    fn holding_groups(&self, i: usize) -> Vec<&Vec<Condition>> {
        self.g.edges[i]
            .groups
            .iter()
            .filter(|g| g.iter().all(|c| self.holds(c)))
            .collect()
    }

    fn edge_holds(&self, i: usize) -> bool {
        let e = &self.g.edges[i];
        e.groups.is_empty() || e.groups.iter().any(|g| g.iter().all(|c| self.holds(c)))
    }

    fn holding_names(&self, i: usize) -> Vec<String> {
        let mut names: Vec<String> = Vec::new();
        for g in self.holding_groups(i) {
            for c in g {
                if !names.contains(&c.input) {
                    names.push(c.input.clone());
                }
            }
        }
        names
    }

    fn set_value(&mut self, name: &str, value: Value) {
        if !value.number().is_finite() {
            self.push_error("bad_value", Some(name));
            return;
        }
        let name = self.resolve(name);
        if name.starts_with("node::") || name == "behavior::rest" {
            self.push_error("read_only", Some(&name));
            return;
        }
        if self
            .g
            .inputs
            .get(&name)
            .is_some_and(|(k, _)| k == "trigger")
        {
            if value.number() != 0.0 {
                self.fire_name(&name);
            } else if let Some(i) = self.fire_index(&name) {
                self.fires.remove(i);
                self.consider(Boundary::None, false);
            }
            return;
        }
        if self.held.get(&name) == Some(&value) {
            return;
        }
        self.held.insert(name, value);
        self.consider(Boundary::None, false);
    }

    fn fire_name(&mut self, name: &str) {
        let name = self.resolve(name);
        if self.fire_index(&name).is_some() {
            return;
        }
        self.fires.push((name, None));
        self.consider(Boundary::None, false);
    }

    fn spend(&mut self, name: &str) {
        if let Some(i) = self.fire_index(name) {
            let (name, claim) = self.fires.remove(i);
            self.out.push(Command::Spent {
                name,
                used: claim.is_some(),
            });
        }
    }

    fn spend_where(&mut self, keep: impl Fn(&Option<Claim>) -> bool) {
        let names: Vec<String> = self
            .fires
            .iter()
            .filter(|(_, c)| !keep(c))
            .map(|(n, _)| n.clone())
            .collect();
        for n in names {
            self.spend(&n);
        }
    }

    fn unclaim_where(&mut self, f: impl Fn(&Claim) -> bool) {
        for (_, claim) in self.fires.iter_mut() {
            if claim.as_ref().is_some_and(&f) {
                *claim = None;
            }
        }
    }

    fn claim(&mut self, names: &[String], claim: Claim) {
        for (n, c) in self.fires.iter_mut() {
            if c.is_none() && names.contains(n) {
                *c = Some(claim.clone());
            }
        }
    }

    // ---------------------------------------------------------------- 4. What plays next

    fn decide(&self) -> Option<Decision> {
        let p = self.pose.as_deref()?;
        let mut cands: Vec<usize> = (0..self.g.edges.len())
            .filter(|&i| {
                let e = &self.g.edges[i];
                !e.is_loop
                    && match e.source.as_deref() {
                        Some(s) => s == p && self.edge_holds(i),
                        None => !e.groups.is_empty() && !self.holding_groups(i).is_empty(),
                    }
            })
            .collect();
        cands.sort_by(|&a, &b| {
            self.g.edges[b]
                .priority
                .total_cmp(&self.g.edges[a].priority)
                .then(a.cmp(&b))
        });
        for i in cands {
            let e = &self.g.edges[i];
            if e.source.is_none() {
                if e.target == p {
                    return Some(Decision::Stay);
                }
                match self.route_hop(p, &e.target) {
                    None => continue,
                    Some(hop) => {
                        return Some(Decision::Start(Plan {
                            edge: i,
                            hop,
                            route: true,
                        }))
                    }
                }
            }
            return Some(Decision::Start(Plan {
                edge: i,
                hop: i,
                route: false,
            }));
        }
        None
    }

    fn route_hop(&self, p: &str, t: &str) -> Option<usize> {
        let with_clip: Vec<usize> = self
            .g
            .moves_from(p)
            .filter(|&i| self.g.edges[i].has_video)
            .collect();
        let direct: Vec<usize> = with_clip
            .iter()
            .copied()
            .filter(|&i| self.g.edges[i].target == t)
            .collect();
        if let Some(hop) = self.g.best(direct) {
            return Some(hop);
        }
        let exits: Vec<(usize, u32)> = with_clip
            .iter()
            .filter_map(|&i| {
                self.g
                    .hops(&self.g.edges[i].target, t, &[p])
                    .map(|h| (i, h))
            })
            .collect();
        let holding: Vec<(usize, u32)> = exits
            .iter()
            .copied()
            .filter(|&(i, _)| self.edge_holds(i))
            .collect();
        let mut pool = if holding.is_empty() { exits } else { holding };
        pool.sort_by(|&(a, ha), &(b, hb)| {
            let (ea, eb) = (&self.g.edges[a], &self.g.edges[b]);
            eb.priority
                .total_cmp(&ea.priority)
                .then(ha.cmp(&hb))
                .then(self.g.length[a].cmp(&self.g.length[b]))
                .then(ea.id.cmp(&eb.id))
        });
        pool.first().map(|&(i, _)| i)
    }

    // ---------------------------------------------------------------- 5. When a start happens

    fn moment(&self, plan: Plan, boundary: Boundary) -> At {
        let no_conditions = self.g.edges[plan.edge].groups.is_empty();
        match boundary {
            Boundary::Entry => {
                return if no_conditions {
                    At::End
                } else {
                    At::Time(self.now)
                }
            }
            Boundary::End => return At::Time(self.now),
            Boundary::None => {}
        }
        if self.by_person(plan) {
            return At::Time(self.now);
        }
        if no_conditions {
            return At::End;
        }
        // A still is the pose's own picture: a move follows it without a jump.
        if self.screen.is_some_and(|s| s.kind == ScreenKind::Still) {
            return At::Time(self.now);
        }
        At::End
    }

    /// A person input that is on, in one of the winner's holding groups.
    fn by_person(&self, plan: Plan) -> bool {
        self.holding_groups(plan.edge).iter().any(|g| {
            g.iter()
                .any(|c| PERSON.contains(&c.input.as_str()) && self.read(&c.input).number() != 0.0)
        })
    }

    /// Decides (4) and starts now when the moment is now. True when a start
    /// happened.
    fn consider(&mut self, boundary: Boundary, spend_unclaimed_first: bool) -> bool {
        if self.pose.is_none() {
            return false;
        }
        // No move starts for the rest of a clipless cycle's second; the
        // engine decides again when it is over (rules.md 9.4).
        if self.cycling() {
            self.decided = None;
            return false;
        }
        if let Some(s) = self.screen {
            if s.kind == ScreenKind::Move {
                self.decided = None;
                if boundary == Boundary::None {
                    if let Some(Decision::Start(plan)) = self.decide() {
                        if Some(plan.hop) != s.edge && self.by_person(plan) {
                            self.interrupt(plan);
                            return true;
                        }
                    }
                }
                return false;
            }
        }
        let plan = match self.decide() {
            Some(Decision::Start(plan)) => plan,
            _ => {
                self.decided = None;
                return false;
            }
        };
        let at = self.moment(plan, boundary);
        if at == At::Time(self.now) {
            self.start_plan(plan, spend_unclaimed_first);
            return true;
        }
        self.decided = Some(Decided { plan, at });
        false
    }

    fn interrupt(&mut self, plan: Plan) {
        if let Some(i) = self.screen.and_then(|s| s.edge) {
            self.out.push(Command::Interrupted {
                edge: self.g.edges[i].id.clone(),
            });
        }
        let target = plan.target(&self.g).to_owned();
        self.unclaim_where(|c| c.pose != target);
        self.start_plan(plan, false);
    }

    fn start_plan(&mut self, plan: Plan, spend_unclaimed_first: bool) {
        let p = self.pose.clone().unwrap_or_default();
        let target = plan.target(&self.g).to_owned();
        self.spend_where(|c| c.as_ref().is_none_or(|c| c.pose != p));
        self.unclaim_where(|c| c.route && c.pose != target);
        let names = self.holding_names(plan.edge);
        self.claim(
            &names,
            Claim {
                pose: target,
                clip: None,
                route: plan.route,
            },
        );
        self.decided = None;
        if spend_unclaimed_first {
            self.spend_where(|c| c.is_some());
        }
        self.show_move(plan.hop);
    }

    // ---------------------------------------------------------------- 9. Moves

    fn show_move(&mut self, i: usize) {
        if !self.g.edges[i].has_video || self.unplayable.contains(&i) {
            let id = self.g.edges[i].id.clone();
            self.push_error("clip_failed", Some(&id));
            let target = self.g.edges[i].target.clone();
            self.enter(&target);
            return;
        }
        self.out.push(Command::StopSounds {
            only_looping: false,
        });
        self.looping.clear();
        self.screen = Some(self.clip_screen(ScreenKind::Move, i));
        let (id, rate) = (self.g.edges[i].id.clone(), self.rate(i));
        self.out.push(Command::ShowClip {
            edge: id.clone(),
            kind: ClipKind::Move,
            rate,
        });
        if let Some(looping) = self.g.edges[i].sound {
            self.out.push(Command::PlaySound { edge: id });
            if looping {
                self.looping.insert(i);
            }
        }
        let target = self.g.edges[i].target.clone();
        if let Some(main) = self.main_clip(&target) {
            self.out.push(Command::Preload {
                edge: self.g.edges[main].id.clone(),
            });
        }
    }

    fn enter(&mut self, pose: &str) {
        let (n, since) = self.chain;
        self.chain = if self.now < since.saturating_add(CHAIN_MS) {
            (n.saturating_add(1), since)
        } else {
            (1, self.now)
        };
        self.arrive(pose);
        let started = if self.cycling() {
            self.push_error("clipless_cycle", Some(pose));
            false
        } else {
            self.consider(Boundary::Entry, false)
        };
        if !started {
            // A route that did not continue here ends (rules.md 6.4).
            let here = pose.to_owned();
            self.unclaim_where(|c| c.route && c.pose != here);
            let choice = self.choose_clip(None);
            self.show_pose(choice);
        }
    }

    /// What entering a pose resets and reports, for `enter` and
    /// `preview.showPose` alike (rules.md 8, 9.6, 9.7).
    fn arrive(&mut self, pose: &str) {
        self.pose = Some(pose.to_owned());
        self.loop_count = 0;
        self.entered_at = self.now;
        self.last_ended = None;
        self.screen = None;
        self.decided = None;
        self.out.push(Command::PoseEntered {
            pose: pose.to_owned(),
        });
        if !self.looping.is_empty() {
            self.looping.clear();
            self.out.push(Command::StopSounds { only_looping: true });
        }
        for edge in self.preload_list(pose) {
            self.out.push(Command::Preload { edge });
        }
    }

    /// `reset`, a second `start` and `preview.showPose` cut the move on
    /// screen: its target is never entered (rules.md 11.4).
    fn cut_move(&mut self) {
        let Some(i) = self
            .screen
            .filter(|s| s.kind == ScreenKind::Move)
            .and_then(|s| s.edge)
        else {
            return;
        };
        self.out.push(Command::Interrupted {
            edge: self.g.edges[i].id.clone(),
        });
    }

    /// More than 32 poses were entered within this second of play time
    /// (rules.md 9.4).
    fn cycling(&self) -> bool {
        let (n, since) = self.chain;
        n > MAX_CHAIN && self.now < since.saturating_add(CHAIN_MS)
    }

    fn preload_list(&self, p: &str) -> Vec<String> {
        let rank = |a: &usize, b: &usize| {
            self.g.edges[*b]
                .priority
                .total_cmp(&self.g.edges[*a].priority)
                .then(a.cmp(b))
        };
        let mut out: Vec<String> = Vec::new();
        let mut selectors: Vec<usize> = (0..self.g.edges.len())
            .filter(|&i| {
                let e = &self.g.edges[i];
                e.source.is_none() && !e.groups.is_empty() && e.target != p
            })
            .collect();
        selectors.sort_by(rank);
        for i in selectors {
            if let Some(hop) = self.route_hop(p, &self.g.edges[i].target) {
                let id = &self.g.edges[hop].id;
                if !out.contains(id) {
                    out.push(id.clone());
                }
            }
        }
        let mut moves: Vec<usize> = self
            .g
            .moves_from(p)
            .filter(|&i| self.g.edges[i].has_video)
            .collect();
        moves.sort_by(rank);
        for i in moves {
            let id = &self.g.edges[i].id;
            if !out.contains(id) {
                out.push(id.clone());
            }
        }
        out
    }

    // ---------------------------------------------------------------- 11. Start

    fn begin(&mut self) {
        // A start while the mascot plays leaves its pose, and the fires a
        // start claimed for another pose are claimed no more (rules.md 3.3,
        // 11.1).
        if let Some(p) = self.pose.clone() {
            self.spend_where(|c| c.as_ref().is_none_or(|c| c.pose != p));
        }
        self.unclaim_where(|_| true);
        let mut cands: Vec<usize> = (0..self.g.edges.len())
            .filter(|&i| {
                let e = &self.g.edges[i];
                e.source.is_none() && !e.groups.is_empty() && !self.holding_groups(i).is_empty()
            })
            .collect();
        cands.sort_by(|&a, &b| {
            self.g.edges[b]
                .priority
                .total_cmp(&self.g.edges[a].priority)
                .then(a.cmp(&b))
        });
        let mut first = self.g.initial.clone();
        if let Some(&i) = cands.first() {
            first = self.g.edges[i].target.clone();
            let names = self.holding_names(i);
            self.claim(
                &names,
                Claim {
                    pose: first.clone(),
                    clip: None,
                    route: false,
                },
            );
        }
        self.enter(&first);
    }

    // ---------------------------------------------------------------- 13. Preview calls

    fn show_pose_now(&mut self, pose: &str) {
        if !self.g.nodes.contains(pose) {
            self.push_error("unknown_pose", Some(pose));
            return;
        }
        self.cut_move();
        self.fires.clear();
        self.arrive(pose);
        let main = self.main_clip(pose);
        self.show_pose(main);
        self.consider(Boundary::None, false);
    }

    fn play_move_now(&mut self, edge: &str) {
        let ok = self.g.by_id.get(edge).copied().filter(|&i| {
            let e = &self.g.edges[i];
            e.source.as_deref() == self.pose.as_deref()
                && e.source.is_some()
                && !e.is_loop
                && self.screen.is_some_and(|s| s.kind != ScreenKind::Move)
        });
        let Some(i) = ok else {
            self.push_error("preview_refused", Some(edge));
            return;
        };
        if self.cycling() {
            let pose = self.pose.clone();
            self.push_error("clipless_cycle", pose.as_deref());
            return;
        }
        let p = self.pose.clone().unwrap_or_default();
        self.spend_where(|c| c.as_ref().is_none_or(|c| c.pose != p));
        self.decided = None;
        self.show_move(i);
    }

    // ---------------------------------------------------------------- 7. Pose clips

    /// The pose's main loop: its first clip without conditions, else its
    /// first clip.
    fn main_clip(&self, pose: &str) -> Option<usize> {
        let playable: Vec<usize> = self
            .g
            .pose_clips(pose)
            .filter(|&i| self.g.edges[i].has_video)
            .collect();
        playable
            .iter()
            .copied()
            .find(|&i| self.g.edges[i].groups.is_empty())
            .or_else(|| playable.first().copied())
    }

    fn choose_clip(&mut self, ended: Option<usize>) -> Option<usize> {
        let p = self.pose.clone()?;
        let playable: Vec<usize> = self
            .g
            .pose_clips(&p)
            .filter(|&i| self.g.edges[i].has_video)
            .collect();
        for &i in &playable {
            if !self.g.edges[i].groups.is_empty() && !self.holding_groups(i).is_empty() {
                let names = self.holding_names(i);
                self.claim(
                    &names,
                    Claim {
                        pose: p.clone(),
                        clip: Some(i),
                        route: false,
                    },
                );
                return Some(i);
            }
        }
        let plain: Vec<usize> = playable
            .iter()
            .copied()
            .filter(|&i| self.g.edges[i].groups.is_empty())
            .collect();
        let main = self.main_clip(&p)?;
        if ended == Some(main) {
            let extras: Vec<usize> = plain.iter().copied().filter(|&i| i != main).collect();
            if !extras.is_empty() {
                let r = self.rolls.next();
                if r < 1.0 / 3.0 {
                    let last = self.last_extra.get(&p).copied();
                    let fresh: Vec<usize> = extras
                        .iter()
                        .copied()
                        .filter(|&i| Some(i) != last)
                        .collect();
                    let pool = if fresh.is_empty() { extras } else { fresh };
                    let k = ((r * 3.0 * pool.len() as f64) as usize).min(pool.len() - 1);
                    let pick = pool[k];
                    self.last_extra.insert(p, pick);
                    return Some(pick);
                }
            }
        }
        Some(main)
    }

    fn show_pose(&mut self, choice: Option<usize>) {
        match choice {
            None => self.show_still(STILL_MS),
            Some(i) if self.unplayable.contains(&i) => {
                let id = self.g.edges[i].id.clone();
                self.push_error("clip_failed", Some(&id));
                self.stand_in(i);
            }
            Some(i) => self.show_pose_clip(i),
        }
    }

    /// A pose clip that cannot play: the pose plays again the clip that
    /// ended last on it, if that one can play, else its still for the failed
    /// clip's length. A fire the failed clip claimed is spent when what plays
    /// in its place ends (rules.md 3.3, 9.5).
    fn stand_in(&mut self, failed: usize) {
        for (_, claim) in self.fires.iter_mut() {
            if let Some(c) = claim.as_mut().filter(|c| c.clip == Some(failed)) {
                c.clip = None;
            }
        }
        match self.last_ended.filter(|e| !self.unplayable.contains(e)) {
            Some(prev) => self.show_pose_clip(prev),
            None => {
                let ms = round_ms(self.g.edges[failed].duration / self.rate(failed) * 1000.0);
                self.show_still(ms);
            }
        }
    }

    fn show_pose_clip(&mut self, i: usize) {
        self.screen = Some(self.clip_screen(ScreenKind::Pose, i));
        let (id, rate) = (self.g.edges[i].id.clone(), self.rate(i));
        self.out.push(Command::ShowClip {
            edge: id.clone(),
            kind: ClipKind::Pose,
            rate,
        });
        if let Some(looping) = self.g.edges[i].sound {
            // A looping sound already playing on this pose plays on, never
            // twice (rules.md 9.6).
            if !looping || self.looping.insert(i) {
                self.out.push(Command::PlaySound { edge: id });
            }
        }
    }

    /// Shows the pose's still for `ms`, and never less than 1 s: a still
    /// that ended at once would show again a thousand times a second
    /// (rules.md 9.5).
    fn show_still(&mut self, ms: u64) {
        let ms = ms.max(STILL_MS);
        self.screen = Some(Screen {
            kind: ScreenKind::Still,
            edge: None,
            shown: self.now,
            visible: true,
            nominal: ms,
        });
        let pose = self.pose.clone().unwrap_or_default();
        self.out.push(Command::ShowStill { pose });
    }

    /// Speed times the number `speedInput` names (1 when it holds none, or
    /// one that is not finite), kept between 0.2 and 4 (rules.md 9.2).
    fn rate(&self, i: usize) -> f64 {
        let e = &self.g.edges[i];
        match &e.speed_input {
            None => e.speed,
            Some(name) => {
                let factor = match self.held.get(name) {
                    Some(Value::Number(n)) if self.g.is_number(name) && n.is_finite() => *n,
                    _ => 1.0,
                };
                (e.speed * factor).clamp(0.2, 4.0)
            }
        }
    }

    fn clip_screen(&self, kind: ScreenKind, i: usize) -> Screen {
        let rate = self.rate(i);
        Screen {
            kind,
            edge: Some(i),
            shown: self.now,
            visible: false,
            nominal: round_ms(self.g.edges[i].duration / rate * 1000.0),
        }
    }

    // ---------------------------------------------------------------- 5.5 The end of a pose clip

    fn screen_ended(&mut self) {
        let Some(s) = self.screen else {
            return;
        };
        match (s.kind, s.edge) {
            (ScreenKind::Move, Some(i)) => {
                let target = self.g.edges[i].target.clone();
                self.enter(&target);
            }
            _ => self.clip_end(s.edge),
        }
    }

    fn clip_end(&mut self, ended: Option<usize>) {
        let p = self.pose.clone().unwrap_or_default();
        self.loop_count = self.loop_count.saturating_add(1);
        if ended.is_some() {
            self.last_ended = ended;
        }
        if self.consider(Boundary::End, true) {
            return;
        }
        let here = p.clone();
        self.spend_where(move |c| {
            !c.as_ref()
                .is_some_and(|c| c.pose == here && (c.clip.is_none() || c.clip == ended))
        });
        if self.consider(Boundary::End, true) {
            return;
        }
        let choice = self.choose_clip(ended);
        let spent = self.fires.iter().any(|(_, c)| c.is_none());
        self.spend_where(|c| c.is_some());
        if spent && self.consider(Boundary::End, false) {
            return;
        }
        self.show_pose(choice);
    }

    // ---------------------------------------------------------------- The clock

    fn wakes(&self) -> Vec<u64> {
        let Some(s) = self.screen else {
            return Vec::new();
        };
        if s.kind == ScreenKind::Move {
            return Vec::new();
        }
        let p = self.pose.as_deref().unwrap_or("");
        let mut out = Vec::new();
        if self.cycling() {
            out.push(self.chain.1.saturating_add(CHAIN_MS));
        }
        for e in &self.g.edges {
            let relevant = match e.source.as_deref() {
                Some(src) => src == p,
                None => !e.is_loop,
            };
            if !relevant {
                continue;
            }
            for g in &e.groups {
                for c in g {
                    if c.input == "node::nodeTime" {
                        let v = Value::from(c.value).number();
                        for t in [v.ceil(), v.floor() + 1.0] {
                            if t >= 0.0 {
                                let at = self.entered_at.saturating_add(t as u64);
                                if at > self.now {
                                    out.push(at);
                                }
                            }
                        }
                    }
                }
            }
        }
        out
    }

    fn next_due(&self) -> Option<(u64, Due)> {
        let mut items: Vec<(u64, Due)> = Vec::new();
        if let Some(s) = self.screen {
            if s.kind == ScreenKind::Still {
                items.push((s.shown.saturating_add(s.nominal), Due::StillEnd));
            }
            if s.visible {
                let end = s.shown.saturating_add(s.nominal);
                items.push((end.saturating_add(SAFETY_MS), Due::Safety));
            } else {
                items.push((s.shown.saturating_add(LOAD_MS), Due::LoadTimeout));
            }
        }
        for w in self.wakes() {
            items.push((w, Due::Wake));
        }
        // A time that saturated is never: a clip slowed to almost nothing
        // must not come due again and again at the end of the clock.
        items.into_iter().filter(|&(t, _)| t != u64::MAX).min()
    }

    /// Runs everything due before `until` (and at `until` when inclusive).
    fn run_until(&mut self, until: u64, inclusive: bool) {
        while let Some((t, due)) = self.next_due() {
            if t > until || (!inclusive && t == until) {
                break;
            }
            self.now = self.now.max(t);
            match due {
                Due::StillEnd => self.screen_ended(),
                Due::Safety => {
                    let id = self
                        .screen
                        .and_then(|s| s.edge)
                        .map(|i| self.g.edges[i].id.clone());
                    self.push_error("missing_end", id.as_deref());
                    self.screen_ended();
                }
                Due::LoadTimeout => {
                    if let Some(i) = self.screen.and_then(|s| s.edge) {
                        self.unplayable.insert(i);
                        self.fail_on_screen(i, "clip_timeout");
                    }
                }
                Due::Wake => {
                    self.consider(Boundary::None, false);
                }
            }
        }
        if inclusive {
            self.now = self.now.max(until);
        }
    }

    fn push_error(&mut self, code: &str, detail: Option<&str>) {
        self.out.push(Command::Error {
            code: code.to_owned(),
            detail: detail.map(str::to_owned),
        });
    }

    fn take(&mut self) -> Vec<Command> {
        std::mem::take(&mut self.out)
    }
}
