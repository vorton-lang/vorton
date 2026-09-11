//! Canonical Vorton frontend, contract input reader, project resolver, and declaration preparation.

mod checker;
mod contract;
mod lexer;
mod parser;
mod project;
mod resolver;

pub mod ast;
pub mod diagnostic;

pub use ast::Program;
pub use checker::PreparedProject;
pub use contract::{ContractDiagnostic, ContractDiagnosticKind, ContractDocument};
pub use diagnostic::FrontendDiagnostic;
pub use project::{
    CoreRoleDiagnostic, CoreRoleIssue, FileModulePath, FileModulePathError,
    FileModulePathErrorKind, LibraryId, LibrarySources, NameNamespace, OriginRef,
    ProjectDiagnostic, ProjectDiagnosticKind, ProjectSources, ResolvedProject, SourceRef,
    SupertraitTargetKind,
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

/// Decodes one in-memory Vorton contract document without binding it to source.
///
/// Success guarantees the supported UTF-8 JSON profile, format version, and
/// record structure only. The returned document is owned and opaque; this
/// entry point does not resolve contract references or check source semantics.
pub fn decode_contract(source: &[u8]) -> Result<ContractDocument, ContractDiagnostic> {
    contract::decode_contract(source)
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

/// Checks the declaration graph invariants needed before type and effect checking.
///
/// This consumes an owned [`ResolvedProject`] without parsing or resolving it
/// again. Success guarantees that every supertrait names an actual trait and
/// that trait inheritance and effect-alias declaration graphs are acyclic. It
/// does not check signatures or bodies, expand aliases, or produce typed HIR.
pub fn prepare_project(project: ResolvedProject) -> Result<PreparedProject, ProjectDiagnostic> {
    checker::prepare_project(project)
}
