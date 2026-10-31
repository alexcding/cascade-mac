//! Synara `packages/contracts/src/inlineVisualSpec.ts`: the component spec an agent sends to
//! `synara_show_visual` instead of raw HTML. Synara decodes it with an Effect Schema; this is that
//! schema's decode as Rust, rule for rule and in the schema's order: each text is trimmed and must
//! be non-empty and within its length (UTF-16 units, as JavaScript counts), numbers are finite,
//! lists are within their bounds, and a field the schema does not name is dropped. What comes back
//! is the normalized spec Synara stores.
//!
//! The rules that span fields (series lengths, table rows, calculator ids and formulas) are the
//! tool's (`visuals.rs`), as in Synara.

use serde_json::{Map, Value};

/// Synara `INLINE_VISUAL_MAX_SPEC_BYTES`.
pub const MAX_SPEC_BYTES: usize = 64 * 1024;
/// Synara `INLINE_VISUAL_MAX_BLOCKS`.
pub const MAX_BLOCKS: usize = 16;

/// Synara `INLINE_VISUAL_BLOCK_TYPES`.
pub const BLOCK_TYPES: [&str; 11] =
    ["markdown", "stats", "bar-chart", "line-chart", "table", "list", "callout", "compare", "calculator", "choices", "tabs"];

const TONES: [&str; 5] = ["neutral", "accent", "success", "warning", "danger"];

type Checked = Result<Value, String>;

fn at(path: &str, message: impl std::fmt::Display) -> String {
    format!("{message}\n  at {path}")
}

fn shown(value: &Value) -> String {
    let text = value.to_string();
    if text.chars().count() > 40 {
        format!("{}…", text.chars().take(40).collect::<String>())
    } else {
        text
    }
}

fn utf16_len(text: &str) -> usize {
    text.encode_utf16().count()
}

/// Synara `Text(maxLength)`: `Schema.Trim`, non-empty, at most `max`.
fn text(max: usize) -> impl Fn(&Value, &str) -> Checked {
    move |value, path| {
        let Some(raw) = value.as_str() else { return Err(at(path, format!("Expected a string, got {}", shown(value)))) };
        let trimmed = raw.trim();
        if trimmed.is_empty() {
            return Err(at(path, "Expected a non-empty string"));
        }
        if utf16_len(trimmed) > max {
            return Err(at(path, format!("Expected a string of at most {max} characters")));
        }
        Ok(Value::String(trimmed.to_owned()))
    }
}

/// `Schema.Finite`. JSON has no infinities, so any number is finite.
fn finite(value: &Value, path: &str) -> Checked {
    if value.is_number() {
        Ok(value.clone())
    } else {
        Err(at(path, format!("Expected a finite number, got {}", shown(value))))
    }
}

fn positive(value: &Value, path: &str) -> Checked {
    let checked = finite(value, path)?;
    if checked.as_f64().is_some_and(|number| number > 0.0) {
        Ok(checked)
    } else {
        Err(at(path, format!("Expected a number greater than 0, got {}", shown(value))))
    }
}

/// `Schema.Int` within `minimum..=maximum` (`None` is unbounded).
fn int(minimum: i64, maximum: Option<i64>) -> impl Fn(&Value, &str) -> Checked {
    move |value, path| {
        let number = value.as_f64().filter(|number| number.fract() == 0.0);
        let Some(number) = number else { return Err(at(path, format!("Expected an integer, got {}", shown(value)))) };
        if number < minimum as f64 || maximum.is_some_and(|maximum| number > maximum as f64) {
            let range = match maximum {
                Some(maximum) => format!("between {minimum} and {maximum}"),
                None => format!("greater than or equal to {minimum}"),
            };
            return Err(at(path, format!("Expected an integer {range}, got {}", shown(value))));
        }
        Ok(value.clone())
    }
}

fn boolean(value: &Value, path: &str) -> Checked {
    if value.is_boolean() {
        Ok(value.clone())
    } else {
        Err(at(path, format!("Expected a boolean, got {}", shown(value))))
    }
}

fn literal(options: &'static [&'static str]) -> impl Fn(&Value, &str) -> Checked {
    move |value, path| match value.as_str() {
        Some(found) if options.contains(&found) => Ok(value.clone()),
        _ => Err(at(path, format!("Expected one of {}, got {}", options.join(", "), shown(value)))),
    }
}

/// Synara `List(item, min, max)`.
fn list(min: usize, max: usize, item: impl Fn(&Value, &str) -> Checked) -> impl Fn(&Value, &str) -> Checked {
    move |value, path| {
        let Some(items) = value.as_array() else { return Err(at(path, format!("Expected an array, got {}", shown(value)))) };
        if items.len() < min {
            return Err(at(path, format!("Expected an array of at least {min} items, got {}", items.len())));
        }
        if items.len() > max {
            return Err(at(path, format!("Expected an array of at most {max} items, got {}", items.len())));
        }
        items.iter().enumerate().map(|(index, item_value)| item(item_value, &format!("{path}[{index}]"))).collect::<Result<Vec<_>, _>>().map(Value::Array)
    }
}

/// `Schema.NullOr(inner)`.
fn null_or(inner: impl Fn(&Value, &str) -> Checked) -> impl Fn(&Value, &str) -> Checked {
    move |value, path| if value.is_null() { Ok(Value::Null) } else { inner(value, path) }
}

/// A `Schema.Struct` being decoded: its fields in order, unknown ones dropped.
struct Struct<'a> {
    fields: &'a Map<String, Value>,
    path: &'a str,
    out: Map<String, Value>,
}

impl<'a> Struct<'a> {
    fn new(value: &'a Value, path: &'a str) -> Result<Self, String> {
        match value.as_object() {
            Some(fields) => Ok(Self { fields, path, out: Map::new() }),
            None => Err(at(path, format!("Expected an object, got {}", shown(value)))),
        }
    }

    fn field_path(&self, key: &str) -> String {
        format!("{}.{key}", self.path)
    }

    fn required(mut self, key: &str, check: impl Fn(&Value, &str) -> Checked) -> Result<Self, String> {
        let path = self.field_path(key);
        let Some(value) = self.fields.get(key) else { return Err(at(&path, "Missing key")) };
        self.out.insert(key.to_owned(), check(value, &path)?);
        Ok(self)
    }

    /// `Schema.optional(inner)`: absent, or present and valid (`null` is not absent).
    fn optional(mut self, key: &str, check: impl Fn(&Value, &str) -> Checked) -> Result<Self, String> {
        if let Some(value) = self.fields.get(key) {
            let path = self.field_path(key);
            self.out.insert(key.to_owned(), check(value, &path)?);
        }
        Ok(self)
    }

    fn done(self) -> Value {
        Value::Object(self.out)
    }
}

fn tone(value: &Value, path: &str) -> Checked {
    literal(&TONES)(value, path)
}

/// A leaf block (`InlineVisualLeafBlock`), or with `tabs` allowed, any block (`InlineVisualBlock`).
fn block(allow_tabs: bool) -> impl Fn(&Value, &str) -> Checked {
    move |value, path| {
        let kind = value.as_object().and_then(|fields| fields.get("type")).and_then(Value::as_str);
        let s = Struct::new(value, path)?;
        let s = match kind {
            Some("markdown") => s.required("type", literal(&["markdown"]))?.required("text", text(8_000))?,
            Some("stats") => s.required("type", literal(&["stats"]))?.required(
                "items",
                list(1, 6, |item, path| {
                    Ok(Struct::new(item, path)?
                        .required("label", text(60))?
                        .required("value", text(40))?
                        .optional("detail", text(80))?
                        .optional("trend", literal(&["up", "down", "flat"]))?
                        .optional("tone", tone)?
                        .done())
                }),
            )?,
            Some("bar-chart") => s
                .required("type", literal(&["bar-chart"]))?
                .optional("title", text(120))?
                .optional("unit", text(12))?
                .required(
                    "items",
                    list(1, 40, |item, path| {
                        Ok(Struct::new(item, path)?
                            .required("label", text(60))?
                            .required("value", finite)?
                            .optional("baseline", finite)?
                            .optional("highlight", boolean)?
                            .done())
                    }),
                )?
                .optional("sort", literal(&["none", "value"]))?
                .optional("baselineLabel", text(24))?
                .optional("valueLabel", text(24))?
                .optional("better", literal(&["lower", "higher"]))?,
            Some("line-chart") => s
                .required("type", literal(&["line-chart"]))?
                .optional("title", text(120))?
                .optional("unit", text(12))?
                .required("labels", list(2, 200, text(24)))?
                .required(
                    "series",
                    list(1, 6, |item, path| {
                        Ok(Struct::new(item, path)?
                            .required("name", text(40))?
                            .required("values", list(2, 200, null_or(finite)))?
                            .done())
                    }),
                )?,
            Some("table") => s
                .required("type", literal(&["table"]))?
                .optional("title", text(120))?
                .required(
                    "columns",
                    list(1, 10, |item, path| {
                        Ok(Struct::new(item, path)?
                            .required("label", text(60))?
                            .optional("format", literal(&["text", "number", "percent"]))?
                            .done())
                    }),
                )?
                .required("rows", list(1, 200, list(1, 10, null_or(table_cell))))?
                .optional("highlightRow", int(0, None))?,
            Some("list") => s
                .required("type", literal(&["list"]))?
                .optional("title", text(120))?
                .optional("style", literal(&["bullets", "numbered", "checklist", "steps"]))?
                .required(
                    "items",
                    list(1, 40, |item, path| {
                        Ok(Struct::new(item, path)?
                            .required("title", text(200))?
                            .optional("detail", text(400))?
                            .optional("status", literal(&["done", "current", "pending", "failed"]))?
                            .optional("tone", tone)?
                            .done())
                    }),
                )?,
            Some("callout") => s
                .required("type", literal(&["callout"]))?
                .optional("tone", literal(&["info", "success", "warning", "danger"]))?
                .optional("title", text(120))?
                .required("text", text(1_000))?,
            Some("compare") => s.required("type", literal(&["compare"]))?.required(
                "options",
                list(2, 4, |item, path| {
                    Ok(Struct::new(item, path)?
                        .required("title", text(60))?
                        .optional("subtitle", text(80))?
                        .optional("highlight", boolean)?
                        .required(
                            "points",
                            list(1, 12, |point, path| {
                                Ok(Struct::new(point, path)?.required("label", text(60))?.required("value", text(120))?.done())
                            }),
                        )?
                        .done())
                }),
            )?,
            Some("calculator") => s
                .required("type", literal(&["calculator"]))?
                .optional("title", text(120))?
                .required(
                    "inputs",
                    list(1, 8, |item, path| {
                        Ok(Struct::new(item, path)?
                            .required("id", calculator_id)?
                            .required("label", text(60))?
                            .required("value", finite)?
                            .optional("min", finite)?
                            .optional("max", finite)?
                            .optional("step", positive)?
                            .optional("unit", text(12))?
                            .done())
                    }),
                )?
                .required(
                    "outputs",
                    list(1, 8, |item, path| {
                        Ok(Struct::new(item, path)?
                            .optional("id", calculator_id)?
                            .required("label", text(60))?
                            .required("formula", text(300))?
                            .optional("unit", text(12))?
                            .optional("prefix", text(4))?
                            .optional("decimals", int(0, Some(6)))?
                            .optional("emphasis", boolean)?
                            .done())
                    }),
                )?,
            Some("choices") => s.required("type", literal(&["choices"]))?.optional("prompt", text(200))?.required(
                "options",
                list(1, 6, |item, path| {
                    Ok(Struct::new(item, path)?
                        .required("label", text(80))?
                        .optional("description", text(160))?
                        .optional("message", text(1_000))?
                        .done())
                }),
            )?,
            Some("tabs") if allow_tabs => s.required("type", literal(&["tabs"]))?.required(
                "tabs",
                list(2, 6, |item, path| {
                    Ok(Struct::new(item, path)?
                        .required("label", text(40))?
                        .required("blocks", list(1, MAX_BLOCKS, block(false)))?
                        .done())
                }),
            )?,
            Some("tabs") => return Err(at(&format!("{path}.type"), "Tabs hold any block except tabs")),
            _ => {
                let found = value.as_object().and_then(|fields| fields.get("type")).map(shown).unwrap_or_else(|| "nothing".into());
                return Err(at(&format!("{path}.type"), format!("Expected a block type, got {found}")));
            }
        };
        Ok(s.done())
    }
}

/// A table cell: `null`, a string of at most 400 characters (not trimmed), or a finite number.
fn table_cell(value: &Value, path: &str) -> Checked {
    match value {
        Value::String(cell) if utf16_len(cell) <= 400 => Ok(value.clone()),
        Value::String(_) => Err(at(path, "Expected a string of at most 400 characters")),
        Value::Number(_) => Ok(value.clone()),
        _ => Err(at(path, format!("Expected a string, a number or null, got {}", shown(value)))),
    }
}

/// Synara `CalculatorId`: letters, digits and underscores, as formulas read them.
fn calculator_id(value: &Value, path: &str) -> Checked {
    let valid = value.as_str().is_some_and(|id| {
        let mut chars = id.chars();
        chars.next().is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
            && id.len() <= 32
            && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
    });
    if valid {
        Ok(value.clone())
    } else {
        Err(at(path, format!("Expected an id of letters, digits and underscores, got {}", shown(value))))
    }
}

/// Synara `Schema.decodeUnknownSync(InlineVisualSpec)({ blocks })`: the normalized blocks.
pub fn decode_blocks(blocks: &Value) -> Result<Vec<Value>, String> {
    match list(1, MAX_BLOCKS, block(true))(blocks, "blocks")? {
        Value::Array(blocks) => Ok(blocks),
        _ => unreachable!("a list decodes to an array"),
    }
}
