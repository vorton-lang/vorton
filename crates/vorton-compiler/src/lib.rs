//! Canonical Vorton frontend, contract reader, project resolver, declaration preparation, and Checker.

mod checker;
mod contract;
mod lexer;
mod parser;
mod project;
mod resolver;

pub mod ast;
pub mod diagnostic;

pub use ast::Program;
pub use checker::{
    CheckDiagnostic, CheckDiagnosticKind, CheckOrigin, CheckedProject, PreparedProject,
};
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

/// Resolves and checks one closed in-memory project together with selected
/// format-1 contract documents.
///
/// `owners` maps each document owner label to the real [`LibraryId`] in this
/// project. An empty document list is valid, and unused owner mappings have no
/// effect. The current narrow Checker accepts pure-value functions over `Int`,
/// `Float`, `Bool`, `Unit`, `Never`, tuples, and non-generic transparent
/// aliases. It supports function-level HM inference and type formals, recursive
/// binding groups, per-call instantiation, matching generic contract formals,
/// and whole-binding Borrow/Move checks for the supported generic values. Any
/// reachable source or selected clause outside that subset returns
/// [`CheckDiagnosticKind::Unsupported`] rather than being treated as checked.
/// Success returns one owned opaque result containing closed schemes, typed
/// bodies, call mappings, and the exact facts established during this call.
pub fn check_project(
    sources: &ProjectSources,
    owners: &std::collections::BTreeMap<String, LibraryId>,
    documents: Vec<ContractDocument>,
) -> Result<CheckedProject, CheckDiagnostic> {
    checker::check_project(sources, owners, documents)
}
