// SPDX-License-Identifier: MPL-2.0

//! Notes on calls of fidget built-ins that have a better keycap call, for
//! `.keycap` scripts.  A line of the script that reads `SILENCE` turns them
//! off, for a script that keeps fidget's calls on purpose.

use rhai::{ASTNode, Expr};

use crate::diagnostic::{Diagnostic, Location};
use crate::docs;

/// The line, anywhere in a script, that turns its notes off
const SILENCE: &str = "// keycap: no-prefer";

/// A note on each call in `source` of a built-in that `docs/`
/// says has a better keycap call, at the call's name.  Only `source` is
/// looked at, not the prelude or what it imports; a script that defines a
/// function of the name itself is calling that.
pub fn notes(engine: &rhai::Engine, source: &str) -> Vec<Diagnostic> {
    if source.lines().any(|line| line.trim() == SILENCE) {
        return vec![];
    }
    let Ok(ast) = engine.compile(source) else {
        return vec![];
    };
    let preferred = docs::preferred();
    let defined: Vec<String> = ast.iter_functions().map(|f| f.name.to_owned()).collect();
    let mut notes = vec![];
    ast.walk(&mut |nodes| {
        if let Some(ASTNode::Expr(Expr::FnCall(call, position))) = nodes.last()
            && call.namespace.is_empty()
            && !defined.contains(&call.name.to_string())
            && let Some((name, prefer, why)) = preferred.iter().find(|(n, _, _)| **n == *call.name)
            && let Some(at) = Location::new(*position, None, None)
        {
            notes.push(Diagnostic::note(
                at,
                format!("`{name}`: prefer `{prefer}` -- {why}"),
            ));
        }
        true
    });
    notes
}
