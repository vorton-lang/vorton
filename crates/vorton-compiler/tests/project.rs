use std::collections::BTreeMap;

use vorton_compiler::{
    FileModulePath, ProjectDiagnosticKind, ProjectSources, SourceRef, resolve_project,
};

#[test]
fn public_project_api_resolves_owned_sources_and_preserves_frontend_origin() {
    let api = FileModulePath::new(["api"]).expect("abstract module key");
    let modules = BTreeMap::from([(api.clone(), "pub fn answer() -> Int { 42 }".to_owned())]);
    let mut sources = ProjectSources {
        root: "use api::answer; fn main() -> Int { answer() }".to_owned(),
        modules,
    };
    let resolved = resolve_project(&sources).expect("public project entry resolves");
    sources.root.clear();
    sources.modules.clear();
    assert_eq!(resolved, resolved.clone());

    let diagnostic = resolve_project(&ProjectSources {
        root: "use api;".to_owned(),
        modules: BTreeMap::from([(api.clone(), "@bad".to_owned())]),
    })
    .expect_err("reachable frontend failure remains structured");
    assert!(matches!(
        diagnostic.kind,
        ProjectDiagnosticKind::Frontend(_)
    ));
    assert_eq!(
        diagnostic.primary.expect("source origin").source,
        SourceRef::File(api)
    );
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
    resolve_project(&ProjectSources {
        root: "fn main() {}".to_owned(),
        modules: BTreeMap::from([(hidden.clone(), "generate hidden {}".to_owned())]),
    })
    .expect("an unreachable generate item does not enter the project closure");

    let diagnostic = resolve_project(&ProjectSources {
        root: "use generate;".to_owned(),
        modules: BTreeMap::from([(hidden.clone(), "generate reachable {}".to_owned())]),
    })
    .expect_err("a reachable generate item requires the later generation stage");
    assert_eq!(diagnostic.kind, ProjectDiagnosticKind::GenerateUnsupported);
    assert_eq!(
        diagnostic.primary.expect("generate origin").source,
        SourceRef::File(hidden)
    );

    let source = "fn broken() { missing } generate ctx {}";
    let diagnostic = resolve_project(&ProjectSources {
        root: source.to_owned(),
        modules: BTreeMap::new(),
    })
    .expect_err("generate rejection precedes declaration and body-name checks");
    assert_eq!(diagnostic.kind, ProjectDiagnosticKind::GenerateUnsupported);
    let primary = diagnostic.primary.expect("generate keyword origin");
    let generate_start = source.find("generate").expect("generate spelling");
    assert_eq!(primary.source, SourceRef::Root);
    assert_eq!(primary.span.start, generate_start);
    assert_eq!(primary.span.end, generate_start + "generate".len());

    let broken = FileModulePath::new(["broken"]).expect("module key");
    let diagnostic = resolve_project(&ProjectSources {
        root: "use broken; generate ctx {}".to_owned(),
        modules: BTreeMap::from([(broken.clone(), "@".to_owned())]),
    })
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
    let diagnostic = resolve_project(&ProjectSources {
        root: "generate ctx {} mod clash {}".to_owned(),
        modules: BTreeMap::from([(clash, String::new())]),
    })
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
    let diagnostic = resolve_project(&ProjectSources {
        root: "use z; use a;".to_owned(),
        modules: BTreeMap::from([
            (later, "generate at_zero {}".to_owned()),
            (first.clone(), first_source.to_owned()),
        ]),
    })
    .expect_err("reachable generate inventory should choose one stable diagnostic");
    assert_eq!(diagnostic.kind, ProjectDiagnosticKind::GenerateUnsupported);
    let primary = diagnostic.primary.expect("generate origin");
    assert_eq!(primary.source, SourceRef::File(first));
    let start = first_source.find("generate").expect("first generate");
    assert_eq!(primary.span.start, start);
}
