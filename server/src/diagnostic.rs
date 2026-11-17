// SPDX-License-Identifier: MPL-2.0

//! Rhai errors as diagnostics: the innermost location first, the call sites
//! leading to it outward.

use rhai::{EvalAltResult, Position};
use serde::Serialize;

#[derive(Serialize, Clone, Copy, PartialEq, Eq, Debug)]
#[serde(rename_all = "lowercase")]
pub enum Severity {
    Error,
    Warning,
    Note,
}

/// A place in a script; `file` is set when it is not the script itself.
#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct Location {
    pub line: usize,
    pub column: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
}

impl Location {
    /// The start of the script, for messages about all of it.
    pub fn start() -> Self {
        Location {
            line: 1,
            column: 1,
            file: None,
        }
    }

    /// `position` in `source`, the name an AST was given, relative to
    /// `main`, the script's own name.
    pub fn new(position: Position, source: Option<&str>, main: Option<&str>) -> Option<Self> {
        Some(Location {
            line: position.line()?,
            column: position.position().unwrap_or(1),
            file: source
                .filter(|s| !s.is_empty() && Some(*s) != main)
                .map(str::to_owned),
        })
    }
}

#[derive(Serialize, Clone, Debug)]
pub struct Frame {
    #[serde(flatten)]
    pub at: Location,
    pub message: String,
}

#[derive(Serialize, Clone, Debug)]
pub struct Diagnostic {
    pub severity: Severity,
    #[serde(flatten)]
    pub at: Location,
    pub message: String,
    pub trace: Vec<Frame>,
}

impl Diagnostic {
    pub fn error(at: Location, message: String) -> Self {
        Diagnostic {
            severity: Severity::Error,
            at,
            message,
            trace: vec![],
        }
    }

    pub fn warning(at: Location, message: String) -> Self {
        Diagnostic {
            severity: Severity::Warning,
            ..Diagnostic::error(at, message)
        }
    }

    pub fn note(at: Location, message: String) -> Self {
        Diagnostic {
            severity: Severity::Note,
            ..Diagnostic::error(at, message)
        }
    }

    /// Unwraps `error` down to where it happened.  `main` is the name the
    /// script's AST was given, so that only other files are named.
    pub fn from_error(error: &EvalAltResult, main: Option<&str>) -> Self {
        let mut outward = vec![];
        let mut source = main.map(str::to_owned);
        let mut error = error;
        loop {
            match error {
                EvalAltResult::ErrorInFunctionCall(name, fn_source, inner, position) => {
                    let message = if name.starts_with("anon$") {
                        "in call to a closure".to_owned()
                    } else {
                        format!("in call to fn {name}")
                    };
                    outward.push((*position, source.clone(), message));
                    if !fn_source.is_empty() {
                        source = Some(fn_source.clone());
                    }
                    error = inner;
                }
                EvalAltResult::ErrorInModule(path, inner, position) => {
                    let name = std::path::Path::new(path)
                        .file_name()
                        .map_or(path.clone(), |n| n.to_string_lossy().into_owned());
                    outward.push((*position, source.clone(), format!("in import of {name}")));
                    source = Some(path.clone());
                    error = inner;
                }
                _ => break,
            }
        }
        let trace: Vec<Frame> = outward
            .into_iter()
            .rev()
            .filter_map(|(position, source, message)| {
                Some(Frame {
                    at: Location::new(position, source.as_deref(), main)?,
                    message,
                })
            })
            .collect();
        // An error without a position of its own happened at the nearest
        // call site.
        let at = Location::new(error.position(), source.as_deref(), main)
            .or_else(|| trace.first().map(|frame| frame.at.clone()))
            .unwrap_or_else(Location::start);
        Diagnostic {
            severity: Severity::Error,
            at,
            message: message(error),
            trace,
        }
    }
}

/// The error the calls and imports around `error` lead to.
pub fn innermost(mut error: &EvalAltResult) -> &EvalAltResult {
    while let EvalAltResult::ErrorInFunctionCall(_, _, inner, _)
    | EvalAltResult::ErrorInModule(_, inner, _) = error
    {
        error = inner;
    }
    error
}

/// `error`'s message without the position Rhai appends to it, and without
/// the "Runtime error" Rhai prefixes to the messages of fidget and of the
/// script API.
fn message(error: &EvalAltResult) -> String {
    match error {
        EvalAltResult::ErrorRuntime(value, _) | EvalAltResult::ErrorTerminated(value, _)
            if value.is_string() =>
        {
            return value.to_string();
        }
        _ => {}
    }
    let text = error.to_string();
    let position = error.position();
    let suffix = format!(" ({position})");
    let text = match text.strip_suffix(&suffix) {
        Some(text) if !position.is_none() => text,
        _ => &text,
    };
    // Rhai names a string argument by all three Rust types it may be.
    text.trim_end()
        .replace("&str | ImmutableString | String", "string")
}
