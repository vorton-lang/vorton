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
