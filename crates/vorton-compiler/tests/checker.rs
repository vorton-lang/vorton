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

#[test]
fn joint_candidate_conditions_precede_method_and_projection_selection() {
    let prefix = "trait Mark {} trait Left { type Item; fn read(self: &Self) -> Bool; } trait Right { type Item; fn read(self: &Self) -> Int; } struct Box<T> { value: T } ";
    let right = "impl Right for Box<Int> { type Item = Int; fn read(self: &Self) -> Int { 1 } }";
    let call = "type IBox = Box<Int>; fn use_it() -> IBox::Item { Box { value: 1 }.read() }";
    for left in [
        "impl<T: Mark> Left for Box<T> { type Item = Bool; fn read(self: &Self) -> Bool { true } }",
        "impl<T> Left for Box<T> where T: Mark { type Item = Bool; fn read(self: &Self) -> Bool { true } }",
    ] {
        for implementations in [format!("{left} {right}"), format!("{right} {left}")] {
            check(&format!("{prefix} {implementations} {call}")).unwrap();
            assert!(
                error(&format!(
                    "{prefix} impl Mark for Int {{}} {implementations} {call}"
                ))
                .message
                .contains("ambiguous")
            );
        }
    }
    let conditional_inherent =
        "impl<T: Mark> Box<T> { type Item = Bool; fn read(self: &Self) -> Bool { true } }";
    check(&format!("{prefix} {conditional_inherent} {right} {call}")).unwrap();
    let diagnostic = error(&format!(
        "{prefix} impl Mark for Int {{}} {conditional_inherent} {right} fn use_it() -> Int {{ Box {{ value: 1 }}.read() }}"
    ));
    assert_eq!(
        diagnostic.kind,
        CheckDiagnosticKind::ReturnMismatch,
        "selected inherent method cannot fall back: {diagnostic:?}"
    );
    let binding = "trait Has { type Value; } impl Has for Int { type Value = Int; } impl<T: Has<Value = Bool>> Left for Box<T> { type Item = Bool; fn read(self: &Self) -> Bool { true } }";
    check(&format!("{prefix} {binding} {right} {call}")).unwrap();
    let impossible_binding = "trait Has { type Value; } impl Has for Int { type Value = (Int, Bool); } impl<T: Has, U> Left for Box<T> where T: Has<Value = (U, U)> { type Item = Bool; fn read(self: &Self) -> Bool { true } }";
    check(&format!("{prefix} {impossible_binding} {right} {call}")).unwrap();
    assert!(
        error(&format!(
            "{prefix} {} {right} {call}",
            impossible_binding.replace("(Int, Bool)", "(Int, Int)")
        ))
        .message
        .contains("ambiguous")
    );
    let projected_binding = "trait Has { type Value; } struct A {} impl Has for A { type Value = Int; } impl Has for Int { type Value = (Int, Int); } impl<T: Has, U> Left for Box<T> where T: Has<Value = (U, A::Value)> { type Item = Bool; fn read(self: &Self) -> Bool { true } }";
    check(&format!("{prefix} {projected_binding} {call}")).unwrap();
    for hidden in [
        "mod hidden { trait Hidden { type Item; } impl Hidden for super::Box<Int> { type Item = Bool; } }",
        "mod hidden { impl<T> super::Box<T> { type Item = Bool; } }",
    ] {
        check(&format!("{prefix} {hidden} {right} {call}")).unwrap();
    }
    for (source, reason) in [
        (
            "trait Right { fn read(self: &Self) -> Int with {}; } struct A {} impl Right for A { fn read(self: &Self) -> Int { 1 } } impl A { fn read(self: &Self) -> Int with {fs} { 1 } } fn f() -> Int with {} { A {}.read() }",
            "exceeds",
        ),
        (
            "trait Right { fn read(self: &Self) -> Int with {}; } struct A {} impl Right for A { fn read(self: &Self) -> Int { 1 } } impl A { fn read(self: move Self) -> Int { 1 } } fn f(value: &A) -> Int { value.read() }",
            "borrowed",
        ),
    ] {
        let diagnostic = error(source);
        assert!(diagnostic.message.contains(reason), "{diagnostic:?}");
    }
}

#[test]
fn joint_candidate_unknown_cycle_and_growth_are_not_negative_evidence() {
    let prefix = "trait Mark {} trait Left { type Item; fn read(self: &Self) -> Bool; } trait Right { type Item; fn read(self: &Self) -> Int; } struct Box<T> { value: T } impl<T: Mark> Left for Box<T> { type Item = Bool; fn read(self: &Self) -> Bool { true } } impl Right for Box<Int> { type Item = Int; fn read(self: &Self) -> Int { 1 } } ";
    for (rule, reason) in [
        ("impl<T: Mark> Mark for T {}", "cycle"),
        (
            "struct Grow<T> { value: T } impl<T> Mark for T where Grow<T>: Mark {}",
            "logical work limit",
        ),
    ] {
        for consumer in [
            "fn call() -> Int { Box { value: 1 }.read() }",
            "type IBox = Box<Int>; fn associated() -> IBox::Item { 1 }",
        ] {
            let source = format!("{prefix} {rule} {consumer}");
            std::thread::Builder::new()
                .stack_size(1024 * 1024)
                .spawn(move || {
                    let diagnostic = error(&source);
                    assert!(diagnostic.message.contains(reason), "{diagnostic:?}");
                })
                .unwrap()
                .join()
                .unwrap();
        }
    }
    let diagnostic = error(
        "trait Mark {} trait Left { fn read(self: &Self) -> Int; } trait Right { fn read(self: &Self) -> Int; } struct Box<T> { value: T } impl<T: Mark> Left for Box<T> { fn read(self: &Self) -> Int { 1 } } impl<T> Right for Box<T> { fn read(self: &Self) -> Int { 2 } } fn generic<T>(value: &Box<T>) -> Int { value.read() }",
    );
    assert_eq!(diagnostic.kind, CheckDiagnosticKind::TypeMismatch);
    assert!(
        diagnostic.message.contains("Mark"),
        "unknown condition must not become false: {diagnostic:?}"
    );
}

#[test]
fn joint_handled_identity_uses_closed_projection_actuals() {
    let prefix = "trait Has { type Item; } struct A {} impl Has for A { type Item = Int; } effect Signal<T> { fn send(value: &T) -> Unit; } ";
    for source in [
        "fn f() with {Signal<A::Item>} { Signal.send(1); }",
        "type Item = A::Item; fn f() with {Signal<Item>} { Signal.send(1); }",
        "effect alias Row = {Signal<A::Item>}; fn f() with {Row} { Signal.send(1); }",
        "fn f<T: Has<Item = Int>>(owner: &T) with {Signal<T::Item>} { Signal.send(1); }",
        "mod bounded requires {super::Signal<super::A::Item>} { fn f() { super::Signal.send(1); } }",
    ] {
        check(&format!("{prefix} {source}")).unwrap();
    }
    let diagnostic = error(&format!(
        "{prefix} fn f<T: Has>(owner: &T) with {{Signal<T::Item>}} {{}}"
    ));
    assert!(
        diagnostic.message.contains("closed concrete"),
        "{diagnostic:?}"
    );
}

#[test]
fn joint_effect_operations_use_actual_public_surface_before_type_erasure() {
    for source in [
        "struct Hidden {} pub effect Signal { fn receive() -> Hidden; }",
        "struct Hidden {} pub effect Signal { fn receive(value: &Hidden) -> Unit; }",
        "struct Hidden {} pub effect Signal { fn receive() -> (Int, Hidden); }",
        "type Hidden = Int; pub effect Signal { fn receive() -> Hidden; }",
        "pub struct A {} impl A { type Hidden = Int; } pub effect Signal { fn receive() -> A::Hidden; }",
        "pub use inside::Signal; mod inside { struct Hidden {} pub effect Signal { fn receive() -> Hidden; } }",
    ] {
        let diagnostic = error(source);
        assert_eq!(
            diagnostic.kind,
            CheckDiagnosticKind::TypeMismatch,
            "{diagnostic:?}"
        );
        assert!(diagnostic.message.contains("private"), "{diagnostic:?}");
    }
    for source in [
        "pub struct Visible {} pub effect Signal { fn receive() -> Visible; }",
        "mod inside { pub effect Signal { fn receive() -> Unit; } }",
        "mod inside { struct Hidden {} pub effect Signal { fn receive() -> Hidden; } }",
        "pub use inside::Signal; mod inside { pub effect Signal { fn receive() -> Unit; } }",
        "pub mod inside { pub effect Signal { fn receive() -> Unit; } }",
        "struct Hidden {} effect Signal { fn receive() -> Hidden; }",
    ] {
        check(source).unwrap();
    }
}

#[test]
fn joint_contract_rows_compare_normalized_type_operands() {
    let owners = BTreeMap::from([("app".to_owned(), APP)]);
    let prefix = "trait Has { type Item; } struct A {} impl Has for A { type Item = Int; } effect Signal<T> { fn send(value: &T) -> Unit; } ";
    let projection = r#"{"tag":"associated","base":{"tag":"nominal","declaration":{"library":{"tag":"self"},"path":["A"],"kind":"struct"},"arguments":[]},"trait":{"trait":{"library":{"tag":"self"},"path":["Has"],"kind":"trait"},"arguments":[],"associated_bindings":[]},"name":"Item"}"#;
    let integer = r#"{"tag":"primitive","name":"Int"}"#;
    let selected = format!(
        r#"{{"target":{},"set":{{"effect_upper":[{{"tag":"fail","payload":{projection}}}]}}}}"#,
        function_target("f")
    );
    let concrete = format!(
        r#"{{"target":{},"set":{{"effect_upper":[{{"tag":"fail","payload":{integer}}}]}}}}"#,
        function_target("f")
    );
    for source in [
        "fn f() {}",
        "fn f() with {fail<Int>} {}",
        "fn f() with {fail<A::Item>} {}",
    ] {
        for records in [
            selected.clone(),
            format!("{selected},{concrete}"),
            format!("{concrete},{selected}"),
        ] {
            check_project(
                &project(&format!("{prefix} {source}")),
                &owners,
                vec![contract(&document(&records))],
            )
            .unwrap();
        }
    }
    let conflicting = concrete.replace("Int", "Bool");
    let diagnostic = check_project(
        &project(&format!("{prefix} fn f() {{}}")),
        &owners,
        vec![contract(&document(&format!("{selected},{conflicting}")))],
    )
    .unwrap_err();
    assert_eq!(diagnostic.kind, CheckDiagnosticKind::ContractConflict);
    let handled = format!(
        r#"{{"target":{},"set":{{"effect_upper":[{{"tag":"handled","effect":{{"library":{{"tag":"self"}},"path":["Signal"],"kind":"effect"}},"arguments":[{projection}]}}]}}}}"#,
        function_target("f")
    );
    check_project(
        &project(&format!("{prefix} fn f() {{ Signal.send(1); }}")),
        &owners,
        vec![contract(&document(&handled))],
    )
    .unwrap();
    let formal = function_formal("f", 0);
    let callback_record = |payload| {
        format!(
            r#"{{"target":{},"type_parameters":["F"],"set":{{"generic_requirements":[{{"tag":"trait","subject":{formal},"bound":{{"trait":{{"library":{{"tag":"dependency","alias":"vorton_core"}},"path":["Fn"],"kind":"trait"}},"arguments":[],"associated_bindings":[]}}}},{{"tag":"callable_shape","subject":{formal},"shape":{{"parameters":[],"result":{{"tag":"primitive","name":"Unit"}},"effect_upper":[{{"tag":"fail","payload":{payload}}}]}}}}]}}}}"#,
            function_target("f")
        )
    };
    for source in [
        "fn f<F>(callback: call F) {}",
        "fn f<F: Fn + fn() -> Unit with {fail<A::Item>}>(callback: call F) {}",
    ] {
        let records = format!(
            "{},{}",
            callback_record(projection),
            callback_record(integer)
        );
        check_project(
            &project(&format!("{prefix} {source}")),
            &owners,
            vec![contract(&document(&records))],
        )
        .unwrap();
    }
}

#[test]
fn joint_inputs_prove_formation_before_erasing_each_source_carrier() {
    let prefix = "trait Mark {} struct Limited<T: Mark> { value: T } ";
    for carrier in [
        "trait Out { type Item = Limited<Int>; }",
        "trait Out { type Item; } struct N {} impl Out for N { type Item = Limited<Int>; }",
        "trait Accept<T> {} trait Out { type Item: Accept<Limited<Int>>; }",
        "trait P {} impl P for Limited<Int> {}",
        "trait Accept<T> {} fn f<U: Accept<Limited<Int>>>(value: &U) {}",
        "trait Host { fn f<F: Fn + fn(Limited<Int>) -> Unit with {}>(self: &Self, callback: call F); }",
        "trait Host { fn f<F: Fn + fn() -> Limited<Int> with {}>(self: &Self, callback: call F); }",
        "trait Host { fn f(self: &Self) with {fail<Limited<Int>>}; }",
        "fn f<F: Fn + fn() -> Unit with {fail<Limited<Int>>}>(callback: call F) {}",
        "effect Signal<T> { fn ping() -> Unit; } fn f() with {Signal<Limited<Int>>} {}",
        "effect alias Gone<T> = {}; fn f() with {Gone<Limited<Int>>} {}",
        "effect alias Gone<T> = {}; effect alias Outer = {Gone<Limited<Int>>};",
        "effect alias Gone<T> = {}; mod empty requires {super::Gone<super::Limited<Int>>} {}",
        "fn f<T>(value: move T) -> T { value } fn bad() { let x: Limited<Int> = f(Limited { value: 1 }); }",
        "trait Tick { fn tick(self: &Self) with {}; } impl<T: Mark> Tick for Limited<T> { fn tick(self: &Self) {} } fn f() with {Tick::tick<Limited<Int>>} {}",
    ] {
        let source = format!("{prefix}{carrier}");
        let diagnostic = error(&source);
        assert_eq!(
            diagnostic.kind,
            CheckDiagnosticKind::TypeMismatch,
            "{carrier}: {diagnostic:?}"
        );
        assert!(
            diagnostic.message.contains("Mark"),
            "{carrier}: {diagnostic:?}"
        );
        check(&format!("{prefix} impl Mark for Int {{}} {carrier}"))
            .unwrap_or_else(|error| panic!("formed control {carrier}: {error:?}"));
    }
    let diagnostic =
        error("trait Mark {} trait Accept<T: Mark> {} fn invalid<U: Accept<Int>>(value: &U) {}");
    assert!(
        diagnostic.message.contains("Mark"),
        "a requested formation condition is not a given: {diagnostic:?}"
    );
}

#[test]
fn joint_inputs_compound_givens_fix_the_dictionary_before_inherent_lookup() {
    for subject in ["(T, Int)", "Holder<T>", "T::Item"] {
        let source = format!(
            r#"
trait Read {{ fn read(self: &Self) -> Int with {{}}; }}
trait Has {{ type Item; }}
struct Holder<T> {{ value: T }}
impl<T> Holder<T> {{ fn read(self: &Self) -> Bool {{ true }} }}
fn helper<U: Read>(value: &U) -> Int with {{}} {{ value.read() }}
trait Use<T: Has> {{
    fn direct(self: &Self, value: &{subject}) -> Int with {{}};
    fn indirect(self: &Self, value: &{subject}) -> Int with {{}};
}}
struct Carrier<T> {{ value: T }}
impl<T: Has> Use<T> for Carrier<T> where {subject}: Read {{
    fn direct(self: &Self, value: &{subject}) -> Int with {{}} {{ value.read() }}
    fn indirect(self: &Self, value: &{subject}) -> Int with {{}} {{ helper(value) }}
}}
"#
        );
        check(&source).unwrap_or_else(|error| panic!("{subject}: {error:?}"));
    }
    let source = r#"
trait Read<T> { fn read(self: &Self) -> Int; }
fn ambiguous<U: Read<Int> + Read<Bool>>(value: &U) -> Int { value.read() }
"#;
    assert!(error(source).message.contains("ambiguous"));
}

#[test]
fn joint_inputs_inherent_associated_types_keep_actuals_conditions_and_privacy() {
    check("struct N {} impl N { type Item = Int; } fn value() -> N::Item { 1 }").unwrap();
    check("pub struct N {} impl N { pub type Item = Int; } pub fn value() -> N::Item { 1 }")
        .unwrap();
    check("struct Box<T> { value: T } impl<T> Box<T> { type Item = T; fn identity(value: move Self::Item) -> Self::Item { value } } type IntBox = Box<Int>; fn value() -> IntBox::Item { 1 }").unwrap();
    for source in [
        "struct N {} impl N { type Item = Self::Item; } fn value() -> N::Item { 1 }",
        "mod hidden { pub struct N {} impl N { type Item = Int; } } fn value() -> hidden::N::Item { 1 }",
        "struct N {} impl N { type Item = Int; } fn value() -> N::Item<Int> { 1 }",
        "pub struct N {} impl N { type Item = Int; } pub fn value() -> N::Item { 1 }",
        "pub struct N {} trait Hidden { type Item; } impl Hidden for N { type Item = Int; } pub fn value() -> N::Item { 1 }",
    ] {
        assert!(check(source).is_err(), "{source}");
    }
    let source = "trait Read { fn read(self: &Self) -> Int; } struct N {} impl Read for N { fn read(self: &Self) -> Int { 1 } } mod hidden { trait Secret { fn read(self: &Self) -> Bool; } impl Secret for super::N { fn read(self: &Self) -> Bool { true } } } fn read() -> Int { N {}.read() }";
    check(source).unwrap();
    assert!(
        error(&source.replace("impl Read for N { fn read(self: &Self) -> Int { 1 } }", ""))
            .message
            .contains("private")
    );
}

#[test]
fn joint_inputs_json_type_operands_close_before_row_reduction() {
    let owners = BTreeMap::from([("app".to_owned(), APP)]);
    let limited = r#"{"tag":"nominal","declaration":{"library":{"tag":"self"},"path":["Limited"],"kind":"struct"},"arguments":[{"tag":"primitive","name":"Int"}]}"#;
    for term in [
        format!(r#"{{"tag":"fail","payload":{limited}}}"#),
        format!(r#"{{"tag":"full_destruction","type":{limited}}}"#),
        format!(
            r#"{{"tag":"handled","effect":{{"library":{{"tag":"self"}},"path":["Signal"],"kind":"effect"}},"arguments":[{limited}]}}"#
        ),
    ] {
        let record = format!(
            r#"{{"target":{},"set":{{"effect_upper":[{term}]}}}}"#,
            function_target("f")
        );
        let source = "trait Mark {} struct Limited<T: Mark> { value: T } effect Signal<T> { fn ping() -> Unit; } fn f() {}";
        let document = document(&record);
        let diagnostic =
            check_project(&project(source), &owners, vec![contract(&document)]).unwrap_err();
        assert_eq!(
            diagnostic.kind,
            CheckDiagnosticKind::TypeMismatch,
            "{term}: {diagnostic:?}"
        );
        assert!(diagnostic.message.contains("Mark"), "{diagnostic:?}");
        assert!(
            matches!(diagnostic.primary, Some(CheckOrigin::Contract { json_path, .. }) if json_path == "$.records[0].set.effect_upper[0]")
        );
        check_project(
            &project(&format!("impl Mark for Int {{}} {source}")),
            &owners,
            vec![contract(&document)],
        )
        .unwrap();
    }
    let formal = function_formal("f", 0);
    let callable = format!(
        r#"{{"tag":"trait","subject":{formal},"bound":{{"trait":{{"library":{{"tag":"dependency","alias":"vorton_core"}},"path":["Fn"],"kind":"trait"}},"arguments":[],"associated_bindings":[]}}}}"#
    );
    let unit = r#"{"tag":"primitive","name":"Unit"}"#;
    for (parameter, result, row) in [
        (limited, unit, "".to_owned()),
        (unit, limited, "".to_owned()),
        (
            unit,
            unit,
            format!(r#"{{"tag":"fail","payload":{limited}}}"#),
        ),
    ] {
        let shape = format!(
            r#"{{"tag":"callable_shape","subject":{formal},"shape":{{"parameters":[{{"type":{parameter},"mode":{{"tag":"fixed","mode":"borrow"}},"escape":"may_escape"}}],"result":{result},"effect_upper":[{row}]}}}}"#
        );
        let record = format!(
            r#"{{"target":{},"type_parameters":["F"],"set":{{"generic_requirements":[{callable},{shape}]}}}}"#,
            function_target("f")
        );
        let source =
            "trait Mark {} struct Limited<T: Mark> { value: T } fn f<F>(callback: call F) {}";
        let selected = contract(&document(&record));
        let diagnostic = check_project(&project(source), &owners, vec![selected]).unwrap_err();
        assert_eq!(
            diagnostic.kind,
            CheckDiagnosticKind::TypeMismatch,
            "{diagnostic:?}"
        );
        assert!(diagnostic.message.contains("Mark"), "{diagnostic:?}");
        assert!(matches!(
            diagnostic.primary,
            Some(CheckOrigin::Contract { .. })
        ));
        check_project(
            &project(&format!("impl Mark for Int {{}} {source}")),
            &owners,
            vec![contract(&document(&record))],
        )
        .unwrap();
    }
}

#[test]
fn joint_inputs_handled_contracts_use_dependency_and_reexport_bindings() {
    let owners = BTreeMap::from([("app".to_owned(), APP)]);
    for (library, path) in [
        (r#"{"tag":"self"}"#, "Alias"),
        (r#"{"tag":"dependency","alias":"dep"}"#, "Signal"),
    ] {
        let mut sources = project("pub use dep::Signal as Alias; fn f() { Alias.ping(); }");
        sources
            .libraries
            .get_mut(&APP)
            .unwrap()
            .dependencies
            .insert("dep".to_owned(), DEPENDENCY);
        sources.libraries.insert(
            DEPENDENCY,
            LibrarySources {
                root: "pub effect Signal { fn ping() -> Unit; }".to_owned(),
                modules: BTreeMap::new(),
                dependencies: BTreeMap::from([("vorton_core".to_owned(), CORE)]),
            },
        );
        let record = format!(
            r#"{{"target":{},"set":{{"effect_upper":[{{"tag":"handled","effect":{{"library":{library},"path":["{path}"],"kind":"effect"}},"arguments":[]}}]}}}}"#,
            function_target("f")
        );
        check_project(&sources, &owners, vec![contract(&document(&record))]).unwrap();
    }
}

#[test]
fn joint_inputs_handled_binding_and_main_guard_use_exact_effects() {
    let owners = BTreeMap::from([("app".to_owned(), APP)]);
    let handled = r#"{"tag":"handled","effect":{"library":{"tag":"self"},"path":["Signal"],"kind":"effect"},"arguments":[]}"#;
    let method = r#"{"tag":"method_application","method":{"tag":"trait_member","kind":"method","owner":{"library":{"tag":"self"},"path":["Tick"],"kind":"trait"},"name":"tick"},"self":{"tag":"primitive","name":"Int"},"trait_type_arguments":[],"method_type_arguments":[],"effect_arguments":[]}"#;
    for visibility in ["", "pub "] {
        let source = format!(
            "{visibility}effect Signal {{ fn ping() -> Unit; }} fn f() {{ Signal.ping(); }}"
        );
        let record = format!(
            r#"{{"target":{},"set":{{"effect_upper":[{handled}]}}}}"#,
            function_target("f")
        );
        check_project(
            &project(&source),
            &owners,
            vec![contract(&document(&record))],
        )
        .unwrap();
    }
    let prefix = "effect Signal { fn ping() -> Unit; } trait Tick { fn tick(self: &Self) -> Unit; } impl Tick for Int { fn tick(self: &Self) -> Unit with {Signal} { Signal.ping() } }";
    for upper in ["", " with {Tick::tick<Int>}"] {
        let diagnostic = error(&format!("{prefix} fn main() -> Unit{upper} {{ 1.tick() }}"));
        assert!(
            diagnostic.message.contains("unhandled user effect"),
            "{diagnostic:?}"
        );
    }
    let record = format!(
        r#"{{"target":{},"set":{{"effect_upper":[{method}]}}}}"#,
        function_target("main")
    );
    let diagnostic = check_project(
        &project(&format!("{prefix} fn main() {{ 1.tick(); }}")),
        &owners,
        vec![contract(&document(&record))],
    )
    .unwrap_err();
    assert!(
        diagnostic.message.contains("unhandled user effect"),
        "{diagnostic:?}"
    );
    check(&format!(
        "{prefix} struct N {{}} impl N {{ fn main(self: &Self) {{ 1.tick(); }} }}"
    ))
    .unwrap();
}

#[test]
fn joint_inputs_projection_actuals_normalize_in_shapes_rows_and_conformance() {
    check(r#"
trait Has { type Item; }
struct N {}
impl Has for N { type Item = Int; }
fn apply<T: Has, F: Fn + fn(T::Item) -> Unit with {fail<T::Item>}>(owner: &T, callback: call F, value: &T::Item) -> Unit with {fail<T::Item>} { callback(value); }
fn actual(value: &Int) -> Unit with {fail<Int>} {}
fn use_it() -> Unit with {fail<Int>} { apply(N {}, actual, 1); }
"#).unwrap();
    check(r#"
trait Has { type Item; }
struct N {}
impl Has for N { type Item = Int; }
trait Apply<T: Has> { fn apply<F: Fn + fn(T::Item) -> Unit with {fail<T::Item>}>(self: &Self, callback: call F, value: &T::Item) -> Unit with {fail<T::Item>}; }
struct X {}
impl Apply<N> for X { fn apply<F: Fn + fn(Int) -> Unit with {fail<Int>}>(self: &Self, callback: call F, value: &Int) -> Unit with {fail<Int>} { callback(value); } }
"#).unwrap();
    check(
        r#"
trait Has { type Item; }
struct N {}
impl Has for N { type Item = Int; }
effect alias Payload<T: Has> = {fail<T::Item>};
fn f<T: Has>(owner: &T) -> Unit with {Payload<T>} {}
fn use_it() -> Unit with {fail<Int>} { f(N {}); }
"#,
    )
    .unwrap();
}

#[test]
fn joint_finite_evidence_can_grow_before_it_closes() {
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
    .unwrap();
}

#[test]
fn joint_method_selection_and_owner_actuals_are_shared() {
    check(
        r#"
trait Read { fn read(self: &Self) -> Int; }
struct Box<T> { value: T }
impl<T> Box<T> { fn keep<U>(self: &Self, other: move U) -> U { other } }
impl Read for Int { fn read(self: &Self) -> Int { self } }
fn through<T: Read>(value: &T) -> Int { value.read() }
fn use_methods() -> Int {
    let b = Box { value: true };
    through(b.keep(7))
}
"#,
    )
    .unwrap();
}

#[test]
fn joint_associated_defaults_bindings_and_method_recursion() {
    check(
        r#"
trait Value { type Item = Int; fn get(self: &Self) -> Self::Item; }
struct N {}
impl Value for N { fn get(self: &Self) -> Int { 7 } }
impl N {
    fn make() -> N { N {} }
    fn step(self: &Self, end: Bool) -> Int { if end { 1 } else { recurse(self) } }
}
fn recurse(value: &N) -> Int { value.step(true) }
fn fetch<T: Value<Item = Int>>(value: &T) -> Int { value.get() }
fn use_all() -> Int { fetch(N::make()) + recurse(N {}) }
"#,
    )
    .unwrap();
    let diagnostic =
        error("trait Step { type Next; } struct A {} impl Step for A { type Next = Self::Next; }");
    assert!(diagnostic.message.contains("cycle"), "{diagnostic:?}");
}

#[test]
fn joint_evidence_cycles_and_growth_have_distinct_reasons() {
    let cycle = error(
        "trait P {} struct A {} impl<T: P> P for T {} fn need<T: P>(x: &T) {} fn use_it() { need(A {}); }",
    );
    assert!(cycle.message.contains("cycle"), "{cycle:?}");
    let growth = error(
        "trait P {} struct A {} struct Wrap<T> { value: T } impl<T> P for T where Wrap<T>: P {} fn need<T: P>(x: &T) {} fn use_it() { need(A {}); }",
    );
    assert!(growth.message.contains("incomplete solve"), "{growth:?}");
    assert!(!growth.message.contains("no impl"));
    println!("growth work evidence: {}", growth.message);
}

#[test]
fn joint_real_effect_sources_propagate_and_unsafe_only_discharges_unsafe() {
    check(
        r#"
effect Signal { fn ping() -> Int; }
effect alias Host = {console, fs, process};
fn broad() -> Unit with {Host, mut, unsafe, fail<Int>} {}
fn signal() -> Int with {Signal} { Signal.ping() }
fn abort() -> Never with {fail<Int>} { fail.raise(1) }
mod authorized requires {unsafe, console, fs, process, mut, fail<Int>} {
    use super::broad;
    fn clean() -> Unit with {console, fs, process, mut, fail<Int>} { unsafe { broad() } }
}
"#,
    )
    .unwrap();
    for source in [
        "fn broad() with {fs} {} fn wrong() with {} { broad(); }",
        "fn a() with {fail<Int>} {} fn b() with {fail<Bool>} {} fn c() { a(); b(); }",
        "fn raw() with {unsafe} {} fn wrong() { unsafe { raw() } }",
        "effect Signal { fn ping() -> Unit; } fn main() { Signal.ping(); }",
        "trait Cycle { fn run(self: &Self) with {Cycle::run<Self>}; }",
    ] {
        let diagnostic = error(source);
        assert_eq!(
            diagnostic.kind,
            CheckDiagnosticKind::TypeMismatch,
            "{diagnostic:?}"
        );
    }
}

#[test]
fn joint_generic_failure_cleanup_instantiates_with_the_selected_method() {
    check(
        r#"
trait Tick { fn tick(self: &Self) -> Int; }
struct Runner {}
impl Tick for Runner { fn tick(self: &Self) -> Int with {} { 1 } }
fn keep<T, R: Tick>(value: move T, runner: &R) -> T { runner.tick(); value }
fn pass<T>(value: move T, n: Int) -> T { value }
fn staged<T, R: Tick>(value: move T, runner: &R) -> T { pass(value, runner.tick()) }
fn pure_use() -> Int with {} { keep(1, Runner {}) + staged(2, Runner {}) }
fn discard<T>(value: move T) {}
fn concrete_drop() with {} { discard(Runner {}); }
"#,
    )
    .unwrap();
    let diagnostic = error("fn discard<T>(value: move T) with {} {}");
    assert_eq!(
        diagnostic.kind,
        CheckDiagnosticKind::TypeMismatch,
        "{diagnostic:?}"
    );
}

#[test]
fn joint_shared_callbacks_compute_minimum_effect_actuals() {
    check(r#"
fn pure() -> Unit with {} {}
fn file() -> Unit with {fs} {}
fn print() -> Unit with {console} {}
fn both<F: Fn + fn() -> Unit with {E}, G: Fn + fn() -> Unit with {E}, effect E>(first: call F, second: call G) -> Unit with {E} { first(); second(); }
fn forwarding<F: Fn + fn() -> Unit with {E}, effect E>(callback: call F) -> Unit with {E} { both(callback, callback) }
fn empty() -> Unit with {} { both(pure, pure); }
fn combined() -> Unit with {fs, console} { let alias = file; both(alias, print); forwarding(alias); }
"#).unwrap();
    let conflict = error(
        "fn a() -> Unit with {fail<Int>} {} fn b() -> Unit with {fail<Bool>} {} fn both<F: Fn + fn() -> Unit with {E}, G: Fn + fn() -> Unit with {E}, effect E>(f: call F, g: call G) with {E} { f(); g(); } fn use_it() { both(a, b); }",
    );
    assert!(
        conflict.message.contains("payload conflict"),
        "{conflict:?}"
    );
    let open = error(
        "fn open() -> Unit {} fn use_it<F: Fn + fn() -> Unit>(f: call F) { f(); } fn invoke() { use_it(open); }",
    );
    assert!(open.message.contains("closed"), "{open:?}");
}

#[test]
fn joint_implicit_callback_rows_are_independent_and_constrained_before_generalization() {
    check(r#"
trait Pipe { fn run<F: Fn + fn() -> Unit, G: Fn + fn() -> Unit>(self: &Self, first: call F, second: call G) -> Unit; }
struct Runner {}
impl Pipe for Runner { fn run<A, B>(self: &Self, first: call A, second: call B) -> Unit { second(); } }
fn pure() -> Unit with {} {}
fn file() -> Unit with {fs} {}
fn use_pipe() -> Unit with {} { Runner {}.run(file, pure); }
fn pure_only<F: Fn + fn() -> Unit>(callback: call F) -> Unit with {} { callback(); }
fn inferred<F: Fn + fn() -> Unit>(callback: call F) -> Unit { pure_only(callback); }
fn ignore<F: Fn + fn() -> Unit>(callback: call F) -> Unit with {} {}
fn all() -> Unit with {} { pure_only(pure); inferred(pure); ignore(file); }
"#).unwrap();
    let diagnostic = error(
        "fn file() -> Unit with {fs} {} fn pure_only<F: Fn + fn() -> Unit>(f: call F) with {} { f(); } fn wrong() { pure_only(file); }",
    );
    assert_eq!(
        diagnostic.kind,
        CheckDiagnosticKind::TypeMismatch,
        "{diagnostic:?}"
    );
}

#[test]
fn joint_callable_contracts_bind_receiver_outer_and_method_formals() {
    let implementation = r#"{"library":{"tag":"self"},"type_parameter_count":1,"target":{"tag":"nominal","declaration":{"library":{"tag":"self"},"path":["Box"],"kind":"struct"},"arguments":[{"tag":"local_type_parameter","index":0}]}}"#;
    let target = format!(
        r#"{{"tag":"impl_member","owner":{implementation},"kind":"method","name":"wrap"}}"#
    );
    let outer = format!(
        r#"{{"tag":"formal","formal":{{"owner":{{"tag":"impl","implementation":{implementation}}},"binder":"impl","kind":"type","index":0}}}}"#
    );
    let self_type = format!(
        r#"{{"tag":"self_type","owner":{{"tag":"impl","implementation":{implementation}}}}}"#
    );
    let record = format!(
        r#"{{"target":{target},"type_parameters":[],"set":{{"parameter_types":[{{"parameter":{{"tag":"receiver"}},"type":{self_type}}},{{"parameter":{{"tag":"position","index":0}},"type":{outer}}}],"return_type":{self_type},"effect_upper":[]}}}}"#
    );
    let source = "struct Box<T> { value: T } impl<T> Box<T> { fn wrap(self: &Self, value: move T) -> Box<T> { Box { value } } } fn use_it() -> Box<Int> { Box { value: 1 }.wrap(2) }";
    check_project(
        &project(source),
        &BTreeMap::from([("app".to_owned(), APP)]),
        vec![contract(&document(&record))],
    )
    .unwrap();
    let ambiguous = format!("{source} impl<T> Box<T> {{ fn other(self: &Self) {{}} }}");
    let diagnostic = check_project(
        &project(&ambiguous),
        &BTreeMap::from([("app".to_owned(), APP)]),
        vec![contract(&document(&record))],
    )
    .unwrap_err();
    assert!(diagnostic.message.contains("ambiguous"), "{diagnostic:?}");
}

#[test]
fn joint_contract_requirements_effects_and_selected_call_enter_before_the_body() {
    let target = function_target("invoke");
    let formal = function_formal("invoke", 0);
    let record = format!(
        r#"{{"target":{target},"type_parameters":["Callback"],"set":{{"parameter_modes":[{{"parameter":{{"tag":"position","index":0}},"mode":{{"tag":"callable_use","callable":{formal}}}}}],"generic_requirements":[{{"tag":"trait","subject":{formal},"bound":{{"trait":{{"library":{{"tag":"dependency","alias":"vorton_core"}},"path":["Fn"],"kind":"trait"}},"arguments":[],"associated_bindings":[]}}}},{{"tag":"callable_shape","subject":{formal},"shape":{{"parameters":[],"result":{{"tag":"primitive","name":"Unit"}}}}}}],"effect_upper":[{{"tag":"selected_call","callable":{formal}}}]}}}}"#
    );
    let source = "fn invoke<F>(callback: &F) -> Unit { callback(); } fn file() -> Unit with {fs} {} fn use_it() -> Unit with {fs} { invoke(file); }";
    check_project(
        &project(source),
        &BTreeMap::from([("app".to_owned(), APP)]),
        vec![contract(&document(&record))],
    )
    .unwrap();
    let empty = format!(
        r#"{{"target":{},"type_parameters":[],"set":{{"effect_upper":[]}}}}"#,
        function_target("wrong")
    );
    let diagnostic = check_project(
        &project("fn file() with {fs} {} fn wrong() { file(); }"),
        &BTreeMap::from([("app".to_owned(), APP)]),
        vec![contract(&document(&empty))],
    )
    .unwrap_err();
    assert_eq!(
        diagnostic.primary,
        Some(CheckOrigin::Contract {
            document_index: 0,
            json_path: "$.records[0].set.effect_upper".to_owned()
        })
    );
    let discard_formal = function_formal("discard", 0);
    let discard = format!(
        r#"{{"target":{},"type_parameters":["T"],"set":{{"effect_upper":[{{"tag":"full_destruction","type":{discard_formal}}}],"generic_requirements":[]}}}}"#,
        function_target("discard")
    );
    check_project(
        &project("fn discard<T>(value: move T) {} fn use_it() with {} { discard(1); }"),
        &BTreeMap::from([("app".to_owned(), APP)]),
        vec![contract(&document(&discard))],
    )
    .unwrap();
}

#[test]
fn joint_nominal_conditions_and_public_bound_visibility_are_checked() {
    for source in [
        "trait Mark {} struct Box<T: Mark> { value: T } fn bad() { let value = Box { value: 1 }; }",
        "trait Mark {} struct Box<T: Mark> { value: T } fn bad(value: &Box<Int>) {}",
        "trait Mark {} struct Box<T: Mark> { value: T } struct Bad<T> { value: Box<T> }",
        "trait Private {} pub fn bad<T: Private>(value: &T) {}",
        "trait Private {} pub struct Bad<T: Private> { value: T }",
        "trait Private {} pub trait Bad: Private {}",
        "struct Hidden {} pub trait Bad { type Item = Hidden; }",
        "effect Hidden { fn call() -> Unit; } pub fn bad() -> Unit with {Hidden} {}",
    ] {
        assert_eq!(
            error(source).kind,
            CheckDiagnosticKind::TypeMismatch,
            "{source}"
        );
    }
    check("trait Mark {} struct Good {} impl Mark for Good {} struct Box<T: Mark> { value: T } fn good<T: Mark>(value: move T) -> Box<T> { Box { value } } fn call() { good(Good {}); }").unwrap();
    check("pub trait Public { fn get(self: &Self) -> Int; } struct Hidden {} impl Public for Hidden { fn get(self: &Self) -> Int { 1 } }").unwrap();
}

#[test]
fn joint_associated_bounds_and_comparisons_use_the_dictionary_call() {
    check(
        r#"
trait Read { fn read(self: &Self) -> Int with {}; }
trait Container { type Item: Read; fn item(self: &Self) -> Self::Item; }
fn nested<T: Container>(container: &T) -> Int { container.item().read() }
struct A {}
impl PartialEq for A { fn eq(self: &Self, other: &Self) -> Bool with {} { true } }
fn compare(left: &A, right: &A) -> Bool with {} { left == right }
fn generic<T: PartialEq>(left: &T, right: &T) -> Bool { left != right }
fn call() -> Bool with {} { generic(A {}, A {}) }
"#,
    )
    .unwrap();
    let diagnostic = error(
        "struct A {} impl PartialEq for A { fn eq(self: &Self, other: &Self) -> Bool with {fs} { true } } fn wrong(left: &A, right: &A) -> Bool with {} { left == right }",
    );
    assert_eq!(
        diagnostic.kind,
        CheckDiagnosticKind::TypeMismatch,
        "{diagnostic:?}"
    );
}

#[test]
fn joint_effect_alias_actuals_and_projection_destruction_close_together() {
    check(
        r#"
effect Signal<T> { fn ping(value: T) -> Unit; }
effect alias Alias<T> = {Signal<T>};
fn ping() -> Unit with {Alias<Int>} { Signal.ping(1); }
trait Item { type Value; }
struct A {}
impl Item for A { type Value = Int; }
struct Holder<T: Item> { value: T::Value }
fn discard<T: Item>(value: move Holder<T>) {}
fn pure(value: move Holder<A>) with {} { discard(value); }
"#,
    )
    .unwrap();
    for source in [
        "fn bad() with {fail<Int>, fail<Bool>} {}",
        "trait Bad { fn call(self: &Self) with {fail<Int>, fail<Bool>}; }",
    ] {
        assert_eq!(error(source).kind, CheckDiagnosticKind::TypeMismatch);
    }
}

#[test]
fn joint_conformance_coherence_and_dictionary_binding() {
    check(
        r#"
trait P {}
trait Source { type Item; }
trait Read { fn read(self: &Self) -> Int with {}; }
struct A {}
impl Source for A { type Item = Int; }
impl<T, U> P for T where T: Source<Item = U> {}
impl Read for A { fn read(self: &Self) -> Int { 1 } }
impl A { fn read(self: &Self) -> Bool { true } }
fn fixed<T: Read>(value: &T) -> Int with {} { value.read() }
fn need<T: P>(value: &T) {}
fn valid() -> Int with {} { need(A {}); fixed(A {}) }
trait Pair {}
type PairType = (Int, Bool);
impl Pair for PairType {}
struct Box<T> { value: T }
trait Allowed {}
impl<T> Allowed for Box<T> where (T, Bool): Pair {}
fn allow<T: Allowed>(value: &T) {}
fn tuple_subject() { allow(Box { value: 1 }); }
trait Next { type Item; }
impl Next for Int { type Item = Self; }
fn projection<T: Next<Item = Int>>(value: &T) {}
fn self_nominal() { projection(1); }
"#,
    )
    .unwrap();
    for source in [
        "trait T { fn f(self: &Self); } struct A {} impl T for A {}",
        "trait T {} struct A {} impl T for A { fn extra(self: &Self) {} }",
        "trait T { fn f(self: &Self) -> Int; } struct A {} impl T for A { fn f(self: &Self) -> Bool { true } }",
        "trait T { fn f(self: &Self); } struct A {} impl T for A { fn f(self: move Self) {} }",
        "trait P {} trait T { fn f<U>(self: &Self, value: &U); } struct A {} impl T for A { fn f<U: P>(self: &Self, value: &U) {} }",
        "trait P {} trait T: P {} struct A {} impl T for A {}",
        "trait P {} trait T { type Item: P; } struct A {} impl T for A { type Item = Int; }",
        "trait T {} struct A {} impl T for A {} impl T for A {}",
        "trait T {} struct A {} impl<U> T for A {}",
        "trait X { fn f(self: &Self); } trait Y { fn f(self: &Self); } struct A {} impl X for A { fn f(self: &Self) {} } impl Y for A { fn f(self: &Self) {} } fn bad() { A {}.f(); }",
        "impl PartialEq for Int { fn eq(self: &Self, other: &Self) -> Bool { true } }",
    ] {
        let diagnostic = error(source);
        assert_eq!(
            diagnostic.kind,
            CheckDiagnosticKind::TypeMismatch,
            "{source}: {diagnostic:?}"
        );
    }
}

#[test]
fn joint_named_values_keep_provider_requirements_and_storage_boundary() {
    let prefix = "fn named() -> Unit with {} {} ";
    for tail in [
        "fn bad() { named }",
        "fn bad() { let pair = (named, 1); }",
        "struct Box<T> { value: T } fn bad() { let box = Box { value: named }; }",
        "fn bad() { fail.raise(named); }",
    ] {
        let diagnostic = check(&format!("{prefix}{tail}")).expect_err(tail);
        assert_eq!(
            diagnostic.kind,
            CheckDiagnosticKind::Unsupported,
            "{diagnostic:?}"
        );
    }
    let diagnostic = error(
        "trait Mark {} fn provider<T: Mark>(value: &T) -> Unit with {} {} fn use_it<F: Fn + fn(Int) -> Unit with {}>(callback: call F) { callback(1); } fn bad() { use_it(provider); }",
    );
    assert_eq!(
        diagnostic.kind,
        CheckDiagnosticKind::TypeMismatch,
        "{diagnostic:?}"
    );
}

#[test]
fn joint_legal_foreign_trait_impl_keeps_original_library_through_aliases() {
    let sources = ProjectSources { entry: APP, core: CORE, libraries: with_core(BTreeMap::from([
        (APP, LibrarySources { root: "use dep::Read; struct A {} type Alias = A; impl Read for Alias { fn read(self: &Self) -> Int { 7 } } fn good() -> Int { A {}.read() }".to_owned(), modules: BTreeMap::new(), dependencies: BTreeMap::from([("dep".to_owned(), DEPENDENCY)]) }),
        (DEPENDENCY, LibrarySources { root: "pub use hidden::Read; mod hidden { pub trait Read { fn read(self: &Self) -> Int; } }".to_owned(), modules: BTreeMap::new(), dependencies: BTreeMap::new() }),
    ])) };
    check_project(&sources, &BTreeMap::new(), Vec::new()).unwrap();
    let mut illegal = sources;
    illegal.libraries.get_mut(&APP).unwrap().root = "use dep::Read; type Alias = Int; impl Read for Alias { fn read(self: &Self) -> Int { 7 } }".to_owned();
    assert_eq!(
        check_project(&illegal, &BTreeMap::new(), Vec::new())
            .unwrap_err()
            .kind,
        CheckDiagnosticKind::TypeMismatch
    );
}

#[test]
fn joint_contract_method_formals_requirements_states_and_bodyless_checks() {
    let implementation = r#"{"library":{"tag":"self"},"type_parameter_count":1,"target":{"tag":"nominal","declaration":{"library":{"tag":"self"},"path":["Box"],"kind":"struct"},"arguments":[{"tag":"local_type_parameter","index":0}]}}"#;
    let method = format!(
        r#"{{"tag":"impl_member","owner":{implementation},"kind":"method","name":"keep"}}"#
    );
    let own = format!(
        r#"{{"tag":"formal","formal":{{"owner":{method},"binder":"method","kind":"type","index":0}}}}"#
    );
    let record = format!(
        r#"{{"target":{method},"type_parameters":["Renamed"],"set":{{"parameter_types":[{{"parameter":{{"tag":"position","index":0}},"type":{own}}}],"return_type":{own},"effect_upper":[]}}}}"#
    );
    let source = "struct Box<T> { value: T } impl<T> Box<T> { fn keep<U>(self: &Self, value: move U) -> U { value } } fn use_it() -> Int { Box { value: true }.keep(1) }";
    let owners = BTreeMap::from([("app".to_owned(), APP)]);
    check_project(
        &project(source),
        &owners,
        vec![contract(&document(&record))],
    )
    .unwrap();
    let bad = record.replace("\"binder\":\"method\"", "\"binder\":\"impl\"");
    assert!(check_project(&project(source), &owners, vec![contract(&document(&bad))]).is_err());
    let method_record = r#"{"target":{"tag":"trait_member","owner":{"library":{"tag":"self"},"path":["T"],"kind":"trait"},"kind":"method","name":"read"},"set":{"return_type":{"tag":"primitive","name":"Bool"}}}"#;
    let diagnostic = check_project(
        &project("trait T { fn read(self: &Self) -> Int; }"),
        &owners,
        vec![contract(&document(method_record))],
    )
    .unwrap_err();
    assert!(
        matches!(diagnostic.primary, Some(CheckOrigin::Contract { .. })),
        "{diagnostic:?}"
    );
    let target = function_target("invoke");
    let formal = function_formal("invoke", 0);
    let requirement = format!(
        r#"{{"tag":"trait","subject":{formal},"bound":{{"trait":{{"library":{{"tag":"self"}},"path":["Tick"],"kind":"trait"}},"arguments":[],"associated_bindings":[]}}}}"#
    );
    let selected = format!(
        r#"{{"target":{target},"type_parameters":["X"],"set":{{"generic_requirements":[{requirement}]}}}}"#
    );
    let empty = format!(
        r#"{{"target":{target},"type_parameters":["X"],"set":{{"generic_requirements":[]}}}}"#
    );
    let source = "trait Tick { fn tick(self: &Self) -> Int; } struct A {} impl Tick for A { fn tick(self: &Self) -> Int { 1 } } fn invoke<T>(value: &T) -> Int { value.tick() } fn call() -> Int { invoke(A {}) }";
    check_project(
        &project(source),
        &owners,
        vec![contract(&document(&selected))],
    )
    .unwrap();
    assert!(check_project(&project(source), &owners, vec![contract(&document(&empty))]).is_err());
    assert_eq!(
        check_project(
            &project(source),
            &owners,
            vec![contract(&document(&format!("{selected},{empty}")))]
        )
        .unwrap_err()
        .kind,
        CheckDiagnosticKind::ContractConflict
    );
}

#[test]
fn joint_contract_selected_named_call_and_method_application_keep_public_rows() {
    let owners = BTreeMap::from([("app".to_owned(), APP)]);
    let named = r#"{"tag":"function_item","function":{"tag":"declaration","declaration":{"library":{"tag":"self"},"path":["file"],"kind":"function"}},"owner_type_arguments":[],"type_arguments":[],"effect_arguments":[]}"#;
    let record = format!(
        r#"{{"target":{},"set":{{"effect_upper":[{{"tag":"selected_call","callable":{named}}}]}}}}"#,
        function_target("propagate")
    );
    check_project(&project("fn file() -> Unit with {fs} {} fn propagate() -> Unit { file(); } fn caller() with {fs} { propagate(); }"), &owners, vec![contract(&document(&record))]).unwrap();
    let target = function_target("invoke");
    let formal = function_formal("invoke", 0);
    let record = format!(
        r#"{{"target":{target},"type_parameters":["X"],"set":{{"effect_upper":[{{"tag":"method_application","method":{{"tag":"trait_member","kind":"method","owner":{{"library":{{"tag":"self"}},"path":["Tick"],"kind":"trait"}},"name":"tick"}},"self":{formal},"trait_type_arguments":[],"method_type_arguments":[],"effect_arguments":[]}}]}}}}"#
    );
    check_project(&project("trait Tick { fn tick(self: &Self) -> Int; } struct A {} impl Tick for A { fn tick(self: &Self) -> Int with {fs} { 1 } } fn invoke<T: Tick>(value: &T) -> Int { value.tick() } fn caller() -> Int with {fs} { invoke(A {}) }"), &owners, vec![contract(&document(&record))]).unwrap();
}

#[test]
fn joint_effect_relations_and_recursive_callbacks_preserve_the_selected_domain() {
    for extra in [
        "",
        "struct Other {} impl Tick for Other { fn tick(self: &Self) -> Int with {fs} { 2 } }",
    ] {
        check(&format!(
            r#"
trait Tick {{ fn tick(self: &Self) -> Int; }}
struct A {{}}
impl Tick for A {{ fn tick(self: &Self) -> Int with {{console}} {{ 1 }} }}
fn generic<T: Tick>(value: &T) -> Int {{ value.tick() }}
fn concrete() -> Int with {{console}} {{ generic(A {{}}) }}
{extra}
"#
        ))
        .unwrap();
    }
    check(r#"
fn a<F: Fn + fn() -> Unit with {E}, effect E>(callback: call F, end: Bool) -> Unit with {E} { if end { callback(); } else { b(callback, true); } }
fn b<G: Fn + fn() -> Unit with {H}, effect H>(callback: call G, end: Bool) -> Unit with {H} { a(callback, end); }
fn file() -> Unit with {fs} {}
fn use_it() -> Unit with {fs} { a(file, false); }
trait Base { fn base(self: &Self) -> Int with {}; }
trait Derived: Base {}
trait Container { type Item: Derived; fn item(self: &Self) -> Self::Item; }
fn nested<T: Container>(value: &T) -> Int { value.item().base() }
"#).unwrap();
    for source in [
        "trait T { fn f(self: &Self); } fn bad<X: T>(x: &X) with {} { x.f(); }",
        "effect Hidden { fn op() -> Unit; } pub fn bad() { Hidden.op(); }",
        "effect Signal<T> { fn op(value: T) -> Unit; } fn bad() { Signal.op(1); Signal.op(true); }",
        "trait T { fn a(self: &Self) with {T::b<Self>}; fn b(self: &Self) with {T::a<Self>}; }",
    ] {
        let diagnostic = error(source);
        assert_eq!(
            diagnostic.kind,
            CheckDiagnosticKind::TypeMismatch,
            "{diagnostic:?}"
        );
    }
}

#[test]
fn joint_effect_alias_worklist_handles_a_finite_chain() {
    assert_eq!(error("trait Mark {} effect Signal<T: Mark> { fn op(value: T) -> Unit; } fn bad() { Signal.op(1); }").kind, CheckDiagnosticKind::TypeMismatch);
    assert_eq!(
        error("trait Mark {} effect alias Alias<T: Mark> = {fs}; fn bad() with {Alias<Int>} {}")
            .kind,
        CheckDiagnosticKind::TypeMismatch
    );

    let mut source = "effect alias E0 = {fs};\n".to_owned();
    for index in 1..=128 {
        writeln!(source, "effect alias E{index} = {{E{}}};", index - 1).unwrap();
    }
    source.push_str("fn file() with {E128} {} fn call() with {fs} { file(); }");
    std::thread::Builder::new()
        .stack_size(1024 * 1024)
        .spawn(move || check(&source).unwrap())
        .unwrap()
        .join()
        .unwrap();
}

#[test]
fn joint_contract_projection_partials_normalize_before_conflict_checks() {
    let owners = BTreeMap::from([("app".to_owned(), APP)]);
    let projection = r#"{"tag":"associated","base":{"tag":"nominal","declaration":{"library":{"tag":"self"},"path":["A"],"kind":"struct"},"arguments":[]},"trait":{"trait":{"library":{"tag":"self"},"path":["Item"],"kind":"trait"},"arguments":[],"associated_bindings":[]},"name":"Value"}"#;
    let selected = format!(
        r#"{{"target":{},"set":{{"return_type":{projection}}}}}"#,
        function_target("value")
    );
    let explicit = format!(
        r#"{{"target":{},"set":{{"return_type":{{"tag":"primitive","name":"Int"}}}}}}"#,
        function_target("value")
    );
    check_project(&project("trait Item { type Value; } struct A {} impl Item for A { type Value = Int; } fn value() -> A::Value { 1 }"), &owners, vec![contract(&document(&format!("{selected},{explicit}")))]).unwrap();
    let record = format!(
        r#"{{"target":{},"set":{{"parameter_types":[{{"parameter":{{"tag":"position","index":0}},"type":{{"tag":"nominal","declaration":{{"library":{{"tag":"self"}},"path":["Missing"],"kind":"struct"}},"arguments":[]}}}}],"effect_upper":[{{"tag":"fail","payload":{{"tag":"primitive","name":"Str"}}}}]}}}}"#,
        function_target("value")
    );
    let diagnostic = check_project(
        &project("fn value(x: Int) -> Int { x }"),
        &owners,
        vec![contract(&document(&record))],
    )
    .unwrap_err();
    assert_eq!(diagnostic.kind, CheckDiagnosticKind::Unsupported);
    assert_eq!(
        diagnostic.primary,
        Some(CheckOrigin::Contract {
            document_index: 0,
            json_path: "$.records[0].set.effect_upper[0].payload".to_owned()
        })
    );
}

#[test]
fn public_associated_and_callback_types_retain_nested_visibility() {
    for source in [
        "pub trait Bound<T> {} struct Hidden {} pub trait Host { type Item: Bound<Hidden>; }",
        "pub trait Bound { type Value; } struct Hidden {} pub trait Host { type Item: Bound<Value = Hidden>; }",
        "pub trait Item { type Value; } pub struct A {} struct Hidden {} impl Item for A { type Value = Hidden; }",
        "struct Hidden {} pub fn consume<F: Fn + fn(Hidden) -> Unit with {}>(callback: call F) -> Unit with {} {}",
        "struct Hidden {} pub fn consume<F: Fn + fn() -> Hidden with {}>(callback: call F) -> Unit with {} {}",
        "pub trait Bound<T> {} type Hidden = Int; pub trait Host { type Item: Bound<Hidden>; }",
        "pub trait Item { type Value; } pub struct A {} type Hidden = Int; impl Item for A { type Value = Hidden; }",
        "type Hidden = Int; pub fn consume<F: Fn + fn(Hidden) -> Unit with {}>(callback: call F) -> Unit with {} {}",
        "pub trait Bound<T> {} type Hidden = Int; pub struct A<T: Bound<Hidden>> { value: T }",
        "pub trait Bound<T> {} type Hidden = Int; pub trait Item {} pub struct A<T> { value: T } impl<T> Item for A<T> where T: Bound<Hidden> {}",
    ] {
        let diagnostic = error(source);
        assert_eq!(
            diagnostic.kind,
            CheckDiagnosticKind::TypeMismatch,
            "{source}: {diagnostic:?}"
        );
        assert!(diagnostic.message.contains("private"), "{diagnostic:?}");
        assert!(matches!(diagnostic.primary, Some(CheckOrigin::Source(_))));
    }
    for source in [
        "pub trait Bound<T> {} pub struct Visible {} pub trait Host { type Item: Bound<Visible>; } pub trait Item { type Value; } pub struct A {} impl Item for A { type Value = Visible; }",
        "pub struct Visible {} pub fn consume<F: Fn + fn(Visible) -> Visible with {}>(callback: call F) -> Unit with {} {}",
        "pub trait Item { type Value; } struct A {} struct Hidden {} impl Item for A { type Value = Hidden; }",
        "type Hidden = Int; fn consume<F: Fn + fn(Hidden) -> Hidden with {}>(callback: call F) -> Unit with {} {}",
    ] {
        check(source).unwrap();
    }
}

#[test]
fn nested_projection_uses_associated_givens_without_guessing() {
    for source in [
        "trait Inner { type Value; } trait Outer { type Item: Inner<Value = Int>; } fn value<T: Outer>(x: &T) -> T::Item::Value { 1 }",
        "trait Inner { type Value; } trait Outer { type Item: Inner; } fn identity<T: Outer>(x: move T::Item::Value) -> T::Item::Value { x }",
        "trait Leaf { type End; } trait Inner { type Value: Leaf<End = Int>; } trait Outer { type Item: Inner; } fn value<T: Outer>(x: &T) -> T::Item::Value::End { 1 }",
    ] {
        check(source).unwrap();
    }
    let missing =
        error("trait Outer { type Item; } fn value<T: Outer>(x: &T) -> T::Item::Value { 1 }");
    assert!(missing.message.contains("no trait evidence"), "{missing:?}");
    let ambiguous = error(
        "trait Left { type Value; } trait Right { type Value; } trait Outer { type Item: Left + Right; } fn value<T: Outer>(x: &T) -> T::Item::Value { 1 }",
    );
    assert!(ambiguous.message.contains("ambiguous"), "{ambiguous:?}");
}

#[test]
fn nested_method_effect_actuals_resolve_on_the_default_windows_stack() {
    std::thread::Builder::new().stack_size(1024 * 1024).spawn(|| {
        let prefix = "trait T { fn run<effect E>(self: &Self) -> Unit with {E}; } struct A {} impl T for A { fn run<effect E>(self: &Self) -> Unit with {E} {} } ";
        for depth in [8, 32, 64, 128] {
            let mut row = "fs".to_owned();
            for _ in 0..depth { row = format!("T::run<A, effect {{{row}}}>"); }
            let source = format!("{prefix} fn nested() -> Unit with {{{row}}} {{}} fn call() -> Unit with {{fs}} {{ nested(); }}");
            let sources = project(&source);
            let resolved = vorton_compiler::resolve_project(&sources).unwrap();
            drop(vorton_compiler::prepare_project(resolved).unwrap());
            check_project(&sources, &BTreeMap::new(), Vec::new()).unwrap();
            if depth == 128 {
                let invalid = source.replacen("fs", "missing", 1);
                let diagnostic = vorton_compiler::resolve_project(&project(&invalid)).unwrap_err();
                let origin = diagnostic.primary.unwrap();
                assert_eq!(&invalid[origin.span.start..origin.span.end], "missing");
            }
        }
    }).unwrap().join().unwrap();
}

#[test]
fn callback_minimum_is_recomputed_after_payload_unification() {
    for source in [
        "fn actual() -> Unit with {fail<Int>} {} fn ignore<T, F: Fn + fn() -> Unit with {fail<T>, E}, effect E>(callback: call F) -> Unit with {E} {} fn pure() -> Unit with {} { ignore(actual); }",
        "fn actual() -> Unit with {fail<Int>} {} fn ignore<T, F: Fn + fn() -> Unit with {fail<T>, E}, effect E>(value: &T, callback: call F) -> Unit with {E} {} fn pure() -> Unit with {} { ignore(1, actual); }",
        "fn first() -> Unit with {fail<Int>} {} fn second() -> Unit with {fail<Int>, fs} {} fn ignore<T,F: Fn + fn() -> Unit with {fail<T>, E}, G: Fn + fn() -> Unit with {fail<T>, E}, effect E>(f: call F, g: call G) -> Unit with {E} {} fn call() -> Unit with {fs} { ignore(first, second); }",
        "fn actual() -> Unit with {fail<Int>} {} fn ignore<T,F: Fn + fn() -> Unit with {fail<T>, E, H}, effect E, effect H>(f: call F) -> Unit with {E,H} {} fn call() -> Unit with {} { ignore(actual); }",
        "fn actual<T>() -> Unit with {fail<T>} {} fn ignore<F: Fn + fn() -> Unit with {fail<Int>, E}, effect E>(f: call F) -> Unit with {E} {} fn call() -> Unit with {} { ignore(actual); }",
    ] {
        check(source).unwrap();
    }
    let conflict = error(
        "fn first() -> Unit with {fail<Int>} {} fn second() -> Unit with {fail<Bool>} {} fn ignore<T,F: Fn + fn() -> Unit with {fail<T>, E}, G: Fn + fn() -> Unit with {fail<T>, E}, effect E>(f: call F, g: call G) -> Unit with {E} {} fn call() -> Unit { ignore(first, second); }",
    );
    assert!(
        conflict.message.contains("payload conflict"),
        "{conflict:?}"
    );
}

#[test]
fn public_contract_shapes_reject_private_types_before_erasing_aliases() {
    let owners = BTreeMap::from([("app".to_owned(), APP)]);
    let target = function_target("consume");
    let formal = function_formal("consume", 0);
    for (declaration, kind) in [
        ("struct Hidden {}", "struct"),
        ("type Hidden = Int;", "type_alias"),
    ] {
        let hidden = format!(
            r#"{{"tag":"nominal","declaration":{{"library":{{"tag":"self"}},"path":["Hidden"],"kind":"{kind}"}},"arguments":[]}}"#
        );
        for result in [false, true] {
            let shape = if result {
                format!(r#"{{"parameters":[],"result":{hidden},"effect_upper":[]}}"#)
            } else {
                format!(
                    r#"{{"parameters":[{{"type":{hidden},"mode":{{"tag":"fixed","mode":"borrow"}},"escape":"may_escape"}}],"result":{{"tag":"primitive","name":"Unit"}},"effect_upper":[]}}"#
                )
            };
            let record = format!(
                r#"{{"target":{target},"type_parameters":["F"],"set":{{"generic_requirements":[{{"tag":"trait","subject":{formal},"bound":{{"trait":{{"library":{{"tag":"dependency","alias":"vorton_core"}},"path":["Fn"],"kind":"trait"}},"arguments":[],"associated_bindings":[]}}}},{{"tag":"callable_shape","subject":{formal},"shape":{shape}}}]}}}}"#
            );
            let source =
                format!("{declaration} pub fn consume<F>(callback: &F) -> Unit with {{}} {{}}");
            let diagnostic = check_project(
                &project(&source),
                &owners,
                vec![contract(&document(&record))],
            )
            .unwrap_err();
            assert_eq!(
                diagnostic.kind,
                CheckDiagnosticKind::TypeMismatch,
                "{diagnostic:?}"
            );
            let suffix = if result {
                ".result"
            } else {
                ".parameters[0].type"
            };
            assert_eq!(
                diagnostic.primary,
                Some(CheckOrigin::Contract {
                    document_index: 0,
                    json_path: format!("$.records[0].set.generic_requirements[1].shape{suffix}")
                })
            );
            let visible = source.replacen(declaration, &format!("pub {declaration}"), 1);
            check_project(
                &project(&visible),
                &owners,
                vec![contract(&document(&record))],
            )
            .unwrap();
        }
    }
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
fn nested_supported_expressions_fit_the_default_windows_stack() {
    fn assert_checked(source: &str) {
        let sources = project(source);
        drop(vorton_compiler::parse(source).unwrap());
        let resolved = vorton_compiler::resolve_project(&sources).unwrap();
        assert!(format!("{resolved:?}").contains("library_count: 2"));
        drop(resolved);
        let checked = check_project(&sources, &BTreeMap::new(), Vec::new()).unwrap();
        assert!(format!("{checked:?}").contains("checked_function_count"));
        drop(checked);
    }

    // The normal test thread is larger than the failing Windows main thread.
    // Keep the complete public pipeline, observation, and Drop on its 1 MiB stack.
    std::thread::Builder::new()
        .stack_size(1024 * 1024)
        .spawn(|| {
            for depth in [14, 15, 16, 32] {
                let source = format!(
                    "struct Wrap<T> {{ value: T }} fn probe() {{ let result = {}1{}; }}",
                    "Wrap { value: ".repeat(depth),
                    " }".repeat(depth),
                );
                assert_checked(&source);
            }

            let mut source = "struct Wrap<T> { value: T } fn probe() { let value = 1;".to_owned();
            for _ in 0..32 {
                source.push_str(" let value = Wrap { value };");
            }
            source.push_str(" }");
            assert_checked(&source);

            for (declarations, prefix, suffix) in [
                ("", "(", ")"),
                ("", "(", ", 0)"),
                ("fn identity(value: Int) -> Int { value } ", "identity(", ")"),
                ("", "1 + (", ")"),
                ("", "{ ", " }"),
                ("", "if true { ", " } else { 0 }"),
            ] {
                for depth in [1, 32] {
                    let source = format!(
                        "{declarations}fn probe() {{ let result = {}1{}; }}",
                        prefix.repeat(depth),
                        suffix.repeat(depth),
                    );
                    assert_checked(&source);
                }
            }

            let file = FileModulePath::new(["nested"]).unwrap();
            for (leaf, expected, marker) in [
                (
                    "missing + later_missing",
                    CheckDiagnosticKind::Project(Box::new(ProjectDiagnosticKind::UnresolvedName {
                        namespace: vorton_compiler::NameNamespace::Value,
                        name: "missing".to_owned(),
                    })),
                    "missing",
                ),
                (
                    "OnlyInt { value: true }",
                    CheckDiagnosticKind::TypeMismatch,
                    "true",
                ),
            ] {
                for depth in [1, 32] {
                    let source = format!(
                        "// 前\nstruct Wrap<T> {{ value: T }} struct OnlyInt {{ value: Int }} pub fn probe() {{ let result = {}{leaf}{}; }}",
                        "Wrap { value: ".repeat(depth),
                        " }".repeat(depth),
                    );
                    let mut sources = project("use nested::probe;");
                    sources
                        .libraries
                        .get_mut(&APP)
                        .unwrap()
                        .modules
                        .insert(file.clone(), source.clone());
                    let diagnostic =
                        check_project(&sources, &BTreeMap::new(), Vec::new()).unwrap_err();
                    assert_eq!(diagnostic.kind, expected);
                    let Some(CheckOrigin::Source(origin)) = &diagnostic.primary else {
                        panic!("a real source origin is required: {diagnostic:?}")
                    };
                    assert_eq!(origin.library, APP);
                    assert_eq!(origin.source, vorton_compiler::SourceRef::File(file.clone()));
                    let start = source.find(marker).unwrap();
                    assert_eq!(
                        origin.span,
                        vorton_compiler::ast::Span {
                            start,
                            end: start + marker.len(),
                        }
                    );
                    drop(diagnostic);
                }
            }
        })
        .unwrap()
        .join()
        .unwrap();
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
fn alias_cycles_wrong_arity_and_missing_comparison_evidence_are_type_errors() {
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
fn source_shapes_methods_and_other_declarations_remain_unsupported() {
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
fn each_selected_contract_family_outside_the_subset_is_explicitly_unsupported() {
    let sources = project("fn value(input: Int) -> Int { input }");
    let target = function_target("value");
    let records = [
        format!(r#"{{"target":{target},"set":{{"parameter_modes":[{{"parameter":{{"tag":"position","index":0}},"mode":{{"tag":"fixed","mode":"mut"}}}}]}}}}"#),
        format!(r#"{{"target":{target},"set":{{"return_type":{{"tag":"primitive","name":"Str"}}}}}}"#),
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
        check(&format!(
            "fn f<T>(flag: Bool, x: &T) -> Unit with {{}} {{ {body} }}"
        ))
        .unwrap();
        let source = format!("fn f<T>(flag: Bool, x: move T) -> Unit {{ {body} }}");
        check(&source).unwrap();
        assert_eq!(
            error(&source.replace("-> Unit {", "-> Unit with {} {")).kind,
            CheckDiagnosticKind::TypeMismatch
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
        let source = format!(
            "fn f<T>(flag: Bool, pair: move (T, Int), bottom: (Never, Int)) -> (T, Int) {{ let result = {branches}; result }}"
        );
        check(&source).unwrap();
        assert_eq!(
            error(&source.replace("-> (T, Int) {", "-> (T, Int) with {} {")).kind,
            CheckDiagnosticKind::TypeMismatch
        );
    }
    check("fn f<T>(bottom: (Never, Int)) -> (T, Int) { let result: (T, Int) = bottom; result }")
        .unwrap();
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
fn early_return_accounts_for_generic_temporaries() {
    for source in [
        "fn take<T>(value: move T, count: Int) -> T { value } fn bad<T>(value: move T) -> Int { take(value, { return 0; }); 0 }",
        "fn bad<T>(value: move T) -> Int { let pair = (value, { return 0; }); 0 }",
    ] {
        check(source).expect("pending owners contribute a formal destruction relationship");
        assert_eq!(
            error(&source.replace("-> Int {", "-> Int with {} {")).kind,
            CheckDiagnosticKind::TypeMismatch
        );
    }
    check("fn good<T>(value: move T) -> T { return value; }").unwrap();
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
    check(&format!(
        "{ring} fn drop_recursive(value: move Node0) with {{}} {{}}"
    ))
    .unwrap();

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
fn finite_and_recursive_nominal_cleanup_uses_actual_members() {
    for source in [
        "struct Box<T> { value: T } fn drop_box(value: move Box<Box<Int>>) with {} {}",
        "struct Box<T> { value: T } fn wrap<T>(value: T) -> Box<T> { Box { value } } fn drop_call() with {} { wrap(wrap(1)); }",
        "struct Box<T> { value: T } fn drop_box<T>(value: move Box<Box<T>>) {}",
        "struct Grow<T> { next: Grow<(T, T)> } fn drop_growing<T>(value: move Grow<T>) with {} {}",
        "struct Box<T> { value: T } struct Recursive { next: Box<Recursive> } fn drop_recursive(value: move Recursive) with {} {}",
        "enum Grow<T> { More(Grow<(T, T)>), End(T) } fn drop_growing(value: move Grow<Int>) with {} {}",
    ] {
        check(source).unwrap();
    }
    for source in [
        "struct Box<T> { value: T } fn drop_box<T>(value: move Box<Box<T>>) with {} {}",
        "enum Grow<T> { More(Grow<(T, T)>), End(T) } fn drop_growing<T>(value: move Grow<T>) with {} {}",
    ] {
        assert_eq!(error(source).kind, CheckDiagnosticKind::TypeMismatch);
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
        check(&source).unwrap();
        assert_eq!(
            error(&source.replace("fn bad<T>(value: T) {", "fn bad<T>(value: T) with {} {")).kind,
            CheckDiagnosticKind::TypeMismatch
        );
    }
    check(
        r#"
struct Pair<T> { first: T, last: Unit }
fn early<T>(value: T) -> T {
    let pending = Pair { last: { return value; }, first: value };
    early(value)
}
fn pure_temporary() with {} { let pending = Pair { first: 1, last: { return; } }; }
"#,
    )
    .unwrap();
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
