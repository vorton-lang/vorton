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
    CoreRoleDiagnostic, CoreRoleIssue, FileModulePath, FileModulePathError,
    FileModulePathErrorKind, LibraryId, LibrarySources, NameNamespace, OriginRef,
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

/// Validates and resolves a platform-independent, in-memory Vorton library DAG
/// with one host-selected official core library.
///
/// Every source identity and source-backed diagnostic retains its owning
/// [`LibraryId`]. Every reachable non-core library must directly depend on the
/// supplied core identity. Reachable `generate` items currently return
/// [`ProjectDiagnosticKind::GenerateUnsupported`] after frontend and module
/// graph checks, before declaration or body-name resolution.
pub fn resolve_project(sources: &ProjectSources) -> Result<ResolvedProject, ProjectDiagnostic> {
    resolver::resolve_project(sources)
}
