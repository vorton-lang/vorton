//! Canonical Vorton frontend and pure in-memory project resolver.

mod lexer;
mod parser;
mod project;
mod resolver;

pub mod ast;
pub mod diagnostic;

pub use ast::Program;
pub use diagnostic::FrontendDiagnostic;
pub use project::{
    FileModulePath, FileModulePathError, FileModulePathErrorKind, NameNamespace, OriginRef,
    ProjectDiagnostic, ProjectDiagnosticKind, ProjectSources, ResolvedProject, SourceRef,
};

/// Parses one UTF-8 Vorton source into a complete surface AST.
///
/// Lexing always completes before parsing begins. On failure this returns the
/// first lexical error, or otherwise the first parser error; no partial AST is
/// exposed.
pub fn parse(source: &str) -> Result<Program, FrontendDiagnostic> {
    let tokens = lexer::lex(source)?;
    parser::parse(tokens, source.len())
}

/// Parses and resolves a platform-independent, in-memory Vorton project.
pub fn resolve_project(sources: &ProjectSources) -> Result<ResolvedProject, ProjectDiagnostic> {
    resolver::resolve_project(sources)
}
