//! Canonical Vorton source-to-AST frontend.

mod lexer;
mod parser;

pub mod ast;
pub mod diagnostic;

pub use ast::Program;
pub use diagnostic::FrontendDiagnostic;

/// Parses one UTF-8 Vorton source into a complete surface AST.
///
/// Lexing always completes before parsing begins. On failure this returns the
/// first lexical error, or otherwise the first parser error; no partial AST is
/// exposed.
pub fn parse(source: &str) -> Result<Program, FrontendDiagnostic> {
    let tokens = lexer::lex(source)?;
    parser::parse(tokens, source.len())
}
