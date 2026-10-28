//! The engine for Swift (iPhone, iPad, Mac) and Kotlin (Android), through
//! UniFFI. The generated code exposes `MaskoEngine` with the same calls as
//! the engine; play time is in milliseconds.

use masko_player_engine::{At, ClipKind, Command, Engine, Value};
use std::sync::{Arc, Mutex};

uniffi::setup_scaffolding!();

/// Why a delivery is refused (rules.md 1.2, 1.3).
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum LoadFailure {
    #[error("{code}: {detail}")]
    Refused { code: String, detail: String },
}

#[derive(Debug, Clone, Copy, PartialEq, uniffi::Enum)]
pub enum EngineValue {
    Bool { value: bool },
    Number { value: f64 },
}

#[derive(Debug, Clone, Copy, PartialEq, uniffi::Enum)]
pub enum EngineClipKind {
    Pose,
    Move,
}

/// What the player must do, in order (see the engine's `Command`).
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum EngineCommand {
    ShowClip {
        edge: String,
        kind: EngineClipKind,
        rate: f64,
    },
    ShowStill {
        pose: String,
    },
    Preload {
        edge: String,
    },
    PlaySound {
        edge: String,
    },
    StopSounds {
        only_looping: bool,
    },
    PoseEntered {
        pose: String,
    },
    Interrupted {
        edge: String,
    },
    Spent {
        name: String,
        used: bool,
    },
    Error {
        code: String,
        detail: Option<String>,
    },
}

/// What is on screen and what is decided.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct EngineState {
    pub clock: u64,
    pub pose: Option<String>,
    pub clip: Option<String>,
    pub moving: bool,
    pub shown_at: u64,
    pub expected_ms: u64,
    pub next_clip: Option<String>,
    /// The decided start's play time; none with `next_at_end`.
    pub next_at: Option<u64>,
    pub next_at_end: bool,
}

fn commands(list: Vec<Command>) -> Vec<EngineCommand> {
    list.into_iter()
        .map(|c| match c {
            Command::ShowClip { edge, kind, rate } => EngineCommand::ShowClip {
                edge,
                kind: match kind {
                    ClipKind::Pose => EngineClipKind::Pose,
                    ClipKind::Move => EngineClipKind::Move,
                },
                rate,
            },
            Command::ShowStill { pose } => EngineCommand::ShowStill { pose },
            Command::Preload { edge } => EngineCommand::Preload { edge },
            Command::PlaySound { edge } => EngineCommand::PlaySound { edge },
            Command::StopSounds { only_looping } => EngineCommand::StopSounds { only_looping },
            Command::PoseEntered { pose } => EngineCommand::PoseEntered { pose },
            Command::Interrupted { edge } => EngineCommand::Interrupted { edge },
            Command::Spent { name, used } => EngineCommand::Spent { name, used },
            Command::Error { code, detail } => EngineCommand::Error { code, detail },
        })
        .collect()
}

/// One loaded release's engine. Safe to call from any thread.
#[derive(uniffi::Object)]
pub struct MaskoEngine {
    inner: Mutex<Engine>,
}

impl MaskoEngine {
    fn with<T>(&self, f: impl FnOnce(&mut Engine) -> T) -> T {
        let mut engine = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        f(&mut engine)
    }
}

#[uniffi::export]
impl MaskoEngine {
    /// Reads a release delivery, or says why it is refused.
    #[uniffi::constructor]
    pub fn new(delivery: String) -> Result<Arc<Self>, LoadFailure> {
        masko_player_engine::load(&delivery)
            .map(|e| {
                Arc::new(MaskoEngine {
                    inner: Mutex::new(e),
                })
            })
            .map_err(|e| LoadFailure::Refused {
                code: e.code.to_owned(),
                detail: e.detail,
            })
    }

    pub fn start(&self, now: u64) -> Vec<EngineCommand> {
        commands(self.with(|e| e.start(now)))
    }

    pub fn reset(&self, now: u64) -> Vec<EngineCommand> {
        commands(self.with(|e| e.reset(now)))
    }

    /// `set(name, value)`; with `instant`, what it starts starts now, and an
    /// Any State start goes straight into its target pose (rules.md 5.8).
    pub fn set_bool(
        &self,
        name: String,
        value: bool,
        instant: bool,
        now: u64,
    ) -> Vec<EngineCommand> {
        commands(self.with(|e| e.set(&name, Value::Bool(value), instant, now)))
    }

    pub fn set_number(
        &self,
        name: String,
        value: f64,
        instant: bool,
        now: u64,
    ) -> Vec<EngineCommand> {
        commands(self.with(|e| e.set(&name, Value::Number(value), instant, now)))
    }

    /// `fire(name)`; with `instant`, as `set_bool`.
    pub fn fire(&self, name: String, instant: bool, now: u64) -> Vec<EngineCommand> {
        commands(self.with(|e| e.fire(&name, instant, now)))
    }

    pub fn advance(&self, now: u64) -> Vec<EngineCommand> {
        commands(self.with(|e| e.advance(now)))
    }

    pub fn clip_shown(&self, edge: String, now: u64) -> Vec<EngineCommand> {
        commands(self.with(|e| e.clip_shown(&edge, now)))
    }

    pub fn clip_ended(&self, edge: String, now: u64) -> Vec<EngineCommand> {
        commands(self.with(|e| e.clip_ended(&edge, now)))
    }

    pub fn clip_failed(&self, edge: String, now: u64) -> Vec<EngineCommand> {
        commands(self.with(|e| e.clip_failed(&edge, now)))
    }

    pub fn mark_unplayable(&self, edge: String) {
        self.with(|e| e.mark_unplayable(&edge));
    }

    pub fn mark_playable(&self, edge: String) {
        self.with(|e| e.mark_playable(&edge));
    }

    pub fn preview_show_pose(&self, pose: String, now: u64) -> Vec<EngineCommand> {
        commands(self.with(|e| e.preview_show_pose(&pose, now)))
    }

    pub fn preview_play_move(&self, edge: String, now: u64) -> Vec<EngineCommand> {
        commands(self.with(|e| e.preview_play_move(&edge, now)))
    }

    pub fn next_wake(&self) -> Option<u64> {
        self.with(|e| e.next_wake())
    }

    pub fn state(&self) -> EngineState {
        let s = self.with(|e| e.state());
        let (next_clip, next_at, next_at_end) = match s.next {
            None => (None, None, false),
            Some(n) => match n.at {
                At::Time(t) => (Some(n.clip), Some(t), false),
                At::End => (Some(n.clip), None, true),
            },
        };
        EngineState {
            clock: s.clock,
            pose: s.pose,
            clip: s.clip,
            moving: s.moving,
            shown_at: s.shown_at,
            expected_ms: s.expected_ms,
            next_clip,
            next_at,
            next_at_end,
        }
    }

    pub fn value(&self, name: String) -> EngineValue {
        match self.with(|e| e.value(&name)) {
            Value::Bool(value) => EngineValue::Bool { value },
            Value::Number(value) => EngineValue::Number { value },
        }
    }

    pub fn pending_fires(&self) -> Vec<String> {
        self.with(|e| e.pending_fires())
    }

    pub fn seed(&self, seed: u64) {
        self.with(|e| e.seed(seed));
    }

    /// Fixed extra-clip rolls, for scenarios.
    pub fn use_rolls(&self, rolls: Vec<f64>) {
        self.with(|e| e.use_rolls(rolls));
    }
}
