use std::collections::BTreeMap;
use std::fmt::Write as _;

use vorton_compiler::{
    CheckDiagnostic, CheckDiagnosticKind, CheckOrigin, FileModulePath, LibraryId, LibrarySources,
    ProjectDiagnosticKind, ProjectSources, check_project, decode_contract,
};

const APP: LibraryId = LibraryId(0);
const DEPENDENCY: LibraryId = LibraryId(1);
const OTHER: LibraryId = LibraryId(2);
const CORE: LibraryId = LibraryId(u32::MAX);
const CORE_SOURCE: &str = include_str!("../../../core/root.vorton");

fn with_core(
    mut libraries: BTreeMap<LibraryId, LibrarySources>,
) -> BTreeMap<LibraryId, LibrarySources> {
    for (library, sources) in &mut libraries {
        if *library != CORE {
            sources.dependencies.insert("vorton_core".to_owned(), CORE);
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

fn project(root: &str) -> ProjectSources {
    ProjectSources {
        entry: APP,
        core: CORE,
        libraries: with_core(BTreeMap::from([(
            APP,
            LibrarySources {
                root: root.to_owned(),
                modules: BTreeMap::new(),
                dependencies: BTreeMap::new(),
            },
        )])),
    }
}

fn check(root: &str) -> Result<vorton_compiler::CheckedProject, CheckDiagnostic> {
    check_project(&project(root), &BTreeMap::new(), Vec::new())
}

fn error(root: &str) -> CheckDiagnostic {
    check(root).expect_err("the Checker should reject this source")
}

fn contract(source: &str) -> vorton_compiler::ContractDocument {
    decode_contract(source.as_bytes()).expect("test contract uses the published format")
}

fn function_target(name: &str) -> String {
    format!(
        r#"{{"tag":"declaration","declaration":{{"library":{{"tag":"self"}},"path":["{name}"],"kind":"function"}}}}"#
    )
}

fn function_path_target(path: &[&str]) -> String {
    let path = path
        .iter()
        .map(|segment| format!(r#""{segment}""#))
        .collect::<Vec<_>>()
        .join(",");
    format!(
        r#"{{"tag":"declaration","declaration":{{"library":{{"tag":"self"}},"path":[{path}],"kind":"function"}}}}"#
    )
}

fn document(records: &str) -> String {
    format!(
        r#"{{"format":"vorton.contract","format_version":1,"semantics_version":"0.1","owner":"app","records":[{records}]}}"#
    )
}

#[test]
fn checks_real_typed_bodies_recursion_literals_aliases_and_copy_modes() {
    let source = r#"
requires {};
type Pair = ((Int), Bool);

fn forward(value: Int) -> Int { ((later))(value) }
fn later(value: move Int) -> Int { value }
fn preserve_copy(value: Int) -> Int { later(value); value }
fn int_math(left: Int, right: Int) -> Int { ((left + right) * right - left) / right % right }
fn float_math(left: Float, right: Float) -> Float { ((left + right) * right - left) / right % right }
fn logic(left: Bool, right: Bool) -> Bool { !left || left && right }
fn primitive_order(left: Bool, right: Bool) -> Bool { left != right && left < right || left > right || left >= right }

fn even(value: Int) -> Bool {
    if value == 0 { true } else { odd(value - 1) }
}
fn odd(value: Int) -> Bool {
    if value == 0 { false } else { even(value - 1) }
}

fn choose(flag: Bool, left: Int, right: Int) -> Int {
    let selected: Int = if flag { left } else { right };
    let pair: Pair = ((selected), true);
    pair.0
}

fn float_value() -> Float { -0.000000000000000000000000000000000000000000001 }
fn unit_order() -> Bool { () <= () }
fn bottom() -> Never { bottom() }
fn bottom_branch(flag: Bool) -> Int { if flag { bottom() } else { 1 } }
fn explicit(value: Int) -> Int { return value; }
fn explicit_pure() -> Unit with {} {}
fn runtime_arithmetic() -> Int { 1 / 0 }
fn main() -> Int { forward(choose(even(2), 4, 5)) }
"#;

    let checked = check(source).expect("the complete supported source subset checks");
    let debug = format!("{checked:?}");
    assert!(debug.contains("checked_function_count"));
}

#[test]
fn supported_contract_fields_bind_before_the_body_and_merge_idempotently() {
    let sources =
        project("pub type Pair = (Int, Bool); pub fn expose(value: Pair) -> Pair { value }");
    let alias = r#"{"tag":"nominal","declaration":{"library":{"tag":"self"},"path":["Pair"],"kind":"type_alias"},"arguments":[]}"#;
    let first = format!(
        r#"{{"target":{},"set":{{"parameter_types":[{{"parameter":{{"tag":"position","index":0}},"type":{alias}}}],"parameter_modes":[{{"parameter":{{"tag":"position","index":0}},"mode":{{"tag":"fixed","mode":"borrow"}}}}],"effect_upper":[],"generic_requirements":[]}}}}"#,
        function_target("expose")
    );
    let second = format!(
        r#"{{"target":{},"type_parameters":[],"set":{{"return_type":{alias}}}}}"#,
        function_target("expose")
    );
    let documents = vec![contract(&document(&first)), contract(&document(&second))];
    let owners = BTreeMap::from([("app".to_owned(), APP)]);

    check_project(&sources, &owners, documents)
        .expect("source and contract aliases normalize to the same checked type");
}

#[test]
fn rejects_source_type_operator_call_return_and_projection_failures_separately() {
    let cases = [
        (
            "fn bad() -> Int { true + 1 }",
            CheckDiagnosticKind::TypeMismatch,
        ),
        (
            "fn bad() -> Int { if 1 { 2 } else { 3 } }",
            CheckDiagnosticKind::TypeMismatch,
        ),
        (
            "fn takes(value: Int) -> Int { value } fn bad() -> Int { takes() }",
            CheckDiagnosticKind::CallMismatch,
        ),
        (
            "fn takes(value: Int) -> Int { value } fn bad() -> Int { takes(true) }",
            CheckDiagnosticKind::CallMismatch,
        ),
        (
            "fn bad() -> Int { return true; }",
            CheckDiagnosticKind::ReturnMismatch,
        ),
        ("fn bad() -> Int {}", CheckDiagnosticKind::ReturnMismatch),
        (
            "fn bad() -> Never { 1 }",
            CheckDiagnosticKind::ReturnMismatch,
        ),
        (
            "fn bad() -> Int { (1, true).2 }",
            CheckDiagnosticKind::TypeMismatch,
        ),
    ];
    for (source, expected) in cases {
        assert_eq!(error(source).kind, expected, "source: {source}");
    }
}

#[test]
fn numeric_literal_boundaries_are_interpreted_without_evaluating_arithmetic() {
    let subnormal = format!("0.{}5", "0".repeat(323));
    let rounded_zero = format!("0.{}1", "0".repeat(400));
    assert!(
        subnormal
            .parse::<f64>()
            .expect("host parser used by the Checker")
            .is_subnormal()
    );
    assert_eq!(
        rounded_zero
            .parse::<f64>()
            .expect("host parser used by the Checker"),
        0.0
    );
    let valid = format!(
        "fn min() -> Int {{ -((9223372036854775808)) }} \
         fn subnormal() -> Float {{ {subnormal} }} \
         fn rounded_zero() -> Float {{ {rounded_zero} }} \
         fn runtime_zero() -> Int {{ 1 / 0 }}"
    );
    check(&valid).expect("minimum Int, finite tiny Float, and runtime division are valid");

    for source in [
        "fn bad() -> Int { 9223372036854775808 }",
        "fn bad() -> Int { 9999999999999999999999999999999999999999999999 }",
        "fn bad() -> Float { 999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999.0 }",
    ] {
        assert_eq!(error(source).kind, CheckDiagnosticKind::LiteralOutOfRange);
    }
}

#[test]
fn unsupported_carriers_are_not_accepted_by_spelling_or_call_shape() {
    let cases = [
        "fn missing(value: Int) { value }",
        "fn generic<T>(value: T) -> T { value }",
        "fn mutable() -> Int { let    mut value = 1; value }",
        "fn destructure() -> Int { let (value, _) = (1, 2); value }",
        "fn target() -> Int { 1 } fn shadow() -> Int { let target = 1; target() }",
        "fn target() -> Int { 1 } fn shadow(target: Int) -> Int { target() }",
        "fn target() -> Int { 1 } fn nested() -> Int { target()(1) }",
        "fn bad(value: &mut Int) -> Int { value }",
        "fn bad(value: scoped &Int) -> Int { value }",
        "fn bad() -> Int with {fs} { 1 }",
        "requires {fs}; fn bad() -> Int { 1 }",
        "fn bad() -> Str { \"text\" }",
        "fn bad(value: List<Int>) -> Int { 1 }",
        "const VALUE: Int = 1; fn good() -> Int { 1 }",
    ];
    for source in cases {
        assert_eq!(
            error(source).kind,
            CheckDiagnosticKind::Unsupported,
            "source: {source}"
        );
    }
}

#[test]
fn alias_cycles_and_wrong_arity_are_type_errors_while_tuple_comparison_is_unsupported() {
    for source in [
        "type A = B; type B = A; fn value() -> A { 1 }",
        "fn value() -> Int<Bool> { 1 }",
    ] {
        assert_eq!(error(source).kind, CheckDiagnosticKind::TypeMismatch);
    }
    assert_eq!(
        error("fn value() -> Bool { (1, 2) == (1, 2) }").kind,
        CheckDiagnosticKind::Unsupported
    );
}

#[test]
fn public_parameter_mode_can_only_be_selected_by_source_or_contract() {
    assert_eq!(
        error("pub fn expose(value: Int) -> Int { value }").kind,
        CheckDiagnosticKind::Unsupported
    );
    check("pub fn expose(value: &Int) -> Int { value }")
        .expect("an explicit public Borrow mode is supported");

    let sources = project("pub fn expose(value: &Int) -> Int { value }");
    let record = format!(
        r#"{{"target":{},"set":{{"parameter_modes":[{{"parameter":{{"tag":"position","index":0}},"mode":{{"tag":"fixed","mode":"move"}}}}]}}}}"#,
        function_target("expose")
    );
    let diagnostic = check_project(
        &sources,
        &BTreeMap::from([("app".to_owned(), APP)]),
        vec![contract(&document(&record))],
    )
    .expect_err("different explicit source and contract modes are deferred");
    assert_eq!(diagnostic.kind, CheckDiagnosticKind::Unsupported);
}

#[test]
fn contracts_do_not_supply_omitted_source_type_identity() {
    let owners = BTreeMap::from([("app".to_owned(), APP)]);
    let parameter_record = format!(
        r#"{{"target":{},"set":{{"parameter_types":[{{"parameter":{{"tag":"position","index":0}},"type":{{"tag":"primitive","name":"Int"}}}}]}}}}"#,
        function_target("identity")
    );
    let diagnostic = check_project(
        &project("fn identity(value) -> Int { value }"),
        &owners,
        vec![contract(&document(&parameter_record))],
    )
    .expect_err("a contract cannot monomorphize an unannotated source parameter");
    assert_eq!(diagnostic.kind, CheckDiagnosticKind::Unsupported);
    assert!(matches!(diagnostic.primary, Some(CheckOrigin::Source(_))));

    let return_record = format!(
        r#"{{"target":{},"set":{{"return_type":{{"tag":"primitive","name":"Int"}}}}}}"#,
        function_target("identity")
    );
    let diagnostic = check_project(
        &project("fn identity(value: Int) { value }"),
        &owners,
        vec![contract(&document(&return_record))],
    )
    .expect_err("a contract cannot supply an omitted source return identity");
    assert_eq!(diagnostic.kind, CheckDiagnosticKind::Unsupported);
    assert!(matches!(diagnostic.primary, Some(CheckOrigin::Source(_))));
}

#[test]
fn contract_binding_errors_keep_document_paths_and_real_source_relations() {
    let sources = project("fn value(input: Int) -> Int { input }");
    let owners = BTreeMap::from([("app".to_owned(), APP)]);
    let unknown_target = format!(
        r#"{{"target":{},"set":{{"return_type":{{"tag":"primitive","name":"Int"}}}}}}"#,
        function_target("missing")
    );
    let diagnostic = check_project(
        &sources,
        &owners,
        vec![contract(&document(&unknown_target))],
    )
    .expect_err("unknown target must not bind by a global leaf name");
    assert_eq!(diagnostic.kind, CheckDiagnosticKind::ContractBinding);
    assert!(matches!(
        diagnostic.primary,
        Some(CheckOrigin::Contract {
            document_index: 0,
            ref json_path,
        }) if json_path == "$.records[0].target"
    ));

    let unknown_owner = document(&format!(
        r#"{{"target":{},"set":{{"return_type":{{"tag":"primitive","name":"Int"}}}}}}"#,
        function_target("value")
    ))
    .replace(r#""owner":"app""#, r#""owner":"missing""#);
    let diagnostic = check_project(&sources, &owners, vec![contract(&unknown_owner)])
        .expect_err("owner labels require an explicit reachable mapping");
    assert_eq!(diagnostic.kind, CheckDiagnosticKind::ContractBinding);
}

#[test]
fn contract_conflicts_are_not_last_wins_and_indices_never_truncate() {
    let sources = project("fn value(input: Int) -> Int { input }");
    let owners = BTreeMap::from([("app".to_owned(), APP)]);
    let first = format!(
        r#"{{"target":{},"set":{{"return_type":{{"tag":"primitive","name":"Int"}}}}}}"#,
        function_target("value")
    );
    let conflicting = format!(
        r#"{{"target":{},"set":{{"return_type":{{"tag":"primitive","name":"Bool"}}}}}}"#,
        function_target("value")
    );
    let diagnostic = check_project(
        &sources,
        &owners,
        vec![contract(&document(&format!("{first},{conflicting}")))],
    )
    .expect_err("partial records may not overwrite one another");
    assert_eq!(diagnostic.kind, CheckDiagnosticKind::ContractConflict);
    assert_eq!(diagnostic.related.len(), 1);

    let diagnostic = check_project(&sources, &owners, vec![contract(&document(&conflicting))])
        .expect_err("an explicit contract type cannot overwrite the source type");
    assert_eq!(diagnostic.kind, CheckDiagnosticKind::ContractConflict);
    assert!(matches!(
        diagnostic.related.as_slice(),
        [CheckOrigin::Source(origin)] if origin.library == APP
    ));

    let out_of_range = format!(
        r#"{{"target":{},"set":{{"parameter_types":[{{"parameter":{{"tag":"position","index":18446744073709551615}},"type":{{"tag":"primitive","name":"Int"}}}}]}}}}"#,
        function_target("value")
    );
    let diagnostic = check_project(&sources, &owners, vec![contract(&document(&out_of_range))])
        .expect_err("u64::MAX is a real wire value but not a parameter index");
    assert_eq!(diagnostic.kind, CheckDiagnosticKind::ContractBinding);
}

#[test]
fn unsupported_clause_rejects_the_entire_record_before_supported_facts_apply() {
    let sources = project("pub fn value(input: Int) -> Int { input }");
    let record = format!(
        r#"{{"target":{},"set":{{"parameter_modes":[{{"parameter":{{"tag":"position","index":0}},"mode":{{"tag":"fixed","mode":"borrow"}}}}],"parameter_escape":[{{"parameter":{{"tag":"position","index":0}},"escape":"noescape"}}]}}}}"#,
        function_target("value")
    );
    let diagnostic = check_project(
        &sources,
        &BTreeMap::from([("app".to_owned(), APP)]),
        vec![contract(&document(&record))],
    )
    .expect_err("one unsupported clause rejects its whole record");
    assert_eq!(diagnostic.kind, CheckDiagnosticKind::Unsupported);
    assert!(matches!(
        diagnostic.primary,
        Some(CheckOrigin::Contract { ref json_path, .. })
            if json_path.ends_with(".set.parameter_escape")
    ));
}

#[test]
fn checks_every_reachable_library_and_preserves_cross_library_exact_callees() {
    let sources = ProjectSources {
        entry: APP,
        core: CORE,
        libraries: with_core(BTreeMap::from([
            (
                APP,
                LibrarySources {
                    root: "use dep::answer as selected; fn main() -> Int { selected() }".to_owned(),
                    modules: BTreeMap::new(),
                    dependencies: BTreeMap::from([("dep".to_owned(), DEPENDENCY)]),
                },
            ),
            (
                DEPENDENCY,
                LibrarySources {
                    root: "pub fn answer() -> Int { 42 }".to_owned(),
                    modules: BTreeMap::new(),
                    dependencies: BTreeMap::new(),
                },
            ),
        ])),
    };
    check_project(&sources, &BTreeMap::new(), Vec::new())
        .expect("a public re-export/import call retains the dependency function identity");

    let mut unsupported = sources;
    unsupported
        .libraries
        .get_mut(&DEPENDENCY)
        .expect("dependency")
        .root
        .push_str(" const HIDDEN: Int = 1;");
    assert_eq!(
        check_project(&unsupported, &BTreeMap::new(), Vec::new())
            .expect_err("reachable dependency declarations cannot be skipped")
            .kind,
        CheckDiagnosticKind::Unsupported
    );
}

#[test]
fn checker_does_not_open_unreachable_file_source_bodies() {
    let hidden = FileModulePath::new(["hidden"]).expect("file module key");
    let sources = ProjectSources {
        entry: APP,
        core: CORE,
        libraries: with_core(BTreeMap::from([(
            APP,
            LibrarySources {
                root: "fn main() -> Int { 1 }".to_owned(),
                modules: BTreeMap::from([(hidden, "@not_frontend_input".to_owned())]),
                dependencies: BTreeMap::new(),
            },
        )])),
    };
    check_project(&sources, &BTreeMap::new(), Vec::new())
        .expect("an unreachable file source is not opened by the Checker");
}

#[test]
fn contracts_cannot_target_foreign_reexports_and_dependency_aliases_are_exact() {
    let sources = ProjectSources {
        entry: APP,
        core: CORE,
        libraries: with_core(BTreeMap::from([
            (
                APP,
                LibrarySources {
                    root: "pub use dep::foreign as facade; fn local() -> Int { facade() }"
                        .to_owned(),
                    modules: BTreeMap::new(),
                    dependencies: BTreeMap::from([("dep".to_owned(), DEPENDENCY)]),
                },
            ),
            (
                DEPENDENCY,
                LibrarySources {
                    root: "pub fn foreign() -> Int { 1 }".to_owned(),
                    modules: BTreeMap::new(),
                    dependencies: BTreeMap::new(),
                },
            ),
            (
                OTHER,
                LibrarySources {
                    root: "pub fn foreign() -> Int { 2 }".to_owned(),
                    modules: BTreeMap::new(),
                    dependencies: BTreeMap::new(),
                },
            ),
        ])),
    };
    let record = format!(
        r#"{{"target":{},"set":{{"return_type":{{"tag":"primitive","name":"Int"}}}}}}"#,
        function_target("facade")
    );
    let diagnostic = check_project(
        &sources,
        &BTreeMap::from([("app".to_owned(), APP)]),
        vec![contract(&document(&record))],
    )
    .expect_err("a local facade cannot transfer ownership of a foreign function contract");
    assert_eq!(diagnostic.kind, CheckDiagnosticKind::ContractBinding);
    assert!(diagnostic.related.iter().any(|origin| matches!(
        origin,
        CheckOrigin::Source(origin) if origin.library == DEPENDENCY
    )));
}

#[test]
fn exact_core_roles_are_exempt_but_extra_core_declarations_are_checked() {
    let mut sources = project("fn main() -> Int { 1 }");
    sources
        .libraries
        .get_mut(&CORE)
        .expect("core")
        .root
        .push_str("\nfn supported_extra() -> Int { 1 }\n");
    check_project(&sources, &BTreeMap::new(), Vec::new())
        .expect("an extra supported core function is checked normally");
    sources
        .libraries
        .get_mut(&CORE)
        .expect("core")
        .root
        .push_str("\nconst EXTRA: Int = 1;\n");
    assert_eq!(
        check_project(&sources, &BTreeMap::new(), Vec::new())
            .expect_err("core is not exempt as a whole library")
            .kind,
        CheckDiagnosticKind::Unsupported
    );
}

#[test]
fn contract_paths_reach_private_inline_and_file_module_functions_without_a_query_api() {
    let file = FileModulePath::new(["file_api"]).expect("file module key");
    let sources = ProjectSources {
        entry: APP,
        core: CORE,
        libraries: with_core(BTreeMap::from([(
            APP,
            LibrarySources {
                root: "use file_api; mod inline_api { fn hidden(value: Int) -> Int { value } }"
                    .to_owned(),
                modules: BTreeMap::from([(
                    file,
                    "fn hidden(value: Int) -> Int { value }".to_owned(),
                )]),
                dependencies: BTreeMap::new(),
            },
        )])),
    };
    let record = |path: &[&str]| {
        format!(
            r#"{{"target":{},"set":{{"parameter_modes":[{{"parameter":{{"tag":"position","index":0}},"mode":{{"tag":"fixed","mode":"move"}}}}]}}}}"#,
            function_path_target(path)
        )
    };
    let records = format!(
        "{},{}",
        record(&["inline_api", "hidden"]),
        record(&["file_api", "hidden"])
    );
    check_project(
        &sources,
        &BTreeMap::from([("app".to_owned(), APP)]),
        vec![contract(&document(&records))],
    )
    .expect("owner-local contract paths may name private functions in logical modules");
}

#[test]
fn dependency_contract_types_use_the_declared_direct_edge_and_public_binding() {
    let sources = ProjectSources {
        entry: APP,
        core: CORE,
        libraries: with_core(BTreeMap::from([
            (
                APP,
                LibrarySources {
                    root: "use dep::Number; pub fn expose(value: &Number) -> Number { value }"
                        .to_owned(),
                    modules: BTreeMap::new(),
                    dependencies: BTreeMap::from([
                        ("dep".to_owned(), DEPENDENCY),
                        ("other".to_owned(), OTHER),
                    ]),
                },
            ),
            (
                DEPENDENCY,
                LibrarySources {
                    root: "pub type Number = Int;".to_owned(),
                    modules: BTreeMap::new(),
                    dependencies: BTreeMap::new(),
                },
            ),
            (
                OTHER,
                LibrarySources {
                    root: "pub type Number = Bool;".to_owned(),
                    modules: BTreeMap::new(),
                    dependencies: BTreeMap::new(),
                },
            ),
        ])),
    };
    let dependency_number = r#"{"tag":"nominal","declaration":{"library":{"tag":"dependency","alias":"dep"},"path":["Number"],"kind":"type_alias"},"arguments":[]}"#;
    let record = format!(
        r#"{{"target":{},"set":{{"parameter_types":[{{"parameter":{{"tag":"position","index":0}},"type":{dependency_number}}}],"return_type":{dependency_number}}}}}"#,
        function_target("expose")
    );
    check_project(
        &sources,
        &BTreeMap::from([("app".to_owned(), APP)]),
        vec![contract(&document(&record))],
    )
    .expect("the explicit dep edge selects Int despite another library's same leaf name");

    let self_with_dependency_segment = dependency_number
        .replace(
            r#""library":{"tag":"dependency","alias":"dep"}"#,
            r#""library":{"tag":"self"}"#,
        )
        .replace(r#""path":["Number"]"#, r#""path":["dep","Number"]"#);
    let wrong_library_record = format!(
        r#"{{"target":{},"set":{{"return_type":{self_with_dependency_segment}}}}}"#,
        function_target("expose")
    );
    assert_eq!(
        check_project(
            &sources,
            &BTreeMap::from([("app".to_owned(), APP)]),
            vec![contract(&document(&wrong_library_record))],
        )
        .expect_err("LibraryRef self cannot replace the explicit dependency selector")
        .kind,
        CheckDiagnosticKind::ContractBinding
    );

    let missing_edge = document(&record).replace(r#""alias":"dep""#, r#""alias":"missing""#);
    assert_eq!(
        check_project(
            &sources,
            &BTreeMap::from([("app".to_owned(), APP)]),
            vec![contract(&missing_edge)],
        )
        .expect_err("contract dependency labels do not use a global leaf search")
        .kind,
        CheckDiagnosticKind::ContractBinding
    );

    let mut private_sources = sources.clone();
    private_sources
        .libraries
        .get_mut(&DEPENDENCY)
        .expect("dependency")
        .root
        .push_str(" type Hidden = Int;");
    let private_type = r#"{"tag":"nominal","declaration":{"library":{"tag":"dependency","alias":"dep"},"path":["Hidden"],"kind":"type_alias"},"arguments":[]}"#;
    let private_record = format!(
        r#"{{"target":{},"set":{{"return_type":{private_type}}}}}"#,
        function_target("expose")
    );
    assert_eq!(
        check_project(
            &private_sources,
            &BTreeMap::from([("app".to_owned(), APP)]),
            vec![contract(&document(&private_record))],
        )
        .expect_err("dependency contract paths cannot reach private declarations")
        .kind,
        CheckDiagnosticKind::ContractBinding
    );
}

#[test]
fn project_failures_remain_structured_inside_checker_diagnostics() {
    let missing_core = LibraryId(99);
    let sources = ProjectSources {
        entry: APP,
        core: missing_core,
        libraries: BTreeMap::from([(
            APP,
            LibrarySources {
                root: "fn value() -> Int { 1 }".to_owned(),
                modules: BTreeMap::new(),
                dependencies: BTreeMap::new(),
            },
        )]),
    };
    let diagnostic = check_project(&sources, &BTreeMap::new(), Vec::new())
        .expect_err("project gates precede checker semantics");
    assert!(matches!(
        diagnostic.kind,
        CheckDiagnosticKind::Project(boxed)
            if *boxed == ProjectDiagnosticKind::MissingCoreLibrary { core: missing_core }
    ));
    assert!(diagnostic.primary.is_none());
}

#[test]
fn header_diagnostics_use_logical_source_order_even_when_alias_expansion_reaches_later_text() {
    let source = "fn early(value: Bad) -> Int { 1 } \
                  const MIDDLE: Int = 1; \
                  type Bad = Str;";
    let diagnostic = error(source);
    assert_eq!(diagnostic.kind, CheckDiagnosticKind::Unsupported);
    let Some(CheckOrigin::Source(origin)) = diagnostic.primary else {
        panic!("header diagnostic should retain a source origin")
    };
    assert_eq!(
        &source[origin.span.start..origin.span.end],
        "const MIDDLE: Int = 1;"
    );
}

#[test]
fn source_shapes_core_constructors_methods_and_non_function_declarations_are_unsupported() {
    let cases = [
        "fn apply(callback: fn(Int) -> Int) -> Int { 1 }",
        "fn bad(value: Int) -> Bool { value.eq(value) }",
        "use vorton_core::Option::Some; fn bad() -> Int { Some(1); 1 }",
        "struct Value {} fn good() -> Int { 1 }",
        "trait Value {} fn good() -> Int { 1 }",
        "extern fn host() -> Int with {}; fn good() -> Int { 1 }",
        "impl Int { fn value(self: &Self) -> Int { 1 } } fn good() -> Int { 1 }",
        "fn bad() -> Int { [1, 2]; 1 }",
    ];
    for source in cases {
        assert_eq!(
            error(source).kind,
            CheckDiagnosticKind::Unsupported,
            "source: {source}"
        );
    }
}

#[test]
fn unsupported_contract_shape_wins_atomically_even_beside_an_unbindable_supported_field() {
    let sources = project("fn value(input: Int) -> Int { input }");
    let record = format!(
        r#"{{"target":{},"set":{{"parameter_types":[{{"parameter":{{"tag":"position","index":99}},"type":{{"tag":"primitive","name":"Int"}}}}]}},"check":{{"visibility":"private"}}}}"#,
        function_target("value")
    );
    let diagnostic = check_project(
        &sources,
        &BTreeMap::from([("app".to_owned(), APP)]),
        vec![contract(&document(&record))],
    )
    .expect_err("the whole record is unsupported before supported facts can be applied");
    assert_eq!(diagnostic.kind, CheckDiagnosticKind::Unsupported);
    assert!(matches!(
        diagnostic.primary,
        Some(CheckOrigin::Contract { ref json_path, .. })
            if json_path.ends_with(".check.visibility")
    ));
}

#[test]
fn each_selected_contract_family_outside_the_subset_is_explicitly_unsupported() {
    let sources = project("fn value(input: Int) -> Int { input }");
    let target = function_target("value");
    let records = [
        format!(
            r#"{{"target":{target},"set":{{"parameter_types":[{{"parameter":{{"tag":"receiver"}},"type":{{"tag":"primitive","name":"Int"}}}}]}}}}"#
        ),
        format!(
            r#"{{"target":{target},"set":{{"parameter_modes":[{{"parameter":{{"tag":"position","index":0}},"mode":{{"tag":"fixed","mode":"mut"}}}}]}}}}"#
        ),
        format!(
            r#"{{"target":{target},"set":{{"return_type":{{"tag":"primitive","name":"Str"}}}}}}"#
        ),
        format!(r#"{{"target":{target},"set":{{"effect_upper":[{{"tag":"mut"}}]}}}}"#),
        format!(
            r#"{{"target":{target},"set":{{"generic_requirements":[{{"tag":"trait","subject":{{"tag":"primitive","name":"Int"}},"bound":{{"trait":{{"library":{{"tag":"self"}},"path":["Missing"],"kind":"trait"}},"arguments":[],"associated_bindings":[]}}}}]}}}}"#
        ),
        format!(
            r#"{{"target":{target},"type_parameters":["T"],"set":{{"return_type":{{"tag":"primitive","name":"Int"}}}}}}"#
        ),
        r#"{"target":{"tag":"declaration","declaration":{"library":{"tag":"self"},"path":["value"],"kind":"struct"}},"set":{"return_type":{"tag":"primitive","name":"Int"}}}"#.to_owned(),
    ];
    for record in records {
        let diagnostic = check_project(
            &sources,
            &BTreeMap::from([("app".to_owned(), APP)]),
            vec![contract(&document(&record))],
        )
        .expect_err("selected clause or target is outside the initial subset");
        assert_eq!(
            diagnostic.kind,
            CheckDiagnosticKind::Unsupported,
            "record: {record}"
        );
    }
}

#[test]
fn short_circuit_rhs_divergence_does_not_make_the_whole_boolean_expression_diverge() {
    for operator in ["&&", "||"] {
        let diagnostic = error(&format!(
            "fn bottom() -> Never {{ bottom() }} \
             fn bad(flag: Bool) -> Never {{ flag {operator} bottom() }}"
        ));
        assert_eq!(diagnostic.kind, CheckDiagnosticKind::ReturnMismatch);

        check(&format!(
            "fn bottom() -> Never {{ bottom() }} \
             fn valid() -> Never {{ bottom() {operator} true }}"
        ))
        .expect("a divergent left operand still makes the short-circuit expression diverge");
    }
}

#[test]
fn nested_never_widens_inside_tuple_types() {
    check(
        "fn accept(value: (Bool, Int)) -> (Bool, Int) { value } \
         fn widen(value: (Never, Int)) -> (Bool, Int) { \
             let widened: (Bool, Int) = value; \
             accept(value) \
         } \
         fn choose(flag: Bool, value: (Never, Int)) -> (Bool, Int) { \
             if flag { value } else { (true, 1) } \
         }",
    )
    .expect("Never widens recursively for returns, annotations, calls, and branch joins");
}

#[test]
fn module_function_receiver_is_stably_unsupported() {
    assert_eq!(
        error("fn bad(self: &Int) -> Int { self }").kind,
        CheckDiagnosticKind::Unsupported
    );
}

#[test]
fn public_signature_cannot_expose_a_private_type_alias() {
    for source in [
        "type Hidden = Int; pub fn expose(value: &Hidden) -> Hidden { value }",
        "type Hidden = Int; pub type Surface = Hidden; \
         pub fn expose(value: &Surface) -> Surface { value }",
    ] {
        assert_eq!(error(source).kind, CheckDiagnosticKind::TypeMismatch);
    }
}

#[test]
fn supported_deep_non_generic_alias_chain_uses_bounded_host_stack() {
    let mut source = String::new();
    for index in 0..4_096 {
        writeln!(&mut source, "type A{index} = A{};", index + 1)
            .expect("writing to a String cannot fail");
    }
    source.push_str("type A4096 = Int; fn value() -> A0 { 1 }");

    check(&source).expect("a finite acyclic supported alias chain must terminate normally");
}

#[test]
fn pub_function_inside_private_module_uses_private_mode_default() {
    check(
        "mod hidden { pub fn helper(value: Int) -> Int { value } } \
         fn main() -> Int { 1 }",
    )
    .expect("a declaration pub bit behind a private module is not an external input surface");
}

#[test]
fn unexported_internal_signature_can_use_its_private_alias() {
    check(
        "mod hidden { \
             type Secret = Int; \
             pub fn helper(value: &Secret) -> Secret { value } \
         } \
         fn main() -> Int { 1 }",
    )
    .expect("an unexported internal signature does not leak its private alias");
}

#[test]
fn root_public_signature_rejects_alias_without_public_export_path() {
    let diagnostic = error(
        "use hidden::Secret; \
         mod hidden { pub type Secret = Int; } \
         pub fn expose(value: &Secret) -> Secret { value }",
    );
    assert_eq!(diagnostic.kind, CheckDiagnosticKind::TypeMismatch);
}

#[test]
fn continuous_public_modules_and_reexports_enter_the_actual_external_surface() {
    let diagnostic = error(
        "pub mod visible { pub fn helper(value: Int) -> Int { value } } \
         fn main() -> Int { 1 }",
    );
    assert_eq!(diagnostic.kind, CheckDiagnosticKind::Unsupported);

    check(
        "pub mod visible { pub type Secret = Int; } \
         pub fn expose(value: &visible::Secret) -> visible::Secret { value }",
    )
    .expect("a continuous public module path exports the alias identity");

    let diagnostic = error(
        "pub use hidden::helper; \
         mod hidden { pub fn helper(value: Int) -> Int { value } } \
         fn main() -> Int { 1 }",
    );
    assert_eq!(diagnostic.kind, CheckDiagnosticKind::Unsupported);

    check(
        "pub use hidden::Secret; \
         mod hidden { pub type Secret = Int; } \
         pub fn expose(value: &Secret) -> Secret { value }",
    )
    .expect("a real public alias export may appear in an actually public signature");
}

#[test]
fn contract_can_use_supported_alias_not_referenced_by_source_types() {
    let sources = project("type Alias = Int; fn value(input: &Int) -> Int { input }");
    let alias = r#"{"tag":"nominal","declaration":{"library":{"tag":"self"},"path":["Alias"],"kind":"type_alias"},"arguments":[]}"#;
    let record = format!(
        r#"{{"target":{},"set":{{"parameter_types":[{{"parameter":{{"tag":"position","index":0}},"type":{alias}}}]}}}}"#,
        function_target("value")
    );

    check_project(
        &sources,
        &BTreeMap::from([("app".to_owned(), APP)]),
        vec![contract(&document(&record))],
    )
    .expect("a checked standalone alias is available to contract normalization");
}
