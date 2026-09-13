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
fn trait_proof_can_grow_before_reaching_its_base_fact() {
    check(
        r#"
trait P {}
trait Step { type Next; }
struct Wrap<T> { value: T }
struct Grow<T> { value: T }
struct A {}
struct End {}
impl Step for A { type Next = Wrap<Grow<A>>; }
impl<T> Step for Grow<T> { type Next = End; }
impl P for End {}
impl<T: Step> P for Wrap<T> where T::Next: P {}
fn need<T: P>(value: &T) -> Unit {}
fn use_proof() { need(Wrap { value: A {} }); }
"#,
    )
    .expect("Wrap<A>:P closes through Wrap<Grow<A>>:P and End:P");
}

#[test]
fn ordinary_and_method_bodies_share_real_recursive_dependencies() {
    check(
        r#"
trait Tick { fn tick(self: &Self) -> Int; }
struct Runner { n: Int }
impl Runner {
    fn new(n: Int) -> Self { Runner { n } }
    fn read(self: &Self) -> Int { self.n }
    fn step(self: &Self, n: Int) -> Int {
        if n == 0 { self.read() } else { again(self, n - 1) }
    }
}

impl Tick for Runner { fn tick(self: &Self) -> Int { self.read() } }
fn again(runner: &Runner, n: Int) -> Int { runner.step(n) }
fn dictionary<T: Tick>(value: &T) -> Int { value.tick() }
fn use_methods() -> Int {
    let runner = Runner::new(2);
    dictionary(runner) + runner.step(3)
}
"#,
    )
    .expect("method dependencies close with ordinary recursion and formal evidence");
}

#[test]
fn explicit_effect_rows_propagate_through_real_calls_and_module_ceilings() {
    check(
        r#"
effect alias IO = {console, fs};
fn declared() -> Unit with {IO, process, mut, unsafe, fail<Int>} {}
fn relay() -> Unit with {IO, process, mut, unsafe, fail<Int>} { declared() }
"#,
    )
    .expect("a public upper bound is retained even when its body is pure");
    for source in [
        "fn noisy() with {console} {} fn quiet() with {} { noisy() }",
        "requires {}; fn noisy() with {console} {}",
        "effect alias Bad = {fail<Int>, fail<Bool>}; fn bad() with {Bad} {}",
    ] {
        assert_eq!(
            error(source).kind,
            CheckDiagnosticKind::TypeMismatch,
            "{source}"
        );
    }
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
fn alias_cycles_and_wrong_arity_are_type_errors_and_tuple_comparison_requires_evidence() {
    for source in [
        "type A = B; type B = A; fn value() -> A { 1 }",
        "fn value() -> Int<Bool> { 1 }",
    ] {
        assert_eq!(error(source).kind, CheckDiagnosticKind::TypeMismatch);
    }
    assert_eq!(
        error("fn value() -> Bool { (1, 2) == (1, 2) }").kind,
        CheckDiagnosticKind::TypeMismatch
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
fn source_concrete_shapes_and_adjacent_declarations_remain_unsupported() {
    let cases = [
        "fn apply(callback: fn(Int) -> Int) -> Int { 1 }",
        "extern fn host() -> Int with {}; fn good() -> Int { 1 }",
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
fn contract_families_distinguish_unsupported_capabilities_from_binding_errors() {
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
        format!(
            r#"{{"target":{target},"set":{{"generic_requirements":[{{"tag":"trait","subject":{{"tag":"primitive","name":"Int"}},"bound":{{"trait":{{"library":{{"tag":"self"}},"path":["Missing"],"kind":"trait"}},"arguments":[],"associated_bindings":[]}}}}]}}}}"#
        ),
        r#"{"target":{"tag":"declaration","declaration":{"library":{"tag":"self"},"path":["value"],"kind":"struct"}},"set":{"return_type":{"tag":"primitive","name":"Int"}}}"#.to_owned(),
    ];
    for (index, record) in records.into_iter().enumerate() {
        let diagnostic = check_project(
            &sources,
            &BTreeMap::from([("app".to_owned(), APP)]),
            vec![contract(&document(&record))],
        )
        .expect_err("selected clause or target is outside the initial subset");
        assert_eq!(
            diagnostic.kind,
            if matches!(index, 0 | 3) {
                CheckDiagnosticKind::ContractBinding
            } else {
                CheckDiagnosticKind::Unsupported
            },
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
        check(&format!(
            "fn f<T>(flag: Bool, x: move T) -> Unit {{ {body} }}"
        ))
        .expect("a discarded owned branch contributes D(T)");
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
        check(&format!(
            "fn f<T>(flag: Bool, pair: move (T, Int), bottom: (Never, Int)) -> (T, Int) {{ \
                 let result = {branches}; result }}"
        ))
        .expect("the unselected owned branch contributes its destruction relation");
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
        CheckDiagnosticKind::TypeMismatch
    );
}

#[test]
fn early_return_cleans_generic_temporaries_from_partially_evaluated_expressions() {
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
        check(source).expect("early return retains the pending generic temporary cleanup relation");
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
            CheckDiagnosticKind::TypeMismatch,
        ),
        (
            "fn choose<T>(left: move T, right: move T) -> T with {} { left }",
            CheckDiagnosticKind::TypeMismatch,
        ),
        (
            "fn early<T>(flag: Bool, left: move T, right: move T) -> T with {} { \
                 if flag { return left; } \
                 right \
             }",
            CheckDiagnosticKind::TypeMismatch,
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
fn nominal_cleanup_handles_long_field_graphs_without_host_recursion() {
    let count = 1024;
    let ring = (0..count)
        .map(|index| {
            format!(
                "struct Node{index} {{ next: Node{} }}\n",
                (index + 1) % count
            )
        })
        .collect::<String>();
    check(&format!(
        "{ring}
        fn borrow(value: &Node0) {{}}
        fn forward(value: Node0) -> Node0 {{ let next = value; next }}
    "
    ))
    .expect("borrowing and whole transfer create no owning cleanup demand");
    check(&format!("{ring} fn drop_recursive(value: move Node0) {{}}")).expect(
        "structural recursion retains an exact destruction relation without unfolding forever",
    );

    let chain = (0..count)
        .map(|index| {
            let next = if index + 1 == count {
                "Int".to_owned()
            } else {
                format!("Node{}", index + 1)
            };
            format!("struct Node{index} {{ next: {next} }}\n")
        })
        .collect::<String>();
    check(&format!("{chain} fn drop_finite(value: move Node0) {{}}"))
        .expect("actual pure cleanup walks all finite fields on an explicit work stack");
}

#[test]
fn finite_repeated_nominal_owners_clean_up_and_retain_recursive_destruction_relations() {
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
        check(source)
            .expect("generic and structural recursive destruction retain formal relations");
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
        check(&source).expect("pending construction members contribute return cleanup effects");
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
        "struct Value {} impl Drop for Value { fn drop(self: &mut Self) -> Unit {} }",
        "struct Box<T> { value: T } type Alias<T> = Box<T>;",
        "struct Value { text: Str }",
        "struct Value { items: List<Int> }",
        "struct Point { x: Int } fn bad(value: Point) -> Point { Point { ..value, x: 2 } }",
    ] {
        assert_eq!(
            error(source).kind,
            CheckDiagnosticKind::Unsupported,
            "{source}"
        );
    }
}

#[test]
fn operation_calls_and_unsafe_use_real_effect_identities() {
    check(
        r#"
requires {unsafe, Tick, console, mut, fail<Int>};
effect Tick { fn tick(value: Int) -> Int; }
fn raw() -> Int with {unsafe, console, mut, fail<Int>} { 1 }
fn operate(value: Int) -> Int with {Tick, console, mut, fail<Int>} {
    unsafe { raw() };
    Tick.tick(value)
}
fn raise() -> Never with {fail<Int>} { fail.raise(1) }
"#,
    )
    .expect("unsafe removes only unsafe; operation and failure keep their owners");
    check("effect Echo<T> { fn echo(value: T) -> T; } fn use_echo() -> Int with {Echo<Int>} { Echo.echo(1) }")
        .expect("operation type actual is closed by its argument");
    for source in [
        "fn bad() { unsafe { 1 }; }",
        "requires {unsafe, console}; fn noisy() with {unsafe, console} {} fn bad() with {} { unsafe { noisy() } }",
        "effect Echo<T> { fn echo(value: T) -> T; } fn bad() { Echo.echo(1); Echo.echo(true); }",
        "effect Echo<T> { fn echo(value: T) -> T; } fn bad<T>(value: &T) { Echo.echo(value); }",
    ] {
        assert_eq!(
            error(source).kind,
            CheckDiagnosticKind::TypeMismatch,
            "{source}"
        );
    }
}

#[test]
fn shared_fn_callbacks_use_one_minimal_effect_actual_for_all_arguments() {
    check(
        r#"
fn pure() -> Unit with {} {}
fn console_callback() -> Unit with {console} {}
fn file_callback() -> Unit with {fs} {}
fn sequence<F: Fn + fn() -> Unit with {E}, G: Fn + fn() -> Unit with {E}, effect E>(
    first: call F, second: call G
) -> Unit with {E} {
    first(); second();
}
fn pure_use() with {} { let callback = pure; sequence(callback, pure); }
fn combined_use() with {console, fs} { sequence(console_callback, file_callback); }
"#,
    )
    .expect("shared Fn and both callback lower bounds are checked in the same call mapping");
    let mismatch = error(
        r#"
fn first() -> Unit with {fail<Int>} {}
fn second() -> Unit with {fail<Bool>} {}
fn sequence<F: Fn + fn() -> Unit with {E}, G: Fn + fn() -> Unit with {E}, effect E>(first: call F, second: call G) with {E} { first(); second(); }
fn bad() { sequence(first, second); }
"#,
    );
    assert_eq!(mismatch.kind, CheckDiagnosticKind::TypeMismatch);
    assert_eq!(error("fn provider() -> Unit {} fn take<F: Fn + fn() -> Unit>(f: call F) { f(); } fn bad() { take(provider); }").kind, CheckDiagnosticKind::Unsupported);
    assert_eq!(
        error("fn bad<F: FnOnce + fn() -> Unit>(f: call F) { f(); }").kind,
        CheckDiagnosticKind::Unsupported
    );
}

#[test]
fn ordinary_omitted_shape_rows_are_constrained_only_by_actual_body_consumers() {
    check(
        r#"
fn pure() -> Unit with {} {}
fn noisy() -> Unit with {console} {}
fn require_pure<F: Fn + fn() -> Unit>(callback: call F) -> Unit with {} { callback(); }
fn ignore<F: Fn + fn() -> Unit>(callback: call F) -> Unit with {} {}
fn check_both() with {} { require_pure(pure); ignore(noisy); }
"#,
    )
    .expect("an omitted shape row can close to pure without constraining an unused callback");
    assert_eq!(error("fn noisy() -> Unit with {console} {} fn require_pure<F: Fn + fn() -> Unit>(callback: call F) with {} { callback(); } fn bad() { require_pure(noisy); }").kind, CheckDiagnosticKind::TypeMismatch);
}

#[test]
fn recursive_callback_effect_actuals_keep_the_same_formal_relationship() {
    check(
        r#"
fn first<F: Fn + fn() -> Unit with {E}, effect E>(done: Bool, callback: call F) -> Unit with {E} {
    if done { callback() } else { second(true, callback) }
}
fn second<G: Fn + fn() -> Unit with {R}, effect R>(done: Bool, callback: call G) -> Unit with {R} {
    if done { callback() } else { first(true, callback) }
}
fn console_callback() -> Unit with {console} {}
fn use_recursion() with {console} { first(false, console_callback); }
"#,
    )
    .expect("mutual recursion preserves type and effect actuals without another body pass");
}

#[test]
fn contract_effect_terms_and_partial_conflicts_keep_document_paths() {
    let sources = project(
        "fn noisy() with {console} {} fn relay() { noisy(); } fn discard<T>(value: move T) {} fn apply<F: Fn + fn() -> Unit with {E}, effect E>(callback: call F) { callback(); }",
    );
    let discard = function_target("discard");
    let apply = function_target("apply");
    let type_formal = |target: &str| {
        format!(
            r#"{{"tag":"formal","formal":{{"owner":{target},"binder":"declaration","kind":"type","index":0}}}}"#
        )
    };
    let records = format!(
        r#"
{{"target":{},"set":{{"effect_upper":[{{"tag":"system","name":"console"}}]}}}},
{{"target":{discard},"type_parameters":["Alpha"],"set":{{"effect_upper":[{{"tag":"full_destruction","type":{}}}]}}}},
{{"target":{apply},"type_parameters":["Callback"],"set":{{"effect_upper":[{{"tag":"selected_call","callable":{}}}],"parameter_modes":[{{"parameter":{{"tag":"position","index":0}},"mode":{{"tag":"callable_use","callable":{}}}}}]}}}}
"#,
        function_target("relay"),
        type_formal(&discard),
        type_formal(&apply),
        type_formal(&apply)
    );
    check_project(
        &sources,
        &BTreeMap::from([("app".to_owned(), APP)]),
        vec![contract(&document(&records))],
    )
    .expect("contract effects and shared callable_use enter the ordinary checker");
    let wrong = document(&format!(
        r#"{{"target":{},"set":{{"effect_upper":[]}}}}"#,
        function_target("relay")
    ));
    let diagnostic = check_project(
        &sources,
        &BTreeMap::from([("app".to_owned(), APP)]),
        vec![contract(&wrong)],
    )
    .unwrap_err();
    assert!(
        matches!(diagnostic.primary, Some(CheckOrigin::Contract { ref json_path, .. }) if json_path == "$.records[0].set.effect_upper")
    );
    let conflict = document(&format!(
        r#"{{"target":{},"set":{{"effect_upper":[]}}}},{{"target":{},"set":{{"effect_upper":[{{"tag":"system","name":"console"}}]}}}}"#,
        function_target("relay"),
        function_target("relay")
    ));
    assert_eq!(
        check_project(
            &sources,
            &BTreeMap::from([("app".to_owned(), APP)]),
            vec![contract(&conflict)]
        )
        .unwrap_err()
        .kind,
        CheckDiagnosticKind::ContractConflict
    );
}

#[test]
fn contract_requirements_are_grouped_before_body_selection_and_never_unioned() {
    let source = "trait Value { fn value(self: &Self) -> Int; } trait Other {} struct Item {} impl Value for Item { fn value(self: &Self) -> Int { 1 } } fn extract<T>(item: &T) -> Int { item.value() } fn use_it() -> Int { extract(Item {}) }";
    let target = function_target("extract");
    let formal = format!(
        r#"{{"tag":"formal","formal":{{"owner":{target},"binder":"declaration","kind":"type","index":0}}}}"#
    );
    let predicate = |name: &str| {
        format!(
            r#"{{"tag":"trait","subject":{formal},"bound":{{"trait":{{"library":{{"tag":"self"}},"path":["{name}"],"kind":"trait"}},"arguments":[],"associated_bindings":[]}}}}"#
        )
    };
    let record = |requirements: &str| {
        format!(
            r#"{{"target":{target},"type_parameters":["Alpha"],"set":{{"generic_requirements":[{requirements}]}}}}"#
        )
    };
    let owners = BTreeMap::from([("app".to_owned(), APP)]);
    check_project(
        &project(source),
        &owners,
        vec![contract(&document(&record(&predicate("Value"))))],
    )
    .expect("P is available during dictionary selection");
    assert_eq!(
        check_project(
            &project(source),
            &owners,
            vec![contract(&document(&record("")))]
        )
        .unwrap_err()
        .kind,
        CheckDiagnosticKind::TypeMismatch
    );
    let conflict = format!(
        "{},{}",
        record(&predicate("Value")),
        record(&predicate("Other"))
    );
    assert_eq!(
        check_project(
            &project(source),
            &owners,
            vec![contract(&document(&conflict))]
        )
        .unwrap_err()
        .kind,
        CheckDiagnosticKind::ContractConflict
    );
}

#[test]
fn contract_trait_and_impl_members_bind_receiver_outer_and_own_formals() {
    let source = "trait Work<T> { fn run<U>(self: &Self, input: &T, value: move U) -> U; } struct Holder<T> { stored: T } impl<T> Work<T> for Holder<T> { fn run<V>(self: &Self, input: &T, value: move V) -> V { value } } fn use_it() -> Bool { Holder { stored: 1 }.run(1, true) }";
    let trait_ref = r#"{"library":{"tag":"self"},"path":["Work"],"kind":"trait"}"#;
    let trait_owner = format!(r#"{{"tag":"declaration","declaration":{trait_ref}}}"#);
    let trait_target =
        format!(r#"{{"tag":"trait_member","owner":{trait_ref},"kind":"method","name":"run"}}"#);
    let impl_ref = r#"{"library":{"tag":"self"},"type_parameter_count":1,"target":{"tag":"nominal","declaration":{"library":{"tag":"self"},"path":["Holder"],"kind":"struct"},"arguments":[{"tag":"local_type_parameter","index":0}]},"trait":{"trait":{"library":{"tag":"self"},"path":["Work"],"kind":"trait"},"arguments":[{"tag":"local_type_parameter","index":0}],"associated_bindings":[]}}"#;
    let impl_owner = format!(r#"{{"tag":"impl","implementation":{impl_ref}}}"#);
    let impl_target =
        format!(r#"{{"tag":"impl_member","owner":{impl_ref},"kind":"method","name":"run"}}"#);
    let formal = |owner: &str, binder: &str| {
        format!(
            r#"{{"tag":"formal","formal":{{"owner":{owner},"binder":"{binder}","kind":"type","index":0}}}}"#
        )
    };
    let trait_self = format!(
        r#"{{"tag":"self_type","owner":{{"tag":"declaration","declaration":{trait_ref}}}}}"#
    );
    let impl_self =
        format!(r#"{{"tag":"self_type","owner":{{"tag":"impl","implementation":{impl_ref}}}}}"#);
    let record = |target: &str, self_type: &str, outer: &str, own: &str| {
        format!(
            r#"{{"target":{target},"type_parameters":["Local"],"set":{{"parameter_types":[{{"parameter":{{"tag":"receiver"}},"type":{self_type}}},{{"parameter":{{"tag":"position","index":0}},"type":{outer}}},{{"parameter":{{"tag":"position","index":1}},"type":{own}}}],"return_type":{own},"effect_upper":[]}}}}"#
        )
    };
    let records = format!(
        "{},{}",
        record(
            &trait_target,
            &trait_self,
            &formal(&trait_owner, "declaration"),
            &formal(&trait_target, "method")
        ),
        record(
            &impl_target,
            &impl_self,
            &formal(&impl_owner, "impl"),
            &formal(&impl_target, "method")
        )
    );
    check_project(
        &project(source),
        &BTreeMap::from([("app".to_owned(), APP)]),
        vec![contract(&document(&records))],
    )
    .expect("trait and impl contracts share each callable's actual owner scope");
}

#[test]
fn callback_support_does_not_enable_general_returns_or_aggregate_storage() {
    for source in [
        "fn callback() -> Unit with {} {} fn factory() { callback }",
        "fn return_owned<F: Fn + fn() -> Unit>(callback: move F) -> F { callback }",
        "fn callback() -> Unit with {} {} fn bad() { let pair = (callback, 1); }",
        "fn pack<T>(value: move T) { let pair = (value, 1); } fn callback() -> Unit with {} {} fn bad() { pack(callback); }",
        "fn identity<T>(value: move T) -> T { value } fn callback() -> Unit with {} {} fn bad() { let alias = identity(callback); }",
        "fn raise<T>(value: move T) -> Never { fail.raise(value) } fn callback() -> Unit with {} {} fn bad() { raise(callback); }",
    ] {
        assert_eq!(
            error(source).kind,
            CheckDiagnosticKind::Unsupported,
            "{source}"
        );
    }
    check("fn callback() -> Unit with {} {} fn observe<T>(value: &T) {} fn good() { let alias = callback; observe(alias); alias(); }")
        .expect("an immutable named-function alias can be borrowed and called");
}

#[test]
fn associated_bounds_defaults_and_finite_repeated_proofs_close() {
    check(
        r#"
trait P {}
trait Step { type Next: P; }
struct A {}
struct Wrap<T> { value: T }
impl P for A {}
impl<T: P> P for Wrap<T> {}
impl Step for A { type Next = Self; }
fn need<T: P>(value: &T) -> Unit {}
fn associated<T: Step>(owner: &T, value: &T::Next) -> Unit { need(value); }
fn repeated() { need(Wrap { value: Wrap { value: A {} } }); associated(A {}, A {}); }
trait Default { type Value = Int; fn value(self: &Self) -> Self::Value; }
struct First {}
struct Second {}
impl Default for First { fn value(self: &Self) -> Int { 1 } }
impl Default for Second { type Value = Bool; fn value(self: &Self) -> Bool { true } }
fn defaults() { let first: Int = First {}.value(); let second: Bool = Second {}.value(); }
"#,
    )
    .expect("associated bound, override, Next=Self, and repeated finite evidence");
    for source in [
        "trait P {} trait Step { type Next: P; } struct A {} impl Step for A { type Next = Int; }",
        "trait P {} trait Q: P {} struct A {} impl Q for A {}",
        "trait P { fn read(self: &Self) -> Int; } struct A {} impl P for A {}",
        "trait P {} struct A {} impl P for A { fn extra(self: &Self) {} }",
        "trait P { fn read(self: &Self) -> Int; } struct A {} impl P for A { fn read(self: move Self) -> Int { 1 } }",
    ] {
        assert_eq!(
            error(source).kind,
            CheckDiagnosticKind::TypeMismatch,
            "{source}"
        );
    }
}

#[test]
fn projection_cycles_and_growing_search_have_distinct_bounded_diagnostics() {
    for source in [
        "trait Step { type Next; } struct A {} impl Step for A { type Next = Self::Next; }",
        "trait Step { type Next; } struct A {} struct B {} impl Step for A { type Next = B::Next; } impl Step for B { type Next = A::Next; }",
        "trait P {} struct A {} impl P for A where A: P {} fn need<T: P>(value: &T) {} fn use_it() { need(A {}); }",
    ] {
        let failure = error(source);
        assert!(failure.message.contains("cycle"), "{failure:?}");
        assert!(failure.primary.is_some());
    }
    let failure = error(
        "trait P {} struct Grow<T> { value: T } struct A {} impl<T> P for Grow<T> where Grow<Grow<T>>: P {} fn need<T: P>(value: &T) {} fn use_it() { need(Grow { value: A {} }); }",
    );
    assert!(
        failure.message.contains("proof incomplete") && failure.message.contains("limit"),
        "{failure:?}"
    );
    eprintln!("growth probe: {failure:?}");
    assert!(failure.primary.is_some());
}

#[test]
fn public_trait_surfaces_preserve_private_representation_boundaries() {
    check("pub trait P { fn read(self: &Self) -> Int; } struct Hidden {} impl P for Hidden { fn read(self: &Self) -> Int { 1 } } pub struct Public { hidden: Hidden } fn inside() { Hidden {}.read(); }").expect("private target impl stays inside its module");
    for source in [
        "trait Hidden {} pub trait Public: Hidden {}",
        "trait Hidden {} pub struct Public<T: Hidden> { value: T }",
        "trait Hidden {} pub fn public<T: Hidden>(value: &T) -> Unit {}",
        "struct Hidden {} pub trait Public { type Item = Hidden; }",
        "trait Public {} struct Hidden {} pub struct Open {} impl Public for Open {} pub trait Result { type Item; } impl Result for Open { type Item = Hidden; }",
        "effect Hidden { fn action() -> Unit; } pub fn public() -> Unit with { Hidden } {}",
    ] {
        let failure = error(source);
        assert!(failure.message.contains("private"), "{failure:?}: {source}");
    }
}

#[test]
fn contract_domain_is_available_before_source_projection_selection() {
    let target = function_target("take");
    let formal = format!(
        r#"{{"tag":"formal","formal":{{"owner":{target},"binder":"declaration","kind":"type","index":0}}}}"#
    );
    let predicate = format!(
        r#"{{"tag":"trait","subject":{formal},"bound":{{"trait":{{"library":{{"tag":"self"}},"path":["Value"],"kind":"trait"}},"arguments":[],"associated_bindings":[]}}}}"#
    );
    let record = format!(
        r#"{{"target":{target},"type_parameters":["Alpha"],"set":{{"generic_requirements":[{predicate}]}}}}"#
    );
    let source = "trait Value { type Item; } struct A {} impl Value for A { type Item = Int; } fn take<T>(owner: &T, item: &T::Item) -> Unit {} fn use_it() { take(A {}, 1); }";
    check_project(
        &project(source),
        &BTreeMap::from([("app".to_owned(), APP)]),
        vec![contract(&document(&record))],
    )
    .expect("P determines source associated lookup before header normalization");
}

#[test]
fn core_comparisons_use_explicit_and_generic_evidence() {
    check(r#"
struct Value { stored: Int }
impl PartialEq for Value { fn eq(self: &Self, other: &Self) -> Bool with {} { self.stored == other.stored } }
impl Eq for Value {}
fn compare<T: PartialEq>(left: &T, right: &T) -> Bool with {} { left == right }
fn concrete() -> Bool { compare(Value { stored: 1 }, Value { stored: 2 }) }
"#).expect("source core implementation and fixed generic dictionary use the comparison solver");
    assert!(
        error("struct A {} fn compare(left: &A, right: &A) -> Bool { left == right }")
            .message
            .contains("no evidence")
    );
    assert!(
        error("impl PartialEq for Int { fn eq(self: &Self, other: &Self) -> Bool { true } }")
            .message
            .contains("orphan")
    );
}

#[test]
fn disjoint_where_domains_select_evidence_but_not_a_public_impl_identity() {
    let source = r#"
trait Tag { type Kind; }
trait Read { fn read(self: &Self) -> Int; }
struct A {} struct B {} struct Wrap<T> { value: T }
impl Tag for A { type Kind = Int; }
impl Tag for B { type Kind = Bool; }
impl<T: Tag<Kind = Int>> Read for Wrap<T> { fn read(self: &Self) -> Int { 1 } }
impl<T: Tag<Kind = Bool>> Read for Wrap<T> { fn read(self: &Self) -> Int { 2 } }
fn use_it() { Wrap { value: A {} }.read(); Wrap { value: B {} }.read(); }
"#;
    check(source).expect(
        "associated equalities prove disjoint input domains and select the applicable impl",
    );
    let implementation = r#"{"library":{"tag":"self"},"type_parameter_count":1,"target":{"tag":"nominal","declaration":{"library":{"tag":"self"},"path":["Wrap"],"kind":"struct"},"arguments":[{"tag":"local_type_parameter","index":0}]},"trait":{"trait":{"library":{"tag":"self"},"path":["Read"],"kind":"trait"},"arguments":[],"associated_bindings":[]}}"#;
    let record = format!(
        r#"{{"target":{{"tag":"impl_member","owner":{implementation},"kind":"method","name":"read"}},"set":{{"effect_upper":[]}}}}"#
    );
    let failure = check_project(
        &project(source),
        &BTreeMap::from([("app".to_owned(), APP)]),
        vec![contract(&document(&record))],
    )
    .unwrap_err();
    assert!(
        failure.message.contains("ImplRef is ambiguous"),
        "{failure:?}"
    );
    assert!(
        matches!(failure.primary, Some(CheckOrigin::Contract { ref json_path, .. }) if json_path == "$.records[0].target")
    );
}

#[test]
fn nominal_formation_conditions_are_checked_in_signatures_and_fields() {
    check("trait P {} struct A {} impl P for A {} struct Box<T: P> { value: T } fn valid<T: P>(value: &Box<T>) {} struct Container<T: P> { value: Box<T> } fn use_it() { valid(Box { value: A {} }); }").expect("formation conditions use the declared domain");
    for source in [
        "trait P {} struct Box<T: P> { value: T } fn bad() { Box { value: 1 }; }",
        "trait P {} struct Box<T: P> { value: T } fn bad(value: &Box<Int>) {}",
        "trait P {} struct Box<T: P> { value: T } fn bad<T>(value: &Box<T>) {}",
        "trait P {} struct Box<T: P> { value: T } struct Bad<T> { value: Box<T> }",
    ] {
        assert!(error(source).message.contains("no evidence"), "{source}");
    }
}

#[test]
fn method_effect_contracts_keep_abstract_and_per_impl_rows() {
    check(
        r#"
trait Run { fn run(self: &Self) -> Unit; }
struct First {} struct Second {}
impl Run for First { fn run(self: &Self) -> Unit with {console} {} }
impl Run for Second { fn run(self: &Self) -> Unit with {fs} {} }
fn abstract_run<T: Run>(value: &T) -> Unit { value.run(); }
fn first() with {console} { abstract_run(First {}); }
fn second() with {fs} { abstract_run(Second {}); }
trait Fixed { fn run(self: &Self) -> Unit with {console, fs}; }
impl Fixed for First { fn run(self: &Self) -> Unit with {console} {} }
fn generic_fixed<T: Fixed>(value: &T) with {console, fs} { value.run(); }
fn concrete_fixed() with {console, fs} { generic_fixed(First {}); }
fn scheme() with {Run::run<Second>} { second(); }
"#,
    )
    .expect("an abstract method relationship does not union unrelated impl rows");
    for source in [
        "trait Loop { fn step(self: &Self) -> Unit with {Loop::step<Self>}; }",
        "trait Loop { fn first(self: &Self) -> Unit with {Loop::second<Self>}; fn second(self: &Self) -> Unit with {Loop::first<Self>}; }",
        "trait Run { fn run(self: &Self) -> Unit; } fn bad<T: Run>(value: &T) with {} { value.run(); }",
        "trait Fixed { fn run(self: &Self) with {console}; } struct A {} impl Fixed for A { fn run(self: &Self) with {fs} {} }",
    ] {
        let failure = error(source);
        assert_eq!(
            failure.kind,
            CheckDiagnosticKind::TypeMismatch,
            "{failure:?}"
        );
    }
}

#[test]
fn generic_merge_legality_and_effect_only_type_actuals_close_at_the_call() {
    check(
        r#"
fn payload<T>() -> Unit with {fail<T>} {}
fn bound() with {fail<Int>} { payload(); }
fn pure() -> Unit with {} {}
fn fail_int() -> Unit with {fail<Int>} {}
fn attempt<T, F: Fn + fn() -> Unit with {E}, effect E>(error: T, callback: call F) -> Unit {
    callback(); fail.raise(error)
}
fn legal() with {fail<Int>} { attempt(1, pure); attempt(1, fail_int); }
"#,
    )
    .expect("effect-only type actuals and callback merge obligations use the call mapping");
    let failure = error(
        "fn fail_bool() -> Unit with {fail<Bool>} {} fn attempt<T, F: Fn + fn() -> Unit with {E}, effect E>(error: T, callback: call F) { callback(); fail.raise(error); } fn bad() { attempt(1, fail_bool); }",
    );
    assert!(failure.message.contains("payload conflict"), "{failure:?}");
}

#[test]
fn nested_shared_shapes_and_fixed_method_rows_use_the_same_callback_actual() {
    check(r#"
fn pure() -> Unit with {} {}
fn apply<G: Fn + fn() -> Unit with {}>(callback: call G) -> Unit with {} { callback(); }
fn nested<G: Fn + fn() -> Unit with {E}, F: Fn + fn(call G) -> Unit with {E}, effect E>(higher: call F, lower: call G) -> Unit with {E} { higher(lower); }
fn use_nested() with {} { nested(apply, pure); }
trait Row { fn row(self: &Self) -> Unit; }
struct A {}
fn console() -> Unit with {console} {}
impl Row for A { fn row(self: &Self) -> Unit { console(); } }
fn select<F: Fn + fn() -> Unit with {Row::row<A>, E}, effect E>(callback: call F) -> Unit with {E} {}
fn smallest() with {} { select(console); }
"#).expect("nested call G is fixed Borrow; method contribution leaves the smallest E empty");
    let failure = error(
        "trait P {} fn constrained<T: P>(value: &T) -> Int with {} { 1 } fn take<F: Fn + fn(&Int) -> Int with {}>(callback: call F) -> Int { callback(1) } fn bad() -> Int { take(constrained) }",
    );
    assert!(failure.message.contains("no evidence"), "{failure:?}");
}

#[test]
fn contract_shared_shape_without_an_upper_keeps_selected_call_relation() {
    let target = function_target("apply");
    let formal = function_formal("apply", 0);
    let predicate = format!(
        r#"{{"tag":"trait","subject":{formal},"bound":{{"trait":{{"library":{{"tag":"dependency","alias":"vorton_core"}},"path":["Fn"],"kind":"trait"}},"arguments":[],"associated_bindings":[]}}}}"#
    );
    let shape = format!(
        r#"{{"tag":"callable_shape","subject":{formal},"shape":{{"parameters":[],"result":{{"tag":"primitive","name":"Unit"}}}}}}"#
    );
    let record = format!(
        r#"{{"target":{target},"type_parameters":["F"],"set":{{"generic_requirements":[{predicate},{shape}],"parameter_modes":[{{"parameter":{{"tag":"position","index":0}},"mode":{{"tag":"callable_use","callable":{formal}}}}}]}}}}"#
    );
    let source = "fn apply<F>(callback: &F) -> Unit { callback(); } fn console() -> Unit with {console} {} fn use_it() with {console} { apply(console); }";
    check_project(&project(source), &BTreeMap::from([("app".to_owned(), APP)]), vec![contract(&document(&record))]).expect("an unspecified contract shape row relates to this exact callback instead of defaulting to pure");
}

#[test]
fn contract_receiver_types_precede_method_and_field_constraints() {
    let source = "struct Point { x: Int } impl Point { fn read(self: &Self) -> Int { self.x } } fn method(value) -> Int { value.read() } fn field(value) -> Int { value.x }";
    let point = r#"{"tag":"nominal","declaration":{"library":{"tag":"self"},"path":["Point"],"kind":"struct"},"arguments":[]}"#;
    let records = ["method", "field"].into_iter().map(|name| format!(r#"{{"target":{},"set":{{"parameter_types":[{{"parameter":{{"tag":"position","index":0}},"type":{point}}}]}}}}"#, function_target(name))).collect::<Vec<_>>().join(",");
    check_project(&project(source), &BTreeMap::from([("app".to_owned(), APP)]), vec![contract(&document(&records))]).expect("an explicit contract receiver is available to selection without specializing an unconstrained identity function");
}

#[test]
fn trait_owner_actuals_can_be_inferred_from_the_shared_call_constraints() {
    check(r#"
trait Accept<T> { fn accept(self: &Self, value: move T) -> T; }
struct A {}
impl<T> Accept<T> for A { fn accept(self: &Self, value: move T) -> T { value } }
trait P {} impl P for A {}
fn make<T: P>() -> T { make() }
trait Factory { fn create() -> A; }
impl Factory for A { fn create() { make() } }
fn inherited_result() -> A { A::create() }
fn use_it() -> A { let number: Int = A {}.accept(1); let flag: Bool = A {}.accept(true); make() }
"#).expect("owner actuals and return constraints use the one call substitution before evidence selection");
}

#[test]
fn dictionary_selection_and_structured_where_domains_are_observable() {
    check(r#"
trait Read { fn read(self: &Self) -> Int; }
struct A {}
impl Read for A { fn read(self: &Self) -> Int with {console} { 1 } }
impl A { fn read(self: &Self) -> Int with {fs} { 2 } }
fn dictionary<T: Read>(value: &T) -> Int { value.read() }
fn via_dictionary() -> Int with {console} { dictionary(A {}) }
fn via_inherent() -> Int with {fs} { A {}.read() }
trait Pair {} impl<T> Pair for T {}
trait Has {}
trait Next { type Item; }
impl Next for A { type Item = Int; }
struct Wrap<T> { value: T }
impl<T: Next> Has for Wrap<T> where (T::Item, Int): Pair {}
fn require<T: Has>(value: &T) {}
fn where_subject() { require(Wrap { value: A {} }); }
"#).expect("actual inherent spelling cannot replace the generic dictionary; where tuple/projection is proved");
    for (source, message) in [
        (
            "trait Read { fn read(self: &Self) -> Int; } trait Other { fn read(self: &Self) -> Int; } struct A {} impl Read for A { fn read(self: &Self) -> Int { 1 } } impl Other for A { fn read(self: &Self) -> Int { 2 } } fn ambiguous() { A {}.read(); }",
            "ambiguous",
        ),
        (
            "trait Read { fn read<T>(self: &Self, value: &T) -> Int; } trait Extra {} struct A {} impl Read for A { fn read<U: Extra>(self: &Self, value: &U) -> Int { 1 } }",
            "no evidence",
        ),
        (
            "trait P {} struct A {} impl<T> P for T {} impl P for A {}",
            "overlapping",
        ),
        (
            "trait Pair {} trait Has {} struct Wrap<T> { value: T } impl<T> Has for Wrap<T> where (T, Int): Pair {} fn need<T: Has>(value: &T) {} fn bad() { need(Wrap { value: 1 }); }",
            "no evidence",
        ),
    ] {
        let failure = error(source);
        assert!(failure.message.contains(message), "{failure:?}");
    }
}

#[test]
fn cross_library_impls_and_trait_aliases_keep_the_original_orphan_owner() {
    let library = "pub trait Read { fn read(self: &Self) -> Int; } pub struct Foreign {}";
    let make = |root: &str| ProjectSources {
        entry: APP,
        core: CORE,
        libraries: with_core(BTreeMap::from([
            (
                APP,
                LibrarySources {
                    root: root.to_owned(),
                    modules: BTreeMap::new(),
                    dependencies: BTreeMap::from([("model".to_owned(), DEPENDENCY)]),
                },
            ),
            (
                DEPENDENCY,
                LibrarySources {
                    root: library.to_owned(),
                    modules: BTreeMap::new(),
                    dependencies: BTreeMap::new(),
                },
            ),
        ])),
    };
    check_project(&make("pub use model::Read as Reading; pub struct Local {} impl Reading for Local { fn read(self: &Self) -> Int { 1 } } fn use_it() -> Int { Local {}.read() }"), &BTreeMap::new(), Vec::new()).expect("foreign trait with a local nominal target is a valid impl");
    let failure = check_project(&make("pub use model::Read as Reading; use model::Foreign; type Alias = Foreign; impl Reading for Alias { fn read(self: &Self) -> Int { 1 } }"), &BTreeMap::new(), Vec::new()).unwrap_err();
    assert!(failure.message.contains("orphan"), "{failure:?}");
}

#[test]
fn inherent_associated_selection_checks_its_owner_domain() {
    check("trait P {} struct A {} impl P for A {} struct Wrap<T> { value: T } impl<T: P> Wrap<T> { type Item = Int; } type Good = Wrap<A>; fn accept(value: &Good::Item) -> Int { value } fn use_it() -> Int { accept(1) }").expect("inherent associated selection uses its checked owner applicability");
    let failure = error(
        "trait P {} struct Wrap<T> { value: T } impl<T: P> Wrap<T> { type Item = Int; } type Bad = Wrap<Int>; fn accept(value: &Bad::Item) -> Int { value }",
    );
    assert!(failure.message.contains("no evidence"), "{failure:?}");
}

#[test]
fn associated_bindings_normalize_in_signatures_callback_shapes_and_effects() {
    check(r#"
trait Has { type Item; }
struct A {} impl Has for A { type Item = Int; }
fn from_bound<T: Has<Item = Int>>(value: &T::Item) -> Int { value + 1 }
struct Box<T: Has> { value: T::Item }
fn field(value: &Box<A>) -> Int { value.value }
fn construct() -> Box<A> { Box { value: 1 } }
fn provider<T: Has>(owner: &T, value: &T::Item) -> Unit with {} {}
fn take<F: Fn + fn(&A, &Int) -> Unit with {}>(callback: call F) { callback(A {}, 1); }
fn callback() { take(provider); }
fn source() with {fail<Int>} {}
fn projected_effect() with {fail<A::Item>} { source(); }
"#).expect("associated equality and selected concrete projections are normalized before their consumers");
}

#[test]
fn verification_regression_distinct_owner_formals() {
    let cases = [
        (
            "conformance_wrong_dictionary",
            r#"trait Identity { fn id<U>(self: &Self, value: move U) -> U; }
struct Wrap<T> { value: T }
impl<T> Identity for Wrap<T> { fn id<U>(self: &Self, value: move T) -> T { value } }
fn dictionary<X: Identity>(value: &X) -> Bool { value.id(true) }
fn use_it() -> Bool { dictionary(Wrap { value: 1 }) }"#,
            false,
        ),
        (
            "inherent_wrong_return",
            r#"struct Wrap<T> { value: T }
impl<T> Wrap<T> { fn bad<U>(value: move U) -> T { value } }"#,
            false,
        ),
        (
            "regular_wrong_return",
            r#"fn bad<T, U>(value: move U) -> T { value }"#,
            false,
        ),
    ];
    let mut observed = Vec::new();
    let mut diagnostics = Vec::new();
    for (name, source, _) in &cases {
        let result = check(source);
        observed.push(result.is_ok());
        diagnostics.push(format!("{name}: {result:?}"));
    }
    let expected = cases
        .iter()
        .map(|(_, _, accepted)| *accepted)
        .collect::<Vec<_>>();
    assert_eq!(observed, expected, "{}", diagnostics.join("\n"));
}

#[test]
fn verification_regression_inherent_applicability() {
    let cases = [
        (
            "inherent_disjoint",
            r#"trait Kind { type Item; }
struct A {}
struct B {}
struct Wrap<T> { value: T }
impl Kind for A { type Item = Int; }
impl Kind for B { type Item = Bool; }
impl<T: Kind<Item = Int>> Wrap<T> { fn get(self: &Self) -> Int { 1 } }
impl<T: Kind<Item = Bool>> Wrap<T> { fn get(self: &Self) -> Int { 2 } }
fn use_it() -> Int { Wrap { value: B {} }.get() }"#,
            true,
        ),
        (
            "inherent_disjoint_reverse",
            r#"trait Kind { type Item; }
struct A {}
struct B {}
struct Wrap<T> { value: T }
impl Kind for A { type Item = Int; }
impl Kind for B { type Item = Bool; }
impl<T: Kind<Item = Bool>> Wrap<T> { fn get(self: &Self) -> Int { 2 } }
impl<T: Kind<Item = Int>> Wrap<T> { fn get(self: &Self) -> Int { 1 } }
fn use_it() -> Int { Wrap { value: B {} }.get() }"#,
            true,
        ),
        (
            "inherent_disjoint_only_applicable",
            r#"trait Kind { type Item; }
struct A {}
struct B {}
struct Wrap<T> { value: T }
impl Kind for A { type Item = Int; }
impl Kind for B { type Item = Bool; }

impl<T: Kind<Item = Bool>> Wrap<T> { fn get(self: &Self) -> Int { 2 } }
fn use_it() -> Int { Wrap { value: B {} }.get() }"#,
            true,
        ),
    ];
    let mut observed = Vec::new();
    let mut diagnostics = Vec::new();
    for (name, source, _) in &cases {
        let result = check(source);
        observed.push(result.is_ok());
        diagnostics.push(format!("{name}: {result:?}"));
    }
    let expected = cases
        .iter()
        .map(|(_, _, accepted)| *accepted)
        .collect::<Vec<_>>();
    assert_eq!(observed, expected, "{}", diagnostics.join("\n"));
}

#[test]
fn verification_regression_joint_effect_minimum() {
    let cases = [
        (
            "effect_unique_joint_minimum",
            r#"fn console_callback() -> Unit with {console} {}
fn sequence<F: Fn + fn() -> Unit with {E1, E2}, G: Fn + fn() -> Unit with {E1}, effect E1, effect E2>(first: call F, second: call G) -> Unit with {E1, E2} {
    first(); second();
}
fn use_it() with {console} { sequence(console_callback, console_callback); }"#,
            true,
        ),
        (
            "effect_no_unique_minimum",
            r#"fn console_callback() -> Unit with {console} {}
fn sequence<F: Fn + fn() -> Unit with {E1, E2}, effect E1, effect E2>(first: call F) -> Unit with {E1, E2} { first(); }
fn use_it() with {console} { sequence(console_callback); }"#,
            false,
        ),
        (
            "effect_single_minimum",
            r#"fn console_callback() -> Unit with {console} {}
fn sequence<F: Fn + fn() -> Unit with {E1}, G: Fn + fn() -> Unit with {E1}, effect E1, effect E2>(first: call F, second: call G) -> Unit with {E1, E2} {
    first(); second();
}
fn use_it() with {console} { sequence(console_callback, console_callback); }"#,
            true,
        ),
    ];
    let mut observed = Vec::new();
    let mut diagnostics = Vec::new();
    for (name, source, _) in &cases {
        let result = check(source);
        observed.push(result.is_ok());
        diagnostics.push(format!("{name}: {result:?}"));
    }
    let expected = cases
        .iter()
        .map(|(_, _, accepted)| *accepted)
        .collect::<Vec<_>>();
    assert_eq!(observed, expected, "{}", diagnostics.join("\n"));
}

#[test]
fn verification_regression_method_scheme_requirements() {
    let cases = [
        (
            "method_scheme_own_requirement",
            r#"trait P {}
trait Run { fn run<T: P>(value: &T) -> Unit; }
struct A {}
impl Run for A { fn run<T: P>(value: &T) -> Unit {} }
fn expose() with {Run::run<A, Int>} {}"#,
            false,
        ),
        (
            "method_scheme_with_evidence",
            r#"trait P {}
trait Run { fn run<T: P>(value: &T) -> Unit; }
struct A {}
impl Run for A { fn run<T: P>(value: &T) -> Unit {} }
fn expose() with {Run::run<A, Int>} {}
impl P for Int {}"#,
            true,
        ),
        (
            "method_direct_own_requirement",
            r#"trait P {}
trait Run { fn run<T: P>(value: &T) -> Unit; }
struct A {}
impl Run for A { fn run<T: P>(value: &T) -> Unit {} }
fn expose() { A::run(1); }"#,
            false,
        ),
    ];
    let mut observed = Vec::new();
    let mut diagnostics = Vec::new();
    for (name, source, _) in &cases {
        let result = check(source);
        observed.push(result.is_ok());
        diagnostics.push(format!("{name}: {result:?}"));
    }
    let expected = cases
        .iter()
        .map(|(_, _, accepted)| *accepted)
        .collect::<Vec<_>>();
    assert_eq!(observed, expected, "{}", diagnostics.join("\n"));
}

#[test]
fn formal_scope_protection_preserves_distinct_parameters_across_method_recursion() {
    check(r#"
struct Wrap<T> { value: T }
impl<T> Wrap<T> {
    fn relay<U>(self: &Self, value: move U) -> U { bridge(self, value) }
}
fn bridge<A, B>(receiver: &Wrap<A>, value: move B) -> B { receiver.relay(value) }
fn use_it() -> Bool { Wrap { value: 1 }.relay(true) }
"#).expect("SCC correspondences can align separate callables while keeping each visible binder distinct");
}

#[test]
fn method_scheme_checks_its_callable_shape_without_emitting_input_effects() {
    let declaration = r#"
trait Run { fn run<F: Fn + fn(Int) -> Int with {E}, effect E>(callback: call F) -> Unit; }
struct A {}
impl Run for A { fn run<G: Fn + fn(Int) -> Int with {R}, effect R>(callback: call G) -> Unit {} }
"#;
    for (caller, accepted) in [
        (
            "fn allowed<G: Fn + fn(Int) -> Int with {console}>(callback: call G) with {Run::run<A, G, effect {console}>} {} fn observe<G: Fn + fn(Int) -> Int with {console}>(callback: call G) with {} { allowed(callback); }",
            true,
        ),
        (
            "fn wrong_type<G: Fn + fn(Bool) -> Bool with {}>(callback: call G) with {Run::run<A, G, effect {}>} {}",
            false,
        ),
        (
            "fn wrong_row<G: Fn + fn(Int) -> Int with {console}>(callback: call G) with {Run::run<A, G, effect {}>} {}",
            false,
        ),
    ] {
        let result = check(&format!("{declaration} {caller}"));
        assert_eq!(result.is_ok(), accepted, "{result:?}");
    }
    let cycle = error(
        r#"
trait Loop { fn run<F: Fn + fn() -> Unit with {Loop::run<Self, F>}>(callback: call F) -> Unit; }
struct A {}
impl Loop for A { fn run<G: Fn + fn() -> Unit with {Loop::run<Self, G>}>(callback: call G) -> Unit {} }
fn use_it<G: Fn + fn() -> Unit with {}>(callback: call G) with {Loop::run<A, G>} {}
"#,
    );
    assert!(cycle.message.contains("recursive"), "{cycle:?}");
}

#[test]
fn incomplete_inherent_applicability_cannot_fall_back_to_a_trait_method() {
    let failure = error(
        r#"
trait P {}
struct B {}
impl P for B where B: P {}
struct Wrap<T> { value: T }
impl<T: P> Wrap<T> { fn get(self: &Self) -> Int { 1 } }
trait Fallback { fn get(self: &Self) -> Int; }
impl<T> Fallback for Wrap<T> { fn get(self: &Self) -> Int { 2 } }
fn use_it() -> Int { Wrap { value: B {} }.get() }
"#,
    );
    assert!(failure.message.contains("cycle"), "{failure:?}");
}

#[test]
fn joint_effect_legality_uses_all_callback_lower_bounds() {
    check(r#"
fn first() -> Unit with {fail<Int>} {}
fn second() -> Unit with {fail<Bool>} {}
fn select<F: Fn + fn() -> Unit with {E1, E2}, G: Fn + fn() -> Unit with {E1, E3}, effect E1, effect E2, effect E3>(left: call F, right: call G) with {} {}
fn use_it() with {} { select(first, second); }
"#).expect("E1 stays empty; E2 and E3 separately carry the incompatible payloads");
}

#[test]
fn v2_regression_nested_projection_coherence() {
    let cases = [
        (
            "overlap_nested_projection",
            r#"trait Item { type Kind; }
struct K {}
impl Item for K { type Kind = Int; }
trait Tag { type Kind; }
trait Read { fn read(self: &Self) -> Int; }
struct Wrap<T> { value: T }
impl<T: Tag<Kind = (K::Kind, Bool)>> Read for Wrap<T> { fn read(self: &Self) -> Int { 1 } }
impl<T: Tag<Kind = (Int, Bool)>> Read for Wrap<T> { fn read(self: &Self) -> Int { 2 } }"#,
            false,
        ),
        (
            "overlap_control",
            r#"trait Tag { type Kind; }
trait Read { fn read(self: &Self) -> Int; }
struct Wrap<T> { value: T }
impl<T: Tag<Kind = (Int, Bool)>> Read for Wrap<T> { fn read(self: &Self) -> Int { 1 } }
impl<T: Tag<Kind = (Int, Bool)>> Read for Wrap<T> { fn read(self: &Self) -> Int { 2 } }"#,
            false,
        ),
        (
            "overlap_nested_projection_consumer",
            r#"trait Item { type Kind; }
struct K {}
impl Item for K { type Kind = Int; }
trait Tag { type Kind; }
trait Read { fn read(self: &Self) -> Int; }
struct Wrap<T> { value: T }
impl<T: Tag<Kind = (K::Kind, Bool)>> Read for Wrap<T> { fn read(self: &Self) -> Int { 1 } }
impl<T: Tag<Kind = (Int, Bool)>> Read for Wrap<T> { fn read(self: &Self) -> Int { 2 } }
struct V {}
impl Tag for V { type Kind = (Int, Bool); }
fn use_it() -> Int { Wrap { value: V {} }.read() }"#,
            false,
        ),
    ];
    let mut actual = Vec::new();
    let mut diagnostics = Vec::new();
    for (name, source, _) in &cases {
        let result = check(source);
        actual.push(result.is_ok());
        diagnostics.push(format!("{name}: {result:?}"));
    }
    let expected = cases
        .iter()
        .map(|(_, _, accepted)| *accepted)
        .collect::<Vec<_>>();
    assert_eq!(actual, expected, "{}", diagnostics.join("\n"));
}

#[test]
fn v2_regression_receiver_conformance() {
    let cases = [
        (
            "receiver_conformance",
            r#"trait Read { fn read(value: &Self) -> Int; }
struct A {}
impl Read for A { fn read(self: &Self) -> Int { 1 } }
fn generic<T: Read>(value: &T) -> Int { T::read(value) }
fn use_it() -> Int { generic(A {}) }"#,
            false,
        ),
        (
            "receiver_conformance_inverse",
            r#"trait Read { fn read(self: &Self) -> Int; }
struct A {}
impl Read for A { fn read(value: &Self) -> Int { 1 } }
fn generic<T: Read>(value: &T) -> Int { value.read() }
fn use_it() -> Int { generic(A {}) }"#,
            false,
        ),
        (
            "receiver_conformance_direct",
            r#"trait Read { fn read(value: &Self) -> Int; }
struct A {}
impl Read for A { fn read(self: &Self) -> Int { 1 } }
fn use_it() -> Int { A::read(A {}) }"#,
            false,
        ),
        (
            "receiver_conformance_positive",
            r#"trait Read { fn read(value: &Self) -> Int; }
struct A {}
impl Read for A { fn read(value: &Self) -> Int { 1 } }
fn generic<T: Read>(value: &T) -> Int { T::read(value) }
fn use_it() -> Int { generic(A {}) + A::read(A {}) }"#,
            true,
        ),
    ];
    let mut actual = Vec::new();
    let mut diagnostics = Vec::new();
    for (name, source, _) in &cases {
        let result = check(source);
        actual.push(result.is_ok());
        diagnostics.push(format!("{name}: {result:?}"));
    }
    let expected = cases
        .iter()
        .map(|(_, _, accepted)| *accepted)
        .collect::<Vec<_>>();
    assert_eq!(actual, expected, "{}", diagnostics.join("\n"));
}

#[test]
fn v2_regression_associated_assignment_formation() {
    let cases = [
        (
            "associated_formation",
            r#"trait P {}
struct Needs<T: P> { value: T }
trait Assoc { type Item; }
struct A {}
impl Assoc for A { type Item = Needs<Int>; }"#,
            false,
        ),
        (
            "associated_formation_control",
            r#"trait P {}
struct Needs<T: P> { value: T }
trait Assoc { type Item = Needs<Int>; }"#,
            false,
        ),
        (
            "associated_formation_positive",
            r#"trait P {}
impl P for Int {}
struct Needs<T: P> { value: T }
trait Assoc { type Item; }
struct A {}
impl Assoc for A { type Item = Needs<Int>; }"#,
            true,
        ),
    ];
    let mut actual = Vec::new();
    let mut diagnostics = Vec::new();
    for (name, source, _) in &cases {
        let result = check(source);
        actual.push(result.is_ok());
        diagnostics.push(format!("{name}: {result:?}"));
    }
    let expected = cases
        .iter()
        .map(|(_, _, accepted)| *accepted)
        .collect::<Vec<_>>();
    assert_eq!(actual, expected, "{}", diagnostics.join("\n"));
}

#[test]
fn v2_regression_inherent_projection_evidence() {
    let cases = [
        (
            "inherent_projection_control",
            r#"trait P {}
impl P for Int {}
struct A {}
impl A { type Item = Int; }
trait Mark {}
struct B {}
impl Mark for B where Int: P {}
fn need<T: Mark>(value: &T) {}
fn use_it() { need(B {}); }
fn direct(value: &A::Item) -> Int { value + 1 }"#,
            true,
        ),
        (
            "inherent_projection_evidence",
            r#"trait P {}
impl P for Int {}
struct A {}
impl A { type Item = Int; }
trait Mark {}
struct B {}
impl Mark for B where A::Item: P {}
fn need<T: Mark>(value: &T) {}
fn use_it() { need(B {}); }"#,
            true,
        ),
    ];
    let mut actual = Vec::new();
    let mut diagnostics = Vec::new();
    for (name, source, _) in &cases {
        let result = check(source);
        actual.push(result.is_ok());
        diagnostics.push(format!("{name}: {result:?}"));
    }
    let expected = cases
        .iter()
        .map(|(_, _, accepted)| *accepted)
        .collect::<Vec<_>>();
    assert_eq!(actual, expected, "{}", diagnostics.join("\n"));
}

#[test]
fn formation_conditions_cover_supported_declaration_owners() {
    let declarations = [
        "trait Outer<T> {} struct A {} impl Outer<Needs<Int>> for A {}",
        "trait Outer<T> {} trait Assoc { type Item: Outer<Needs<Int>>; }",
        "trait Outer<T> {} trait Sub: Outer<Needs<Int>> {}",
        "type Bad = Needs<Int>;",
        "effect E { fn get(value: Needs<Int>) -> Unit; }",
        "effect E<T: P> { fn get(value: T) -> T; } fn expose() with {E<Int>} {}",
        "effect alias Alias<T: P> = {console}; fn expose() with {Alias<Int>} {}",
        "effect alias Alias<T> = {console}; fn expose() with {Alias<Needs<Int>>} {}",
    ];
    let mut failures = Vec::new();
    for declaration in declarations {
        let source = format!("trait P {{}} struct Needs<T: P> {{ value: T }} {declaration}");
        match check(&source) {
            Err(error) if error.message.contains("no evidence for Int: P") => {}
            result => failures.push(format!("missing evidence: {declaration}: {result:?}")),
        }
        let positive = format!("{source} impl P for Int {{}}");
        if let Err(error) = check(&positive) {
            failures.push(format!("available evidence: {declaration}: {error:?}"));
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

#[test]
fn abstract_associated_inequality_is_an_incomplete_proof() {
    for source in [
        "trait P { type Item; } trait Tag { type Kind; } trait Read {} struct Wrap<T> { value: T } impl<T: P + Tag<Kind = T::Item>> Read for Wrap<T> {} impl<T: P + Tag<Kind = Int>> Read for Wrap<T> {}",
        "trait P { type Item; } trait Tag { type Kind; } struct Wrap<T> { value: T } impl<T: P> Tag for Wrap<T> { type Kind = T::Item; } fn need<T: Tag<Kind = Int>>(value: &T) {} fn use_it<T: P>(value: &Wrap<T>) { need(value); }",
    ] {
        let error = check(source).expect_err("abstract equality is not evidence of disjointness");
        assert!(error.message.contains("incomplete"), "{error:?}");
    }
    check("trait Item { type Kind; } struct K {} impl Item for K { type Kind = Int; } trait Tag { type Kind; } trait Read { fn read(self: &Self) -> Int; } struct Wrap<T> { value: T } impl<T: Tag<Kind = (K::Kind, Bool)>> Read for Wrap<T> { fn read(self: &Self) -> Int { 1 } } impl<T: Tag<Kind = (Bool, Bool)>> Read for Wrap<T> { fn read(self: &Self) -> Int { 2 } } struct A {} impl Tag for A { type Kind = (Int, Bool); } fn use_it() -> Int { Wrap { value: A {} }.read() }")
        .expect("fully reduced nested projection proves distinct associated values");
}

#[test]
fn effect_alias_formation_uses_the_completed_callable_input_domain() {
    check("trait P {} effect alias IO<T: P> = {console}; trait Run { fn run<T: P>(value: &T) with {IO<T>}; } struct A {} impl Run for A { fn run<U>(value: &U) with {IO<U>} {} } impl P for Int {} fn use_it() with {console} { A::run(1); }")
        .expect("impl aliases use the requirement inherited by conformance");
    check("trait P {} effect alias IO<T: P> = {console}; effect alias Outer<T: P> = {IO<T>}; fn use_it<T: P>(value: &T) with {Outer<T>} {}")
        .expect("transparent nested aliases retain generic givens");
}

#[test]
fn selection_reduces_associated_types_in_implementation_headers() {
    check("struct A {} impl A { type Item = Int; } trait P {} struct Wrap<T> { value: T } impl P for Wrap<A::Item> {} fn need<T: P>(value: &T) {} fn use_it() { need(Wrap { value: 1 }); }")
        .expect("evidence matches the reduced implementation target");
    check("struct A {} impl A { type Item = Int; } struct Wrap<T> { value: T } impl Wrap<A::Item> { fn get(self: &Self) -> Int { self.value + 1 } } fn use_it() -> Int { Wrap { value: 1 }.get() }")
        .expect("inherent selection matches the reduced implementation target");
    check("trait Item { type Kind; } struct A {} impl Item for A { type Kind = Int; } struct Pair<T, U> { first: T, second: U } trait P {} impl<T: Item> P for Pair<T, T::Kind> {} fn need<T: P>(value: &T) {} fn use_it() { need(Pair { first: A {}, second: 1 }); }")
        .expect("the same header mapping supplies projection actuals before reduction");
    let failure = error(
        "trait Item { type Kind; } struct A {} impl Item for A { type Kind = Int; } struct Pair<T, U> { first: T, second: U } trait P {} impl<T: Item> P for Pair<T, T::Kind> {} fn need<T: P>(value: &T) {} fn use_it() { need(Pair { first: A {}, second: true }); }",
    );
    assert!(failure.message.contains("no evidence"), "{failure:?}");
}

#[test]
fn handled_contract_actuals_prove_the_effect_owner_conditions() {
    let target = function_target("expose");
    let record = format!(
        r#"{{"target":{target},"set":{{"effect_upper":[{{"tag":"handled","effect":{{"library":{{"tag":"self"}},"path":["E"],"kind":"effect"}},"arguments":[{{"tag":"primitive","name":"Int"}}]}}]}}}}"#
    );
    for evidence in [false, true] {
        let source = format!(
            "pub trait P {{}} pub effect E<T: P> {{ fn get(value: T) -> T; }} fn expose() {{}} {}",
            if evidence { "impl P for Int {}" } else { "" }
        );
        let result = check_project(
            &project(&source),
            &BTreeMap::from([("app".to_owned(), APP)]),
            vec![contract(&document(&record))],
        );
        if evidence {
            result.expect("contract actual has the owner evidence");
        } else {
            let failure = result.expect_err("contract rows cannot skip owner requirements");
            assert!(
                failure.message.contains("no evidence for Int: P"),
                "{failure:?}"
            );
            assert!(
                matches!(failure.primary, Some(CheckOrigin::Contract { ref json_path, .. }) if json_path == "$.records[0].set.effect_upper"),
                "{failure:?}"
            );
        }
    }
}
