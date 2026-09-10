use std::collections::BTreeMap;

use vorton_compiler::{
    FileModulePath, LibraryId, LibrarySources, ProjectDiagnosticKind, ProjectSources, SourceRef,
    resolve_project,
};

const APP: LibraryId = LibraryId(0);
const DEPENDENCY: LibraryId = LibraryId(1);

fn project(root: &str, modules: BTreeMap<FileModulePath, String>) -> ProjectSources {
    ProjectSources {
        entry: APP,
        libraries: BTreeMap::from([(
            APP,
            LibrarySources {
                root: root.to_owned(),
                modules,
                dependencies: BTreeMap::new(),
            },
        )]),
    }
}

#[test]
fn public_project_api_resolves_owned_sources_and_preserves_frontend_origin() {
    let api = FileModulePath::new(["api"]).expect("abstract module key");
    let mut sources = ProjectSources {
        entry: APP,
        libraries: BTreeMap::from([
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
        ]),
    };
    let resolved = resolve_project(&sources).expect("public project entry resolves");
    sources.libraries.clear();
    assert_eq!(resolved, resolved.clone());

    let diagnostic = resolve_project(&ProjectSources {
        entry: APP,
        libraries: BTreeMap::from([
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
        ]),
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
        libraries: BTreeMap::from([(
            APP,
            LibrarySources {
                root: "@frontend_would_be_later".to_owned(),
                modules: BTreeMap::new(),
                dependencies: BTreeMap::from([("model".to_owned(), missing)]),
            },
        )]),
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
        libraries: BTreeMap::from([
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
        ]),
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
