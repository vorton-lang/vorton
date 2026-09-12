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
fn contracts_accept_resolved_omissions_but_cannot_specialize_inferred_identity() {
    let owners = BTreeMap::from([("app".to_owned(), APP)]);
    let parameter_record = format!(
        r#"{{"target":{},"set":{{"parameter_types":[{{"parameter":{{"tag":"position","index":0}},"type":{{"tag":"primitive","name":"Int"}}}}]}}}}"#,
        function_target("identity")
    );
    check_project(
        &project("fn identity(value) -> Int { value }"),
        &owners,
        vec![contract(&document(&parameter_record))],
    )
    .expect("the source body already fixes the omitted parameter to Int");

    let return_record = format!(
        r#"{{"target":{},"set":{{"return_type":{{"tag":"primitive","name":"Int"}}}}}}"#,
        function_target("identity")
    );
    check_project(
        &project("fn identity(value: Int) { value }"),
        &owners,
        vec![contract(&document(&return_record))],
    )
    .expect("the source body already fixes the omitted return to Int");

    let specializing = format!(
        r#"{{"target":{},"set":{{"parameter_types":[{{"parameter":{{"tag":"position","index":0}},"type":{{"tag":"primitive","name":"Int"}}}}],"return_type":{{"tag":"primitive","name":"Int"}}}}}}"#,
        function_target("identity")
    );
    let diagnostic = check_project(
        &project("fn identity(value) { value }"),
        &owners,
        vec![contract(&document(&specializing))],
    )
    .expect_err("a contract cannot monomorphize the source-inferred identity relation");
    assert_eq!(diagnostic.kind, CheckDiagnosticKind::ContractConflict);
    assert!(matches!(
        diagnostic.primary,
        Some(CheckOrigin::Contract { .. })
    ));
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
fn source_shapes_methods_and_other_declarations_remain_unsupported() {
    let cases = [
        "fn apply(callback: fn(Int) -> Int) -> Int { 1 }",
        "fn bad(value: Int) -> Bool { value.eq(value) }",
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

    let mismatched_generics = format!(
        r#"{{"target":{target},"type_parameters":["T"],"set":{{"return_type":{{"tag":"primitive","name":"Int"}}}}}}"#
    );
    assert_eq!(
        check_project(
            &sources,
            &BTreeMap::from([("app".to_owned(), APP)]),
            vec![contract(&document(&mismatched_generics))],
        )
        .expect_err("contract generics cannot be added to a monomorphic source declaration")
        .kind,
        CheckDiagnosticKind::ContractConflict
    );

    let pair_sources = project("fn pair<T, U>(left: T, right: U) -> (T, U) { (left, right) }");
    let first = function_formal("pair", 0);
    let second = function_formal("pair", 1);
    let merged = format!(
        r#"{{"target":{},"type_parameters":["A","B"],"set":{{"parameter_types":[{{"parameter":{{"tag":"position","index":0}},"type":{first}}},{{"parameter":{{"tag":"position","index":1}},"type":{first}}}],"return_type":{{"tag":"tuple","elements":[{first},{second}]}}}}}}"#,
        function_target("pair")
    );
    assert_eq!(
        check_project(
            &pair_sources,
            &BTreeMap::from([("app".to_owned(), APP)]),
            vec![contract(&document(&merged))],
        )
        .expect_err("a contract cannot merge two distinct source formals")
        .kind,
        CheckDiagnosticKind::ContractConflict
    );
}

fn function_formal(name: &str, index: u64) -> String {
    format!(
        r#"{{"tag":"formal","formal":{{"owner":{},"binder":"declaration","kind":"type","index":{index}}}}}"#,
        function_target(name)
    )
}

#[test]
fn contracted_scc_member_cannot_acquire_an_undeclared_peer_formal() {
    for (left, parameters) in [
        ("fn left(x) { right(x) }", ""),
        (
            "fn left<S>(x) { right(x) }",
            r#", "type_parameters":["Alpha"]"#,
        ),
    ] {
        let right = "fn right<T>(x: T) -> T { left(x) }";
        let record = format!(
            r#"{{"target":{}{parameters},"set":{{"generic_requirements":[]}}}}"#,
            function_target("left")
        );
        for source in [format!("{left} {right}"), format!("{right} {left}")] {
            let diagnostic = check_project(
                &project(&source),
                &BTreeMap::from([("app".to_owned(), APP)]),
                vec![contract(&document(&record))],
            )
            .expect_err("a peer formal must correspond to a declared source/contract formal");
            assert_eq!(diagnostic.kind, CheckDiagnosticKind::ContractConflict);
            assert!(matches!(
                diagnostic.primary,
                Some(CheckOrigin::Contract { .. })
            ));
        }
    }
    let record = format!(
        r#"{{"target":{},"type_parameters":["Alpha"],"set":{{"generic_requirements":[]}}}}"#,
        function_target("left")
    );
    check_project(
        &project("fn left<S>(x: S) -> S { right(x) } fn right<T>(x: T) -> T { left(x) }"),
        &BTreeMap::from([("app".to_owned(), APP)]),
        vec![contract(&document(&record))],
    )
    .expect("an SCC-equivalent formal is valid when source and contract declare it");
}

#[test]
fn recursive_tuple_projection_waits_for_its_receiver_type() {
    for (projected, base, step) in [
        ("b(x).0", "(x, true)", "(a(x - 1), false)"),
        (
            "-(b(x).0).0",
            "((x, true), false)",
            "((a(x - 1), false), true)",
        ),
    ] {
        let a = format!("fn a(x: Int) -> Int {{ {projected} }}");
        let b = format!("fn b(x: Int) {{ if x == 0 {{ {base} }} else {{ {step} }} }}");
        for source in [format!("{a} {b}"), format!("{b} {a}")] {
            check(&source).expect("projection equations close before their numeric consumers");
        }
    }
    for (index, message) in [(1, "incompatible"), (2, "outside a 2-element tuple")] {
        let diagnostic = error(&format!(
            "fn a(x: Int) -> Int {{ b(x).{index} }} \
             fn b(x: Int) {{ if x == 0 {{ (x, true) }} else {{ (a(x - 1), false) }} }}"
        ));
        assert_eq!(diagnostic.kind, CheckDiagnosticKind::TypeMismatch);
        assert!(diagnostic.message.contains(message));
        let Some(CheckOrigin::Source(origin)) = diagnostic.primary else {
            panic!("projection diagnostics retain the index origin")
        };
        assert_eq!((origin.span.start, origin.span.end), (27, 28));
    }
    assert_eq!(
        error("fn unknown(x) { x.0 }").kind,
        CheckDiagnosticKind::Unsupported
    );
}

#[test]
fn unit_if_discards_its_then_value_in_every_outer_context() {
    for body in [
        "if flag { x }",
        "let result = if flag { x };",
        "if flag { x };",
    ] {
        check(&format!("fn f<T>(flag: Bool, x: &T) -> Unit {{ {body} }}"))
            .expect("discarding a borrowed then value does not transfer ownership");
        assert_eq!(
            error(&format!(
                "fn f<T>(flag: Bool, x: move T) -> Unit {{ {body} }}"
            ))
            .kind,
            CheckDiagnosticKind::Unsupported
        );
    }
    assert_eq!(
        error("fn make<T>() -> T { make() } fn f(flag: Bool) -> Unit { if flag { make() } }").kind,
        CheckDiagnosticKind::Unsupported
    );
}

#[test]
fn nested_never_widening_preserves_generic_ownership() {
    for branches in [
        "if flag { bottom } else { pair }",
        "if flag { pair } else { bottom }",
    ] {
        assert_eq!(
            error(&format!(
                "fn f<T>(flag: Bool, pair: move (T, Int), bottom: (Never, Int)) -> (T, Int) {{ \
                 let result = {branches}; result }}"
            ))
            .kind,
            CheckDiagnosticKind::Unsupported
        );
    }
    check("fn f<T>(bottom: (Never, Int)) -> (T, Int) { let result: (T, Int) = bottom; result }")
        .expect("an annotated widening transfers only the actual result into the new owner");
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

#[test]
fn infers_internal_hm_functions_and_instantiates_each_direct_call_once() {
    check(
        "fn identity(value) { value } \
         fn take_int(value: Int) -> Int { value } \
         fn take_bool(value: Bool) -> Bool { value } \
         fn main() -> (Int, Bool) { \
             (take_int(identity(1)), take_bool(identity(true))) \
         }",
    )
    .expect("one inferred identity scheme is freshly instantiated at Int and Bool calls");

    let diagnostic = error(
        "fn impossible<T>() -> T { impossible() } \
         fn take_int(value: Int) -> Unit {} \
         fn take_bool(value: Bool) -> Unit {} \
         fn bad() -> Unit { \
             let value = impossible(); \
             take_int(value); \
             take_bool(value); \
         }",
    );
    assert_eq!(diagnostic.kind, CheckDiagnosticKind::CallMismatch);

    assert_eq!(
        error("fn specialize<T>(value: T) -> T { 1 }").kind,
        CheckDiagnosticKind::ReturnMismatch
    );
}

#[test]
fn closes_recursive_generic_groups_atomically_and_rejects_infinite_types() {
    let first_order = "fn repeat<T>(value: T, depth: Int) -> T { \
             if depth == 0 { value } else { repeat(value, depth - 1) } \
         } \
         fn left<T>(value: T, stop: Bool) -> T { \
             if stop { value } else { right(value, true) } \
         } \
         fn right<U>(value: U, stop: Bool) -> U { \
             if stop { value } else { left(value, true) } \
         } \
         fn main() -> ((Int, Bool), (Int, Bool)) { \
             ((repeat(1, 1), repeat(true, 1)), (left(1, false), right(true, false))) \
         }";
    check(first_order).expect("ordinary and mutually recursive generic groups close");
    check(&first_order.replace(
        "fn left<T>(value: T, stop: Bool) -> T { \
             if stop { value } else { right(value, true) } \
         } \
         fn right<U>(value: U, stop: Bool) -> U { \
             if stop { value } else { left(value, true) } \
         }",
        "fn right<U>(value: U, stop: Bool) -> U { \
             if stop { value } else { left(value, true) } \
         } \
         fn left<T>(value: T, stop: Bool) -> T { \
             if stop { value } else { right(value, true) } \
         }",
    ))
    .expect("declaration order does not change a recursive group result");

    check(
        "fn inferred(value, stop: Bool) { \
             if stop { value } else { declared(value, true) } \
         } \
         fn declared<T>(value: T, stop: Bool) -> T { \
             if stop { value } else { inferred(value, true) } \
         } \
         fn main() -> (Int, Bool) { \
             (inferred(1, false), inferred(true, false)) \
         }",
    )
    .expect("an inferred member re-owns the shared SCC formal in its published scheme");

    let diagnostic = error("fn grow(value) { grow((value, value)) }");
    assert_eq!(diagnostic.kind, CheckDiagnosticKind::CallMismatch);
    assert!(diagnostic.message.contains("contain itself"));

    assert_eq!(
        error("fn swap<T, U>(left: T, right: U) -> T { swap(right, left) }").kind,
        CheckDiagnosticKind::CallMismatch
    );

    assert!(check("fn good() -> Int { 1 }").is_ok());
}

#[test]
fn a_large_inferred_recursive_group_resolves_without_variable_chain_recursion() {
    let mut source = String::new();
    for index in 0..4_096 {
        writeln!(
            &mut source,
            "fn f{index}(x) {{ f{}(x) }}",
            (index + 1) % 4_096
        )
        .expect("writing to a String cannot fail");
    }
    check(&source)
        .expect("a shallow finite SCC must not exhaust the host stack through type links");
}

#[test]
fn generic_contracts_align_formals_across_source_and_partial_records() {
    let sources = project("pub fn identity<T>(value) -> T { value }");
    let formal = function_formal("identity", 0);
    let signature = format!(
        r#"{{"target":{},"type_parameters":["Renamed"],"set":{{"parameter_types":[{{"parameter":{{"tag":"position","index":0}},"type":{formal}}}],"return_type":{formal},"parameter_modes":[{{"parameter":{{"tag":"position","index":0}},"mode":{{"tag":"fixed","mode":"move"}}}}]}}}}"#,
        function_target("identity")
    );
    let empty_requirements = format!(
        r#"{{"target":{},"type_parameters":["Alpha"],"set":{{"generic_requirements":[]}}}}"#,
        function_target("identity")
    );
    check_project(
        &sources,
        &BTreeMap::from([("app".to_owned(), APP)]),
        vec![
            contract(&document(&signature)),
            contract(&document(&empty_requirements)),
        ],
    )
    .expect("alpha-renamed providers and explicit empty requirements preserve one formal relation");

    let missing_declaration = format!(
        r#"{{"target":{},"set":{{"parameter_types":[{{"parameter":{{"tag":"position","index":0}},"type":{formal}}}],"return_type":{formal}}}}}"#,
        function_target("identity")
    );
    assert_eq!(
        check_project(
            &sources,
            &BTreeMap::from([("app".to_owned(), APP)]),
            vec![contract(&document(&missing_declaration))],
        )
        .expect_err("a generic contract cannot omit its own binder declaration")
        .kind,
        CheckDiagnosticKind::ContractConflict
    );

    let specialized = signature.replace(&formal, r#"{"tag":"primitive","name":"Int"}"#);
    assert_eq!(
        check_project(
            &sources,
            &BTreeMap::from([("app".to_owned(), APP)]),
            vec![contract(&document(&specialized))],
        )
        .expect_err("a contract cannot specialize a declared source formal")
        .kind,
        CheckDiagnosticKind::ContractConflict
    );
}

#[test]
fn generic_contract_formals_require_the_exact_owner_binder_and_ordinal() {
    let sources = project(
        "fn identity<T>(value: T) -> T { value } \
         fn other<U>(value: U) -> U { value }",
    );
    let valid = function_formal("identity", 0);
    let record = |formal: &str| {
        format!(
            r#"{{"target":{},"type_parameters":["T"],"set":{{"parameter_types":[{{"parameter":{{"tag":"position","index":0}},"type":{formal}}}],"return_type":{formal}}}}}"#,
            function_target("identity")
        )
    };
    let owners = BTreeMap::from([("app".to_owned(), APP)]);

    let wrong_owner = function_formal("other", 0);
    assert_eq!(
        check_project(
            &sources,
            &owners,
            vec![contract(&document(&record(&wrong_owner)))],
        )
        .expect_err("a formal from another owner cannot prove this signature")
        .kind,
        CheckDiagnosticKind::ContractConflict
    );

    let wrong_binder = valid.replace(r#""binder":"declaration""#, r#""binder":"method""#);
    assert_eq!(
        check_project(
            &sources,
            &owners,
            vec![contract(&document(&record(&wrong_binder)))],
        )
        .expect_err("the formal binder kind is exact")
        .kind,
        CheckDiagnosticKind::ContractBinding
    );

    let wrong_ordinal = function_formal("identity", 1);
    assert_eq!(
        check_project(
            &sources,
            &owners,
            vec![contract(&document(&record(&wrong_ordinal)))],
        )
        .expect_err("the formal ordinal is exact")
        .kind,
        CheckDiagnosticKind::ContractConflict
    );
}

#[test]
fn contracts_preserve_source_inferred_formals_and_allow_optional_generic_clauses() {
    let owners = BTreeMap::from([("app".to_owned(), APP)]);
    let formal = function_formal("identity", 0);
    let tuple =
        format!(r#"{{"tag":"tuple","elements":[{formal},{{"tag":"primitive","name":"Int"}}]}}"#);
    let specializing = format!(
        r#"{{"target":{},"type_parameters":["Alpha"],"set":{{"parameter_types":[{{"parameter":{{"tag":"position","index":0}},"type":{tuple}}}],"return_type":{tuple}}}}}"#,
        function_target("identity")
    );
    assert_eq!(
        check_project(
            &project("fn identity<T>(value) { value }"),
            &owners,
            vec![contract(&document(&specializing))],
        )
        .expect_err("an unused source formal cannot hide a new tuple specialization")
        .kind,
        CheckDiagnosticKind::ContractConflict
    );

    let optional = format!(
        r#"{{"target":{},"type_parameters":["Alpha"],"set":{{"generic_requirements":[]}}}}"#,
        function_target("identity")
    );
    check_project(
        &project("fn identity<T>(value: move T) -> T { value }"),
        &owners,
        vec![contract(&document(&optional))],
    )
    .expect("a generic contract may select only its explicit empty requirements");

    let left_formal = function_formal("left", 0);
    let left_tuple = format!(
        r#"{{"tag":"tuple","elements":[{left_formal},{{"tag":"primitive","name":"Int"}}]}}"#
    );
    let scc_contract = format!(
        r#"{{"target":{},"type_parameters":["Alpha"],"set":{{"parameter_types":[{{"parameter":{{"tag":"position","index":0}},"type":{left_tuple}}}],"return_type":{left_tuple}}}}}"#,
        function_target("left")
    );
    assert_eq!(
        check_project(
            &project(
                "fn left<T>(value) { right(value) } \
                 fn right<U>(value) { left(value) }",
            ),
            &owners,
            vec![contract(&document(&scc_contract))],
        )
        .expect_err("a contract cannot specialize a source-inferred SCC relation")
        .kind,
        CheckDiagnosticKind::ContractConflict
    );

    let merging_peer = format!(
        r#"{{"target":{},"type_parameters":["Alpha"],"set":{{"parameter_types":[{{"parameter":{{"tag":"position","index":0}},"type":{left_formal}}}],"return_type":{left_formal}}}}}"#,
        function_target("left")
    );
    assert_eq!(
        check_project(
            &project(
                "fn left<T>(value) { right(value) } \
                 fn right<U>(value: U) -> U { left(value) }",
            ),
            &owners,
            vec![contract(&document(&merging_peer))],
        )
        .expect_err("a contract cannot merge an unused local formal with a peer formal")
        .kind,
        CheckDiagnosticKind::ContractConflict
    );
}

#[test]
fn defers_numeric_obligations_until_the_whole_recursive_group_is_constrained() {
    for source in [
        "fn negate(value) -> Int { -value }",
        "fn negate(value) -> Int { let result = -value; let exact: Int = value; result }",
        "fn left(x, y) -> Int { if true { x + y } else { right(x, y) } } \
         fn right(x: Int, y: Int) -> Int { left(x, y) }",
        "fn right(x: Int, y: Int) -> Int { left(x, y) } \
         fn left(x, y) -> Int { if true { x + y } else { right(x, y) } }",
        "fn equal(x, y) -> Bool { if true { x == y } else { exact(x, y) } } \
         fn exact(x: Int, y: Int) -> Bool { equal(x, y) }",
    ] {
        check(source).expect("later body or SCC constraints select the concrete numeric type");
    }

    assert_eq!(
        error("fn negate<T>(value: T) -> T { -value }").kind,
        CheckDiagnosticKind::Unsupported
    );
    assert_eq!(
        error("fn equal<T>(value: T) -> Bool { value == value }").kind,
        CheckDiagnosticKind::Unsupported
    );
}

#[test]
fn early_return_rejects_generic_temporaries_from_partially_evaluated_expressions() {
    for source in [
        "fn take<T>(value: move T, count: Int) -> T { value } \
         fn bad<T>(value: move T) -> Int { \
             take(value, { return 0; }); \
             0 \
         }",
        "fn bad<T>(value: move T) -> Int { \
             let pair = (value, { return 0; }); \
             0 \
         }",
    ] {
        let diagnostic = error(source);
        assert_eq!(diagnostic.kind, CheckDiagnosticKind::Unsupported);
        assert!(diagnostic.message.contains("temporary"));
    }

    check("fn good<T>(value: move T) -> T { return value; }")
        .expect("a completed return transfers the only generic owner");
}

#[test]
fn tracks_whole_generic_owners_across_moves_aliases_branches_and_cleanup() {
    check(
        "fn branch<T>(flag: Bool, value: T) -> T { \
             if flag { value } else { value } \
         } \
         fn relay<T>(value: T) -> T { let next = value; next } \
         fn bundle<T, U>(left: T, right: U) -> (T, U) { (left, right) } \
         fn copy_twice(value: move Int) -> (Int, Int) { (value, value) } \
         fn main() -> (Int, Bool) { (branch(true, 1), branch(false, true)) }",
    )
    .expect(
        "each normal branch transfers its generic owner once and concrete Copy remains reusable",
    );

    let cases = [
        (
            "fn borrowed<T>(value: &T) -> T { value }",
            CheckDiagnosticKind::Unsupported,
        ),
        (
            "fn twice<T>(value: move T) -> (T, T) { (value, value) }",
            CheckDiagnosticKind::Unsupported,
        ),
        (
            "fn alias<T>(value: move T) -> (T, T) { let next = value; (value, next) }",
            CheckDiagnosticKind::Unsupported,
        ),
        (
            "fn discard<T>(value: move T) -> Unit with {} {}",
            CheckDiagnosticKind::Unsupported,
        ),
        (
            "fn choose<T>(left: move T, right: move T) -> T { left }",
            CheckDiagnosticKind::Unsupported,
        ),
        (
            "fn early<T>(flag: Bool, left: move T, right: move T) -> T { \
                 if flag { return left; } \
                 right \
             }",
            CheckDiagnosticKind::Unsupported,
        ),
        (
            "fn first<T>(pair: move (T, Int)) -> T { pair.0 }",
            CheckDiagnosticKind::Unsupported,
        ),
    ];
    for (source, expected) in cases {
        assert_eq!(error(source).kind, expected, "source: {source}");
    }
}

#[test]
fn nominal_actuals_constructions_copy_fields_and_borrow_consumers_check_together() {
    check(
        r#"
use vorton_core::Option::Some;
struct Box<T> { value: T }
struct Point { x: Int, y: Int }
struct Empty<T> {}
enum Choice<T> { Empty, Pos(T), Named { count: Int, value: T } }
type IntBox = Box<Int>;
fn wrap<T>(value: T) -> Box<T> { Box { value } }
fn forward<T>(value: Box<T>) -> Box<T> { let next = value; next }
fn borrow<T>(value: &T) {}
fn borrow_field<T>(value: &Box<T>) { borrow(value.value); borrow(value.value); }
fn read(value: &Point) -> Int { value.x + value.x + value.y }
fn integer() -> Int { let value: IntBox = forward(wrap(1)); value.value }
fn boolean() -> Bool { let value = forward(wrap(true)); value.value }
fn point() -> Point { Point { y: 2, x: 1 } }
fn empty<T>() -> Empty<T> { Empty {} }
fn unused<T>(value: move Empty<T>) {}
fn unit<T>() -> Choice<T> { Choice::Empty }
fn positional<T>(value: T) -> Choice<T> { Choice::Pos(value) }
fn named<T>(value: T) -> Choice<T> { Choice::Named { value, count: 1 } }
fn option<T>(value: T) -> Option<T> { Option::Some(value) }
fn ordering() -> Ordering { Ordering::Less }
fn pure<T>() {
    let empty: Option<T> = Option::None;
    let next = empty;
    let pair = (Point { x: 1, y: 2 }, true);
    let phantom: Empty<T> = Empty {};
    Choice::Pos(1);
    Choice::Named { value: true, count: 2 };
}
fn imported() -> Option<Int> { Some(1) }
"#,
    )
    .expect("nominal owners, actuals, constructors and real core roles check together");
}

#[test]
fn finite_repeated_nominal_owners_clean_up_without_accepting_recursive_payloads() {
    for source in [
        "struct Box<T> { value: T } fn drop_box(value: move Box<Box<Int>>) {}",
        "struct Box<T> { value: T } fn wrap<T>(value: T) -> Box<T> { Box { value } } fn drop_call() { wrap(wrap(1)); }",
    ] {
        check(source).expect("finite nominal nesting contains only pure actual members");
    }
    for source in [
        "struct Box<T> { value: T } fn drop_box<T>(value: move Box<Box<T>>) {}",
        "struct Grow<T> { next: Grow<(T, T)> } fn drop_growing(value: move Grow<Int>) {}",
        "struct Box<T> { value: T } struct Recursive { next: Box<Recursive> } fn drop_recursive(value: move Recursive) {}",
    ] {
        assert_eq!(
            error(source).kind,
            CheckDiagnosticKind::Unsupported,
            "{source}"
        );
    }
}

#[test]
fn nominal_identity_arity_members_and_payload_types_are_checked() {
    for source in [
        "struct A { x: Int } struct B { x: Int } fn bad(value: A) -> B { value }",
        "struct Box<T> { value: T } fn bad(value: Box<Int>) -> Box<Bool> { value }",
        "struct Box<T> { value: T } fn bad(value: Box<Int, Bool>) {}",
        "struct Point { x: Int, y: Int } fn bad() -> Point { Point { x: 1 } }",
        "struct Point { x: Int } fn bad() -> Point { Point { x: true } }",
        "struct Point { x: Int } fn bad() -> Point { Point { x: 1, x: 2 } }",
        "struct Point { x: Int } fn bad(value: &Point) -> Bool { value.x }",
        "enum E { V(Int, Bool) } fn bad() -> E { E::V(1) }",
        "enum E { V { x: Int } } fn bad() -> E { E::V { x: true } }",
    ] {
        let diagnostic = error(source);
        assert!(
            matches!(
                diagnostic.kind,
                CheckDiagnosticKind::TypeMismatch
                    | CheckDiagnosticKind::ReturnMismatch
                    | CheckDiagnosticKind::CallMismatch
            ),
            "{source}: {diagnostic:?}"
        );
        assert!(matches!(diagnostic.primary, Some(CheckOrigin::Source(_))));
    }
    for source in [
        "struct Point { x: Int } fn bad() { Point { extra: 1 }; }",
        "enum E { V } fn bad() { E::Missing; }",
        "struct Point { x: Int } fn bad(value: &Point) { value.missing; }",
    ] {
        error(source);
    }
}

#[test]
fn nominal_whole_moves_do_not_grant_copy_or_field_ownership() {
    check("struct Box<T> { value: T } fn choose<T>(flag: Bool, value: Box<T>) -> Box<T> { if flag { value } else { value } }")
        .expect("mutually exclusive whole moves remain legal");
    for source in [
        "struct Empty {} fn bad(value: Empty) -> (Empty, Empty) { (value, value) }",
        "struct Point { x: Int } fn bad(value: Point) -> Point { let next = value; value.x; next }",
        "struct Box<T> { value: T } fn bad<T>(value: &Box<T>) -> Box<T> { value }",
        "struct Box<T> { value: T } fn bad<T>(value: &Box<T>) -> T { value.value }",
        "struct Box<T> { value: T } fn bad<T>(value: Box<T>) -> T { value.value }",
        "struct Box<T> { value: T } fn take<T>(value: T) -> T { value } fn bad<T>(value: &Box<T>) -> T { take(value.value) }",
        "struct Box<T> { value: T } fn bad<T>(value: &Box<T>) { let owned = value.value; }",
        "struct Box<T> { value: T } fn bad<T>(value: move Box<T>) {}",
        "struct Box<T> { value: T } fn bad<T>(value: T) { let owner = Box { value }; }",
    ] {
        assert_eq!(
            error(source).kind,
            CheckDiagnosticKind::Unsupported,
            "{source}"
        );
    }
}

#[test]
fn nominal_construction_preserves_source_order_and_partial_temporary_cleanup() {
    for construction in [
        "Pair { first: value, last: { return; } }",
        "Choice::Named { first: value, last: { return; } }",
        "Choice::Pos(value, { return; })",
    ] {
        let source = format!(
            "struct Pair<T> {{ last: Unit, first: T }} enum Choice<T> {{ Named {{ last: Unit, first: T }}, Pos(T, Unit) }} fn bad<T>(value: T) {{ let pending = {construction}; }}"
        );
        let diagnostic = error(&source);
        assert_eq!(diagnostic.kind, CheckDiagnosticKind::Unsupported);
        assert!(diagnostic.message.contains("temporary"), "{diagnostic:?}");
    }
    check(r#"
struct Pair<T> { first: T, last: Unit }
fn early<T>(value: T) -> T {
    let pending = Pair { last: { return value; }, first: value };
    early(value)
}
fn pure_temporary() { let pending = Pair { first: 1, last: { return; } }; }
"#).expect("actual source order transfers the generic owner before unreachable later fields; pure temporaries may clean up");
}

#[test]
fn recursive_nominal_edges_and_nominal_function_groups_close_without_unfolding() {
    let declarations =
        "struct Node<T> { value: T, next: Self } struct Grow<T> { next: Grow<(T, T)> }";
    let first = "fn left<T>(value: Node<T>) -> Node<T> { right(value) }";
    let second =
        "fn right<T>(value: Node<T>) -> Node<T> { if true { left(value) } else { value } }";
    for functions in [format!("{first} {second}"), format!("{second} {first}")] {
        check(&format!("{declarations} {functions} fn borrow<T>(value: &T) {{}} fn inspect<T>(value: &Grow<T>) {{ borrow(value.next); }}"))
            .expect("recursive nominal edges remain finite and SCC declaration order does not change checking");
    }
    assert_eq!(
        error("struct Box<T> { value: T } fn bad(value) { bad(Box { value }) }").kind,
        CheckDiagnosticKind::CallMismatch
    );
    check("struct Box<T> { value: T } fn first(value) { second(value).value } fn second(value: Box<Int>) -> Box<Int> { if true { Box { value: first(value) } } else { value } }")
        .expect("field selection waits for the same SCC constraints and construction fields contribute call edges");
}

#[test]
fn nominal_visibility_distinguishes_public_surface_from_private_representation() {
    check("struct Hidden {} pub struct Wrapper { inner: Hidden } pub fn make() -> Wrapper { Wrapper { inner: Hidden {} } }")
        .expect("public values may retain private representation fields");
    for source in [
        "struct Hidden {} pub fn expose(value: &Hidden) {}",
        "struct Hidden {} pub fn expose() -> Hidden { Hidden {} }",
        "struct Hidden {} pub fn expose() { Hidden {} }",
        "struct Hidden {} pub struct Wrapper { pub inner: Hidden }",
        "struct Hidden {} pub enum Wrapper { Inner(Hidden) }",
        "struct Hidden {} pub enum Wrapper { Inner { value: Hidden } }",
        "struct Hidden {} pub struct Box<T> { pub value: T } pub fn expose(value: &Box<Hidden>) {}",
        "mod model { pub struct Point { x: Int } } fn bad(value: &model::Point) -> Int { value.x }",
    ] {
        assert_eq!(
            error(source).kind,
            CheckDiagnosticKind::TypeMismatch,
            "{source}"
        );
    }
    error("mod model { pub struct Point { x: Int } } fn bad() { model::Point { x: 1 }; }");
}

#[test]
fn nominal_contract_actuals_match_alpha_formals_and_reject_kind_arity_and_conflicts() {
    let sources =
        project("struct Box<T> { value: T } fn forward<T>(value: move Box<T>) -> Box<T> { value }");
    let formal = function_formal("forward", 0);
    let nominal = format!(
        r#"{{"tag":"nominal","declaration":{{"library":{{"tag":"self"}},"path":["Box"],"kind":"struct"}},"arguments":[{formal}]}}"#
    );
    let record = |ty: &str| {
        format!(
            r#"{{"target":{},"type_parameters":["Alpha"],"set":{{"parameter_types":[{{"parameter":{{"tag":"position","index":0}},"type":{ty}}}],"return_type":{ty},"generic_requirements":[]}}}}"#,
            function_target("forward")
        )
    };
    let owners = BTreeMap::from([("app".to_owned(), APP)]);
    check_project(
        &sources,
        &owners,
        vec![contract(&document(&record(&nominal)))],
    )
    .expect("contract nominal actuals consume the same function formal relation");
    for (ty, kind) in [
        (
            nominal.replace("\"kind\":\"struct\"", "\"kind\":\"enum\""),
            CheckDiagnosticKind::ContractBinding,
        ),
        (
            nominal.replace(&format!("[{formal}]"), "[]"),
            CheckDiagnosticKind::ContractBinding,
        ),
        (
            nominal.replace(&formal, r#"{"tag":"primitive","name":"Int"}"#),
            CheckDiagnosticKind::ContractConflict,
        ),
    ] {
        let diagnostic = check_project(&sources, &owners, vec![contract(&document(&record(&ty)))])
            .expect_err("wrong nominal kind, arity or source relationship cannot bind");
        assert_eq!(diagnostic.kind, kind, "{diagnostic:?}");
        assert!(matches!(
            diagnostic.primary,
            Some(CheckOrigin::Contract { .. })
        ));
        assert!(
            diagnostic
                .related
                .iter()
                .any(|origin| matches!(origin, CheckOrigin::Source(_)))
        );
    }
}

#[test]
fn nominal_cross_library_contracts_and_reexports_keep_original_identity_and_privacy() {
    let mut sources = ProjectSources {
        entry: APP,
        core: CORE,
        libraries: with_core(BTreeMap::from([
            (APP, LibrarySources {
                root: "use facade::Parcel; pub fn forward<T>(value: move Parcel<T>) -> Parcel<T> { value } fn read(value: &Parcel<Int>) -> Int { value.value }".to_owned(),
                modules: BTreeMap::new(),
                dependencies: BTreeMap::from([("facade".to_owned(), DEPENDENCY), ("original".to_owned(), OTHER)]),
            }),
            (DEPENDENCY, LibrarySources {
                root: "pub use model::Box as Parcel; pub type NumberBox = Parcel<Int>;".to_owned(),
                modules: BTreeMap::new(),
                dependencies: BTreeMap::from([("model".to_owned(), OTHER)]),
            }),
            (OTHER, LibrarySources {
                root: "pub struct Box<T> { pub value: T }".to_owned(),
                modules: BTreeMap::new(),
                dependencies: BTreeMap::new(),
            }),
        ])),
    };
    let formal = function_formal("forward", 0);
    let nominal = format!(
        r#"{{"tag":"nominal","declaration":{{"library":{{"tag":"dependency","alias":"facade"}},"path":["Parcel"],"kind":"struct"}},"arguments":[{formal}]}}"#
    );
    let record = format!(
        r#"{{"target":{},"type_parameters":["Renamed"],"set":{{"return_type":{nominal}}}}}"#,
        function_target("forward")
    );
    let owners = BTreeMap::from([("app".to_owned(), APP)]);
    check_project(&sources, &owners, vec![contract(&document(&record))])
        .expect("a contract and source facade consume the same original nominal declaration");
    sources.libraries.get_mut(&APP).unwrap().root =
        "use facade::NumberBox; fn forward(value: NumberBox) -> original::Box<Int> { value }"
            .to_owned();
    check_project(&sources, &BTreeMap::new(), Vec::new())
        .expect("transparent aliases preserve nominal actuals and origin");
    sources.libraries.get_mut(&DEPENDENCY).unwrap().root =
        "pub struct Box<T> { pub value: T }".to_owned();
    sources.libraries.get_mut(&APP).unwrap().root =
        "fn wrong(value: facade::Box<Int>) -> original::Box<Int> { value }".to_owned();
    let diagnostic = check_project(&sources, &BTreeMap::new(), Vec::new())
        .expect_err("same spelling and structure in different libraries cannot unify");
    assert_eq!(diagnostic.kind, CheckDiagnosticKind::ReturnMismatch);
    sources.libraries.get_mut(&OTHER).unwrap().root = "pub struct Box<T> { value: T }".to_owned();
    sources.libraries.get_mut(&APP).unwrap().root =
        "fn wrong(value: &original::Box<Int>) -> Int { value.value }".to_owned();
    let diagnostic = check_project(&sources, &BTreeMap::new(), Vec::new())
        .expect_err("cross-library private fields remain inaccessible");
    assert_eq!(diagnostic.kind, CheckDiagnosticKind::TypeMismatch);
    assert!(
        diagnostic
            .related
            .iter()
            .any(|origin| matches!(origin, CheckOrigin::Source(origin) if origin.library == OTHER))
    );
}

#[test]
fn nominal_support_does_not_ignore_bounds_impls_or_open_adjacent_capabilities() {
    for source in [
        "struct Box<T: Copy> { value: T }",
        "enum Choice<T: Clone> { Value(T) }",
        "struct Value {} impl Value { fn get(self: &Self) -> Int { 1 } }",
        "struct Value {} impl Drop for Value { fn drop(self: &mut Self) -> Unit {} }",
        "struct Box<T> { value: T } type Alias<T> = Box<T>;",
        "struct Value { text: Str }",
        "struct Value { items: List<Int> }",
        "struct Point { x: Int } fn bad(value: Point) -> Point { Point { ..value, x: 2 } }",
        "struct Point { x: Int } fn bad(value: &Point) -> Int { value.method() }",
        "struct Point { x: Int } fn bad(value: &Point) -> Bool { value == value }",
    ] {
        assert_eq!(
            error(source).kind,
            CheckDiagnosticKind::Unsupported,
            "{source}"
        );
    }
}
