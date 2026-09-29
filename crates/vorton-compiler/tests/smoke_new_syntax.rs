use std::collections::BTreeMap;

use vorton_compiler::diagnostic::{FrontendDiagnosticKind, LayoutDiagnosticKind};
use vorton_compiler::{LibraryId, LibrarySources, ProjectSources, parse, resolve_project};

const PROGRAM: &str = r#"
use Option::{Some, None}

struct Vec2 { x: Float, y: Float }
struct Enemy {
    name: Str,
    pos: Vec2,
    hp: Int,
}
struct World { enemies: List<Enemy>, log: List<Str>, hooks: List<fn(Int) -> Int> }

enum State {
    Running { timer: Float },
    Paused,
}

effect Log {
    fn write(message: Str) -> Unit
}

trait Area {
    fn area(self) -> Float
    fn grow(self: mut Self, by: Float)
}

impl Area for Vec2 {
    fn area(self) -> Float { self.x * self.y }
    fn grow(self: mut Self, by: Float) {
        self.x += by; self.y += by
    }
}

fn damage_all(world: mut World, amount: Int) {
    for e in mut world.enemies {
        e.hp -= amount
    }
    world.log.push("hit ${amount}")
}

fn tick(world: mut World, state: mut State, dt: Float) -> Int {
    let t = mut world.enemies[0].pos
    t.x += dt
    t.y += dt
    match mut state {
        State::Running { timer } => { timer -= dt }
        State::Paused => ()
    }
    let alive = world.enemies
        .filter(fn(e) { e.hp > 0 })
        .len()
    let total = alive * 2 +
        1
    if total > 3 {
        damage_all(mut world, 1)
    } else {
        world.log.push("calm")
    }
    let apply = fn(x: Int) -> Int { x + 1 }
    world.hooks.push(apply)
    let first = (world.hooks[0])(total)
    if let Some(value) = world.enemies.first() {
        return value.hp
    }
    first
}
"#;

fn project(root: &str) -> ProjectSources {
    let app = LibraryId(0);
    let core = LibraryId(1);
    ProjectSources {
        entry: app,
        core,
        libraries: BTreeMap::from([
            (
                app,
                LibrarySources {
                    root: root.to_owned(),
                    modules: BTreeMap::new(),
                    dependencies: BTreeMap::from([("core".to_owned(), core)]),
                },
            ),
            (
                core,
                LibrarySources {
                    root: include_str!("../../../core/root.vorton").to_owned(),
                    modules: BTreeMap::new(),
                    dependencies: BTreeMap::new(),
                },
            ),
        ]),
    }
}

#[test]
fn new_syntax_parses_and_resolves() {
    parse(PROGRAM).expect("program parses");
    resolve_project(&project(PROGRAM)).expect("program resolves");
}

fn layout_error(source: &str) -> LayoutDiagnosticKind {
    match parse(source).expect_err(source).kind {
        FrontendDiagnosticKind::Layout(kind) => kind,
        other => panic!("{source:?}: expected a layout diagnostic, got {other:?}"),
    }
}

#[test]
fn layout_rules_reject_old_forms() {
    assert_eq!(
        layout_error("fn f() {\n    g();\n}"),
        LayoutDiagnosticKind::TrailingSeparator
    );
    assert_eq!(
        layout_error("fn f() { g(); }"),
        LayoutDiagnosticKind::TrailingSeparator
    );
    assert_eq!(
        layout_error("fn f()\n{\n}"),
        LayoutDiagnosticKind::UnexpectedLineBreak
    );
    assert_eq!(
        layout_error("fn f() { a b }"),
        LayoutDiagnosticKind::MissingSeparator
    );
    assert_eq!(
        layout_error("fn f() {\n    let x\n        = 1\n}"),
        LayoutDiagnosticKind::UnexpectedLineBreak
    );
    assert_eq!(
        layout_error("fn f() {\n    match x {\n        A => 1,\n        B => 2\n    }\n}"),
        LayoutDiagnosticKind::TrailingSeparator
    );
}

#[test]
fn line_breaks_end_expressions() {
    // `-b` on its own line is a second statement, not a subtraction.
    let program = parse("fn f() -> Int {\n    let a = 1\n    -a\n}").expect("parses");
    let debug = format!("{program:?}");
    assert!(debug.contains("Unary"), "{debug}");
    // A call on the next line is a separate parenthesized expression.
    parse("fn f() {\n    g\n    (1)\n}").expect("parses as two items");
    parse("fn f() { a; b }").expect("same-line separator");
    parse("fn f() {\n    x = xs[0]\n    xs[1] = 2\n    p.0 = 3\n}").expect("places");
}
