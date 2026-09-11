use std::collections::BTreeMap;

use vorton_compiler::{
    FileModulePath, LibraryId, LibrarySources, ProjectDiagnostic, ProjectDiagnosticKind,
    ProjectSources, SourceRef, SupertraitTargetKind, prepare_project, resolve_project,
};

const APP: LibraryId = LibraryId(0);
const DEPENDENCY: LibraryId = LibraryId(1);
const CORE: LibraryId = LibraryId(u32::MAX);
const CORE_SOURCE: &str = include_str!("../../../core/root.vorton");

fn with_core(
    mut libraries: BTreeMap<LibraryId, LibrarySources>,
) -> BTreeMap<LibraryId, LibrarySources> {
    for (library_id, library) in &mut libraries {
        if *library_id != CORE {
            library.dependencies.insert("vorton_core".to_owned(), CORE);
        }
    }
    libraries.insert(
        CORE,
        LibrarySources {
            root: CORE_SOURCE.to_owned(),
            modules: BTreeMap::new(),
            dependencies: BTreeMap::new(),
        },
    );
    libraries
}

fn project(root: &str, modules: BTreeMap<FileModulePath, String>) -> ProjectSources {
    ProjectSources {
        entry: APP,
        core: CORE,
        libraries: with_core(BTreeMap::from([(
            APP,
            LibrarySources {
                root: root.to_owned(),
                modules,
                dependencies: BTreeMap::new(),
            },
        )])),
    }
}

fn prepare(sources: &ProjectSources) -> Result<(), ProjectDiagnostic> {
    let resolved = resolve_project(sources)?;
    prepare_project(resolved).map(|_| ())
}

fn prepare_root(root: &str) -> Result<(), ProjectDiagnostic> {
    prepare(&project(root, BTreeMap::new()))
}

fn preparation_error(root: &str) -> ProjectDiagnostic {
    match prepare_root(root) {
        Ok(()) => panic!("declaration preparation should reject this source"),
        Err(diagnostic) => diagnostic,
    }
}

#[test]
fn public_project_api_resolves_owned_sources_and_preserves_frontend_origin() {
    let api = FileModulePath::new(["api"]).expect("abstract module key");
    let mut sources = ProjectSources {
        entry: APP,
        core: CORE,
        libraries: with_core(BTreeMap::from([
            (
                APP,
                LibrarySources {
                    root: "use dep::answer; fn main() -> Int { answer() }".to_owned(),
                    modules: BTreeMap::new(),
                    dependencies: BTreeMap::from([("dep".to_owned(), DEPENDENCY)]),
                },
            ),
            (
                DEPENDENCY,
                LibrarySources {
                    root: "pub use api::answer;".to_owned(),
                    modules: BTreeMap::from([(
                        api.clone(),
                        "pub fn answer() -> Int { 42 }".to_owned(),
                    )]),
                    dependencies: BTreeMap::new(),
                },
            ),
        ])),
    };
    let resolved = resolve_project(&sources).expect("public project entry resolves");
    sources.libraries.clear();
    assert_eq!(resolved, resolved.clone());

    let diagnostic = resolve_project(&ProjectSources {
        entry: APP,
        core: CORE,
        libraries: with_core(BTreeMap::from([
            (
                APP,
                LibrarySources {
                    root: "fn main() {}".to_owned(),
                    modules: BTreeMap::new(),
                    dependencies: BTreeMap::from([("dep".to_owned(), DEPENDENCY)]),
                },
            ),
            (
                DEPENDENCY,
                LibrarySources {
                    root: "use api;".to_owned(),
                    modules: BTreeMap::from([(api.clone(), "@bad".to_owned())]),
                    dependencies: BTreeMap::new(),
                },
            ),
        ])),
    })
    .expect_err("reachable frontend failure remains structured");
    assert!(matches!(
        diagnostic.kind,
        ProjectDiagnosticKind::Frontend(_)
    ));
    let primary = diagnostic.primary.expect("source origin");
    assert_eq!(primary.library, DEPENDENCY);
    assert_eq!(primary.source, SourceRef::File(api));
}

#[test]
fn library_graph_diagnostics_expose_real_input_identities_without_source_spans() {
    let missing = LibraryId(99);
    let diagnostic = resolve_project(&ProjectSources {
        entry: APP,
        core: CORE,
        libraries: with_core(BTreeMap::from([(
            APP,
            LibrarySources {
                root: "@frontend_would_be_later".to_owned(),
                modules: BTreeMap::new(),
                dependencies: BTreeMap::from([("model".to_owned(), missing)]),
            },
        )])),
    })
    .expect_err("missing dependency target is an input diagnostic");
    assert_eq!(
        diagnostic.kind,
        ProjectDiagnosticKind::MissingDependencyTarget {
            owner: APP,
            alias: "model".to_owned(),
            target: missing,
        }
    );
    assert!(diagnostic.primary.is_none());
    assert!(diagnostic.related.is_empty());
}

#[test]
fn diagnostic_origins_distinguish_consumer_and_dependency_sources() {
    let diagnostic = resolve_project(&ProjectSources {
        entry: APP,
        core: CORE,
        libraries: with_core(BTreeMap::from([
            (
                APP,
                LibrarySources {
                    root: "use dep::Both;".to_owned(),
                    modules: BTreeMap::new(),
                    dependencies: BTreeMap::from([("dep".to_owned(), DEPENDENCY)]),
                },
            ),
            (
                DEPENDENCY,
                LibrarySources {
                    root: "pub struct Both {} pub fn Both() {}".to_owned(),
                    modules: BTreeMap::new(),
                    dependencies: BTreeMap::new(),
                },
            ),
        ])),
    })
    .expect_err("a cross-namespace dependency import is ambiguous");
    assert!(matches!(
        diagnostic.kind,
        ProjectDiagnosticKind::AmbiguousImport { ref path } if path == "dep::Both"
    ));
    assert_eq!(diagnostic.primary.expect("use origin").library, APP);
    assert_eq!(diagnostic.related.len(), 2);
    assert!(
        diagnostic
            .related
            .iter()
            .all(|origin| origin.library == DEPENDENCY && origin.source == SourceRef::Root)
    );
    assert!(diagnostic.related[0].span < diagnostic.related[1].span);
}

#[test]
fn contextual_frontend_spellings_remain_valid_file_module_segments() {
    for spelling in ["generate", "scoped", "call"] {
        FileModulePath::new([spelling]).unwrap_or_else(|error| {
            panic!("contextual spelling {spelling:?} should remain a module segment: {error:?}")
        });
    }
}

#[test]
fn generate_is_rejected_after_frontend_and_module_graph_but_before_name_resolution() {
    let hidden = FileModulePath::new(["generate"]).expect("contextual module key");
    resolve_project(&project(
        "fn main() {}",
        BTreeMap::from([(hidden.clone(), "generate hidden {}".to_owned())]),
    ))
    .expect("an unreachable generate item does not enter the project closure");

    let diagnostic = resolve_project(&project(
        "use generate;",
        BTreeMap::from([(hidden.clone(), "generate reachable {}".to_owned())]),
    ))
    .expect_err("a reachable generate item requires the later generation stage");
    assert_eq!(diagnostic.kind, ProjectDiagnosticKind::GenerateUnsupported);
    assert_eq!(
        diagnostic.primary.expect("generate origin").source,
        SourceRef::File(hidden)
    );

    let source = "fn broken() { missing } generate ctx {}";
    let diagnostic = resolve_project(&project(source, BTreeMap::new()))
        .expect_err("generate rejection precedes declaration and body-name checks");
    assert_eq!(diagnostic.kind, ProjectDiagnosticKind::GenerateUnsupported);
    let primary = diagnostic.primary.expect("generate keyword origin");
    let generate_start = source.find("generate").expect("generate spelling");
    assert_eq!(primary.source, SourceRef::Root);
    assert_eq!(primary.span.start, generate_start);
    assert_eq!(primary.span.end, generate_start + "generate".len());

    let broken = FileModulePath::new(["broken"]).expect("module key");
    let diagnostic = resolve_project(&project(
        "use broken; generate ctx {}",
        BTreeMap::from([(broken.clone(), "@".to_owned())]),
    ))
    .expect_err("reachable frontend failure precedes generate rejection");
    assert!(matches!(
        diagnostic.kind,
        ProjectDiagnosticKind::Frontend(_)
    ));
    assert_eq!(
        diagnostic.primary.expect("frontend origin").source,
        SourceRef::File(broken)
    );

    let clash = FileModulePath::new(["clash"]).expect("module key");
    let diagnostic = resolve_project(&project(
        "generate ctx {} mod clash {}",
        BTreeMap::from([(clash, String::new())]),
    ))
    .expect_err("module graph failure precedes generate rejection");
    assert!(matches!(
        diagnostic.kind,
        ProjectDiagnosticKind::ModuleBodyConflict { .. }
    ));
}

#[test]
fn multiple_generate_items_use_logical_module_then_utf8_span_order() {
    let first = FileModulePath::new(["a"]).expect("module key");
    let later = FileModulePath::new(["z"]).expect("module key");
    let first_source = "// λ\nfn unresolved() { missing } generate first {} generate second {}";
    let diagnostic = resolve_project(&project(
        "use z; use a;",
        BTreeMap::from([
            (later, "generate at_zero {}".to_owned()),
            (first.clone(), first_source.to_owned()),
        ]),
    ))
    .expect_err("reachable generate inventory should choose one stable diagnostic");
    assert_eq!(diagnostic.kind, ProjectDiagnosticKind::GenerateUnsupported);
    let primary = diagnostic.primary.expect("generate origin");
    assert_eq!(primary.source, SourceRef::File(first));
    let start = first_source.find("generate").expect("first generate");
    assert_eq!(primary.span.start, start);
}

#[test]
fn prepares_core_and_exact_multilibrary_declarations_without_checking_bodies_or_arity() {
    prepare(&ProjectSources {
        entry: CORE,
        core: CORE,
        libraries: with_core(BTreeMap::new()),
    })
    .expect("the official core prepares by itself");

    let api = FileModulePath::new(["api"]).expect("abstract module key");
    let sources = ProjectSources {
        entry: APP,
        core: CORE,
        libraries: with_core(BTreeMap::from([
            (
                APP,
                LibrarySources {
                    root: r#"
use dep::Base as First;
use dep::Base as Second;
use dep::IO as IO1;
use dep::IO as IO2;
use other::Base as Other;
use other::IO as OtherIO;

trait Combined: First + Second + Other {}
trait Generic<T> {}
trait DeferredArity: Generic<Int, Str> {}
effect alias CombinedIO = {IO1, IO2, OtherIO};
effect alias GenericEffect<T> = {fs};
effect alias DeferredEffectArity = {GenericEffect<Int, Str>};

fn deferred_body_check() -> Int { "checked later" }
"#
                    .to_owned(),
                    modules: BTreeMap::new(),
                    dependencies: BTreeMap::from([
                        ("dep".to_owned(), DEPENDENCY),
                        ("other".to_owned(), LibraryId(2)),
                    ]),
                },
            ),
            (
                DEPENDENCY,
                LibrarySources {
                    root: "pub use api::Base; pub use api::IO;".to_owned(),
                    modules: BTreeMap::from([(
                        api,
                        "pub trait Base {} pub effect alias IO = {fs};".to_owned(),
                    )]),
                    dependencies: BTreeMap::new(),
                },
            ),
            (
                LibraryId(2),
                LibrarySources {
                    root: "use dep::Base as Parent; use dep::IO as ParentIO; \
                           pub trait Base: Parent {} pub effect alias IO = {ParentIO};"
                        .to_owned(),
                    modules: BTreeMap::new(),
                    dependencies: BTreeMap::from([("dep".to_owned(), DEPENDENCY)]),
                },
            ),
        ])),
    };

    prepare(&sources).expect(
        "aliases retain exact identities while signature arity and body types remain deferred",
    );
}

#[test]
fn invalid_supertraits_report_the_resolved_type_category_and_real_origins() {
    let cases = [
        (
            "trait Bad: Int {}",
            SupertraitTargetKind::LanguageType,
            "Int",
            false,
        ),
        (
            "struct Parent {} trait Bad: Parent {}",
            SupertraitTargetKind::Struct,
            "Parent",
            true,
        ),
        (
            "enum Parent { Item } trait Bad: Parent {}",
            SupertraitTargetKind::Enum,
            "Parent",
            true,
        ),
        (
            "type Parent = Int; trait Bad: Parent {}",
            SupertraitTargetKind::TypeAlias,
            "Parent",
            true,
        ),
        (
            "extern type Parent; trait Bad: Parent {}",
            SupertraitTargetKind::ExternType,
            "Parent",
            true,
        ),
        (
            "trait Bad<T>: T {}",
            SupertraitTargetKind::TypeParameter,
            "T",
            true,
        ),
        (
            "trait Bad: Self {}",
            SupertraitTargetKind::SelfType,
            "Self",
            true,
        ),
        (
            "trait Has { type Item; } trait Bad: Has::Item {}",
            SupertraitTargetKind::AssociatedType,
            "Has::Item",
            true,
        ),
        (
            "trait Has { type Item; } trait Bad<T: Has>: T::Item {}",
            SupertraitTargetKind::TypeDependentSelection,
            "T::Item",
            false,
        ),
    ];

    for (source, actual, spelling, has_related_declaration) in cases {
        let diagnostic = preparation_error(source);
        assert_eq!(
            diagnostic.kind,
            ProjectDiagnosticKind::InvalidSupertrait { actual }
        );
        let primary = diagnostic.primary.expect("supertrait reference origin");
        assert_eq!(&source[primary.span.start..primary.span.end], spelling);
        assert_eq!(
            !diagnostic.related.is_empty(),
            has_related_declaration,
            "only real source targets contribute related origins"
        );
    }
}

#[test]
fn trait_cycles_are_exact_and_do_not_reject_acyclic_diamonds() {
    let self_cycle = "trait Loop<T>: Loop<Int> {}";
    let diagnostic = preparation_error(self_cycle);
    assert_eq!(
        diagnostic.kind,
        ProjectDiagnosticKind::TraitInheritanceCycle
    );
    let primary = diagnostic.primary.expect("self-reference origin");
    assert_eq!(&self_cycle[primary.span.start..primary.span.end], "Loop");
    assert_eq!(diagnostic.related.len(), 1);

    let mutual_cycle = "trait A: B {} trait B: A {}";
    let diagnostic = preparation_error(mutual_cycle);
    assert_eq!(
        diagnostic.kind,
        ProjectDiagnosticKind::TraitInheritanceCycle
    );
    let primary = diagnostic.primary.expect("first stable cycle edge");
    assert_eq!(&mutual_cycle[primary.span.start..primary.span.end], "B");
    assert_eq!(diagnostic.related.len(), 3);
    let closing_reference = diagnostic.related.last().expect("closing cycle reference");
    assert_eq!(
        &mutual_cycle[closing_reference.span.start..closing_reference.span.end],
        "A"
    );

    let definitions = FileModulePath::new(["definitions"]).expect("module key");
    let sources = project(
        "pub use definitions::Base as Alias;",
        BTreeMap::from([(
            definitions.clone(),
            "pub trait Base: root::Alias {}".to_owned(),
        )]),
    );
    let diagnostic = match prepare(&sources) {
        Ok(()) => panic!("a re-export alias retains the self target identity"),
        Err(diagnostic) => diagnostic,
    };
    assert_eq!(
        diagnostic.kind,
        ProjectDiagnosticKind::TraitInheritanceCycle
    );
    assert_eq!(
        diagnostic.primary.expect("aliased self reference").source,
        SourceRef::File(definitions)
    );

    prepare_root("trait A {} trait B: A {} trait C: A {} trait D: B + C {}")
        .expect("a shared acyclic diamond is legal");
}

#[test]
fn effect_alias_cycles_include_nested_method_scheme_row_actuals_only() {
    let self_cycle = "effect alias Loop<T> = {Loop<Int>};";
    let diagnostic = preparation_error(self_cycle);
    assert_eq!(diagnostic.kind, ProjectDiagnosticKind::EffectAliasCycle);
    let primary = diagnostic.primary.expect("self-reference origin");
    assert_eq!(&self_cycle[primary.span.start..primary.span.end], "Loop");

    let mutual_cycle = "effect alias A = {B}; effect alias B = {A};";
    let diagnostic = preparation_error(mutual_cycle);
    assert_eq!(diagnostic.kind, ProjectDiagnosticKind::EffectAliasCycle);
    let primary = diagnostic.primary.expect("first stable cycle edge");
    assert_eq!(&mutual_cycle[primary.span.start..primary.span.end], "B");
    let closing_reference = diagnostic.related.last().expect("closing cycle reference");
    assert_eq!(
        &mutual_cycle[closing_reference.span.start..closing_reference.span.end],
        "A"
    );

    let definitions = FileModulePath::new(["definitions"]).expect("module key");
    let sources = project(
        "pub use definitions::Loop as Alias;",
        BTreeMap::from([(
            definitions.clone(),
            "pub effect alias Loop = {root::Alias};".to_owned(),
        )]),
    );
    let diagnostic = match prepare(&sources) {
        Ok(()) => panic!("a re-export alias retains the self target identity"),
        Err(diagnostic) => diagnostic,
    };
    assert_eq!(diagnostic.kind, ProjectDiagnosticKind::EffectAliasCycle);
    assert_eq!(
        diagnostic.primary.expect("aliased self reference").source,
        SourceRef::File(definitions)
    );

    let nested_cycle = r#"
trait Scheme {
    fn apply<effect E>(self: Self) -> Unit with {E};
}
effect alias Nested = {Scheme::apply<Int, effect {Nested}>};
"#;
    let diagnostic = preparation_error(nested_cycle);
    assert_eq!(diagnostic.kind, ProjectDiagnosticKind::EffectAliasCycle);
    let primary = diagnostic.primary.expect("nested alias reference origin");
    assert_eq!(
        &nested_cycle[primary.span.start..primary.span.end],
        "Nested"
    );

    prepare_root(
        "effect Plain { fn op() -> Unit; } \
         effect alias Safe = {Plain, Scheme::apply<Int>}; \
         trait Scheme { fn apply(self: Self) -> Unit with {Safe}; } \
         fn keep<effect E>() -> Unit with {E} {}",
    )
    .expect("ordinary effects, formals, and method scheme declarations are not alias edges");
}

#[test]
fn preparation_uses_phase_then_library_and_logical_module_order_for_the_first_error() {
    let diagnostic = preparation_error(
        "effect alias EffectLoop = {EffectLoop}; \
         trait TraitLoop: TraitLoop {} \
         trait Bad: Int {}",
    );
    assert!(matches!(
        diagnostic.kind,
        ProjectDiagnosticKind::InvalidSupertrait { .. }
    ));

    let diagnostic =
        preparation_error("effect alias EffectLoop = {EffectLoop}; trait TraitLoop: TraitLoop {}");
    assert_eq!(
        diagnostic.kind,
        ProjectDiagnosticKind::TraitInheritanceCycle
    );

    let a = FileModulePath::new(["a"]).expect("module key");
    let z = FileModulePath::new(["z"]).expect("module key");
    let reverse = project(
        "use z; use a;",
        BTreeMap::from([
            (z, "effect alias Z = {Z};".to_owned()),
            (a.clone(), "effect alias A = {A};".to_owned()),
        ]),
    );
    let forward = project(
        "use z; use a;",
        BTreeMap::from([
            (a.clone(), "effect alias A = {A};".to_owned()),
            (
                FileModulePath::new(["z"]).expect("module key"),
                "effect alias Z = {Z};".to_owned(),
            ),
        ]),
    );
    let diagnostic = match prepare(&reverse) {
        Ok(()) => panic!("both reachable modules contain an alias cycle"),
        Err(diagnostic) => diagnostic,
    };
    let reordered = match prepare(&forward) {
        Ok(()) => panic!("both reachable modules contain an alias cycle"),
        Err(diagnostic) => diagnostic,
    };
    assert_eq!(diagnostic, reordered);
    assert_eq!(diagnostic.kind, ProjectDiagnosticKind::EffectAliasCycle);
    assert_eq!(
        diagnostic.primary.expect("cycle reference origin").source,
        SourceRef::File(a)
    );

    let sources = ProjectSources {
        entry: APP,
        core: CORE,
        libraries: with_core(BTreeMap::from([
            (
                APP,
                LibrarySources {
                    root: String::new(),
                    modules: BTreeMap::new(),
                    dependencies: BTreeMap::from([
                        ("later".to_owned(), LibraryId(2)),
                        ("first".to_owned(), DEPENDENCY),
                    ]),
                },
            ),
            (
                LibraryId(2),
                LibrarySources {
                    root: "effect alias Later = {Later};".to_owned(),
                    modules: BTreeMap::new(),
                    dependencies: BTreeMap::new(),
                },
            ),
            (
                DEPENDENCY,
                LibrarySources {
                    root: "effect alias First = {First};".to_owned(),
                    modules: BTreeMap::new(),
                    dependencies: BTreeMap::new(),
                },
            ),
        ])),
    };
    let diagnostic = match prepare(&sources) {
        Ok(()) => panic!("both reachable libraries contain an alias cycle"),
        Err(diagnostic) => diagnostic,
    };
    assert_eq!(
        diagnostic.primary.expect("first library cycle").library,
        DEPENDENCY
    );
}
