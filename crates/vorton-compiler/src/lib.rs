//! The Vorton compiler: frontend, project resolver, checker and C11 backend.

mod checker;
mod codegen;
mod lexer;
mod parser;
mod prepare;
mod project;
mod resolver;

pub mod ast;
pub mod diagnostic;
pub mod native;

use std::collections::BTreeMap;

pub use ast::Program;
pub use checker::{CheckDiagnostic, CheckDiagnosticKind};
pub use diagnostic::FrontendDiagnostic;
pub use prepare::PreparedProject;
pub use project::{
    CoreRoleDiagnostic, CoreRoleIssue, FileModulePath, FileModulePathError,
    FileModulePathErrorKind, LibraryId, LibrarySources, NameNamespace, OriginRef,
    ProjectDiagnostic, ProjectDiagnosticKind, ProjectSources, ResolvedProject, SourceRef,
    SupertraitTargetKind,
};

/// The official core library source bundled with this compiler.
pub const CORE_SOURCE: &str = include_str!("../../../core/root.vorton");

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
/// supplied core identity.
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
    prepare::prepare_project(project)
}

/// One failure from [`compile_to_c`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CompileError {
    Project(ProjectDiagnostic),
    Check(CheckDiagnostic),
}

/// Resolves and checks a project, then translates it into one self-contained
/// C11 translation unit whose `main` runs the entry library's `fn main()`.
pub fn compile_to_c(sources: &ProjectSources) -> Result<String, CompileError> {
    let resolved = resolve_project(sources).map_err(CompileError::Project)?;
    let prepared = prepare_project(resolved).map_err(CompileError::Project)?;
    let program = checker::check(prepared.project()).map_err(CompileError::Check)?;
    Ok(codegen::emit(&program))
}

/// The library identity of the source passed to [`single_file_project`].
pub const SINGLE_FILE_LIBRARY: LibraryId = LibraryId(0);

/// Builds a project whose entry library is `source` and whose only dependency
/// is the bundled core, under the alias `core`.
pub fn single_file_project(source: &str) -> ProjectSources {
    let core = LibraryId(1);
    ProjectSources {
        entry: SINGLE_FILE_LIBRARY,
        core,
        libraries: BTreeMap::from([
            (
                SINGLE_FILE_LIBRARY,
                LibrarySources {
                    root: source.to_owned(),
                    modules: BTreeMap::new(),
                    dependencies: BTreeMap::from([("core".to_owned(), core)]),
                },
            ),
            (
                core,
                LibrarySources {
                    root: CORE_SOURCE.to_owned(),
                    modules: BTreeMap::new(),
                    dependencies: BTreeMap::new(),
                },
            ),
        ]),
    }
}
