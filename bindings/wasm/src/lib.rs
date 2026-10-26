//! The engine for the web, through wasm-bindgen. Commands and state cross as
//! JSON strings; `web/src/engine.ts` parses them and types them.

use masko_player_engine::{load, Command, Engine, Value};
use wasm_bindgen::prelude::*;

#[wasm_bindgen]
pub struct MaskoEngine {
    inner: Engine,
}

fn json(commands: Vec<Command>) -> String {
    serde_json::to_string(&commands).unwrap_or_else(|_| "[]".into())
}

fn ms(now: f64) -> u64 {
    if now.is_finite() && now > 0.0 {
        now as u64
    } else {
        0
    }
}

#[wasm_bindgen]
impl MaskoEngine {
    /// Reads a release delivery, or throws `"<code>: <detail>"` (rules.md 1.2).
    #[wasm_bindgen(constructor)]
    pub fn new(delivery: &str) -> Result<MaskoEngine, JsError> {
        load(delivery)
            .map(|inner| MaskoEngine { inner })
            .map_err(|e| JsError::new(&format!("{}: {}", e.code, e.detail)))
    }

    pub fn start(&mut self, now: f64) -> String {
        json(self.inner.start(ms(now)))
    }

    pub fn reset(&mut self, now: f64) -> String {
        json(self.inner.reset(ms(now)))
    }

    /// `set(name, value)` with a boolean or a number; with `instant`, what it
    /// starts starts now and goes straight into its target pose (rules.md 5.8).
    pub fn set(
        &mut self,
        name: &str,
        value: JsValue,
        instant: bool,
        now: f64,
    ) -> Result<String, JsError> {
        let value = if let Some(b) = value.as_bool() {
            Value::Bool(b)
        } else if let Some(n) = value.as_f64() {
            Value::Number(n)
        } else {
            return Err(JsError::new("set takes a boolean or a number"));
        };
        Ok(json(self.inner.set(name, value, instant, ms(now))))
    }

    /// `fire(name)`; with `instant`, what it starts starts now and goes
    /// straight into its target pose (rules.md 5.8).
    pub fn fire(&mut self, name: &str, instant: bool, now: f64) -> String {
        json(self.inner.fire(name, instant, ms(now)))
    }

    pub fn click(&mut self, now: f64) -> String {
        json(self.inner.click(ms(now)))
    }

    pub fn hover(&mut self, on: bool, now: f64) -> String {
        json(self.inner.hover(on, ms(now)))
    }

    pub fn advance(&mut self, now: f64) -> String {
        json(self.inner.advance(ms(now)))
    }

    #[wasm_bindgen(js_name = clipShown)]
    pub fn clip_shown(&mut self, edge: &str, now: f64) -> String {
        json(self.inner.clip_shown(edge, ms(now)))
    }

    #[wasm_bindgen(js_name = clipEnded)]
    pub fn clip_ended(&mut self, edge: &str, now: f64) -> String {
        json(self.inner.clip_ended(edge, ms(now)))
    }

    #[wasm_bindgen(js_name = clipFailed)]
    pub fn clip_failed(&mut self, edge: &str, now: f64) -> String {
        json(self.inner.clip_failed(edge, ms(now)))
    }

    #[wasm_bindgen(js_name = markUnplayable)]
    pub fn mark_unplayable(&mut self, edge: &str) {
        self.inner.mark_unplayable(edge);
    }

    #[wasm_bindgen(js_name = markPlayable)]
    pub fn mark_playable(&mut self, edge: &str) {
        self.inner.mark_playable(edge);
    }

    #[wasm_bindgen(js_name = previewShowPose)]
    pub fn preview_show_pose(&mut self, pose: &str, now: f64) -> String {
        json(self.inner.preview_show_pose(pose, ms(now)))
    }

    #[wasm_bindgen(js_name = previewPlayMove)]
    pub fn preview_play_move(&mut self, edge: &str, now: f64) -> String {
        json(self.inner.preview_play_move(edge, ms(now)))
    }

    /// The next play time at which the engine has work, or undefined.
    #[wasm_bindgen(js_name = nextWake)]
    pub fn next_wake(&self) -> Option<f64> {
        self.inner.next_wake().map(|t| t as f64)
    }

    pub fn state(&self) -> String {
        serde_json::to_string(&self.inner.state()).unwrap_or_else(|_| "{}".into())
    }

    /// A name's value now: a boolean or a number.
    pub fn value(&self, name: &str) -> JsValue {
        match self.inner.value(name) {
            Value::Bool(b) => JsValue::from_bool(b),
            Value::Number(n) => JsValue::from_f64(n),
        }
    }

    #[wasm_bindgen(js_name = pendingFires)]
    pub fn pending_fires(&self) -> Vec<String> {
        self.inner.pending_fires()
    }

    pub fn seed(&mut self, seed: f64) {
        self.inner.seed(seed.max(1.0) as u64);
    }

    /// Fixed extra-clip rolls, for scenarios.
    #[wasm_bindgen(js_name = useRolls)]
    pub fn use_rolls(&mut self, rolls: Vec<f64>) {
        self.inner.use_rolls(rolls);
    }
}
