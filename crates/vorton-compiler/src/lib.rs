//! The Vorton compiler: frontend, project resolver, checker and C11 backend.

mod borrowck;
mod capabilities;
mod checker;
mod codegen;
mod depth;
mod exhaustive;
mod lexer;
mod lower;
mod mir;
mod mono;
mod parser;
mod prepare;
mod project;
mod resolver;
mod tail;
mod typed;
mod types;
mod unread;
mod verify;

pub mod ast;
pub mod diagnostic;
pub mod native;

use std::collections::BTreeMap;

pub use ast::Program;
pub use diagnostic::{CheckDiagnostic, CheckDiagnosticKind, FrontendDiagnostic};
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
    on_large_stack(|| parse_source(source))
}

pub(crate) fn parse_source(source: &str) -> Result<Program, FrontendDiagnostic> {
    let tokens = lexer::lex(source)?;
    parser::parse(tokens, source.len())
}

/// The stack of the thread the compiler runs on. Every pass recurses as
/// deep as the source nests, and the spec's nesting limit is what this stack
/// must hold; the space is reserved, and only what is used is committed.
const STACK_SIZE: usize = 1 << 30;

/// Runs `work` on a thread with a stack of [`STACK_SIZE`], so the result does
/// not depend on the caller's stack.
fn on_large_stack<T: Send>(work: impl FnOnce() -> T + Send) -> T {
    std::thread::scope(|scope| {
        std::thread::Builder::new()
            .stack_size(STACK_SIZE)
            .spawn_scoped(scope, work)
            .expect("the compiler thread starts")
            .join()
            .unwrap_or_else(|panic| std::panic::resume_unwind(panic))
    })
}

/// Validates and resolves a platform-independent, in-memory Vorton library DAG
/// with one host-selected official core library.
///
/// Every source identity and source-backed diagnostic retains its owning
/// [`LibraryId`]. Every reachable non-core library must directly depend on the
/// supplied core identity.
pub fn resolve_project(sources: &ProjectSources) -> Result<ResolvedProject, ProjectDiagnostic> {
    on_large_stack(|| resolver::resolve_project(sources))
}

/// Checks the declaration graph invariants needed before type and effect checking.
///
/// This consumes an owned [`ResolvedProject`] without parsing or resolving it
/// again. Success guarantees that every supertrait names an actual trait and
/// that trait inheritance and effect-alias declaration graphs are acyclic. It
/// does not check signatures or bodies, expand aliases, or produce typed HIR.
pub fn prepare_project(project: ResolvedProject) -> Result<PreparedProject, ProjectDiagnostic> {
    on_large_stack(|| prepare::prepare_project(project))
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
    on_large_stack(|| {
        let resolved = resolver::resolve_project(sources).map_err(CompileError::Project)?;
        let prepared = prepare::prepare_project(resolved).map_err(CompileError::Project)?;
        let checked = checker::check(prepared.project()).map_err(CompileError::Check)?;
        let program = instantiate_checked(checked).map_err(CompileError::Check)?;
        Ok(codegen::emit(&program))
    })
}

/// The middle of the pipeline: lowers each checked function to the IR once,
/// checks its moves and borrows, instantiates the generic functions, checks
/// what the instances may do, and marks their tail calls.
fn instantiate_checked(checked: typed::Program) -> Result<mir::Program, CheckDiagnostic> {
    let typed::Program {
        types,
        functions,
        main,
        impls,
    } = checked;
    let mut templates = Vec::new();
    for function in &functions {
        let origin = &function.origin;
        let (mut body, changes) = lower::lower(function, &types);
        verify::verify(&body, &types, &function.name, "lowering");
        let at = |span| origin.at(span);
        // Both analyses name statements by position, so they run before
        // the checks are inserted.
        let checks = borrowck::check(&body, &types, &at)?;
        unread::check(&body, &changes, &at)?;
        body.insert_checks(checks);
        verify::verify(&body, &types, &function.name, "borrow checking");
        templates.push(mono::Template {
            name: function.name.clone(),
            origin: origin.clone(),
            body,
            generic: function.generic,
        });
    }
    let mut program = mono::instantiate(types, &templates, main, &impls)?;
    capabilities::check_drops(&program)?;
    tail::mark(&mut program);
    for instance in &program.functions {
        verify::verify(
            &instance.body,
            &program.types,
            &instance.name,
            "instantiation",
        );
    }
    Ok(program)
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
