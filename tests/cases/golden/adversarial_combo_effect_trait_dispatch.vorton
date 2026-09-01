// B-100 P1.3 R2 adversarial combo: effect + trait dispatch combined.
//
// A generic function that takes a trait-bounded type AND carries an effect.
// The LLVM codegen must correctly order: dict params + evidence params in
// the lowered function signature. If trait dicts and effect evidence are
// interleaved incorrectly, the trait dispatch reads the wrong pointer.
//
// Exercises:
//   * Generic fn with Eq bound + fail effect — both implicit param kinds
//   * Generic fn with custom trait + io effect — trait dispatch + print
//   * Calling an effectful generic fn from another effectful generic fn
//   * Handler around effectful generic call

trait Render {
    fn render(self) -> Str
}

struct Widget { name: Str }

impl Render for Widget {
    fn render(self) -> Str { "[${self.name}]" }
}

struct Badge { label: Str }

impl Render for Badge {
    fn render(self) -> Str { "<${self.label}>" }
}

fn render_or_fail<T: Render>(x: T, allow: Bool) -> Str with {fail<Str>} {
    if !allow { fail.raise("blocked") }
    x.render()
}

fn render_and_print<T: Render>(x: T, label: Str) -> Str {
    let rendered = x.render()
    print("rendering ${label}: ${rendered}")
    rendered
}

fn render_pair<T: Render>(a: T, b: T) -> Str with {fail<Str>} {
    let ra = render_or_fail(a, true)
    let rb = render_or_fail(b, true)
    "${ra}+${rb}"
}

fn try_render_list<T: Render + Eq>(items: List<T>, skip: T) -> Str with {fail<Str>} {
    let mut parts: List<Str> = []
    for item in items {
        if item == skip { continue }
        let r = render_or_fail(item, true)
        parts.push(r)
    }
    if parts.len() == 0 { fail.raise("all skipped") }
    parts.join(",")
}

fn main() {
    // Test 1: generic + effect — success
    let r1 = render_or_fail(Widget { name: "btn" }, true) catch { e => e }
    print("T1: ${r1}")

    // Test 2: generic + effect — failure
    let r2 = render_or_fail(Widget { name: "btn" }, false) catch { e => e }
    print("T2: ${r2}")

    // Test 3: generic + io — Widget
    let r3 = render_and_print(Widget { name: "box" }, "widget")
    print("T3: ${r3}")

    // Test 4: generic + io — Badge
    let r4 = render_and_print(Badge { label: "vip" }, "badge")
    print("T4: ${r4}")

    // Test 5: chained generic+effect — two renders
    let r5 = render_pair(Widget { name: "a" }, Widget { name: "b" }) catch { e => e }
    print("T5: ${r5}")

    // Test 6: generic with BOTH trait + Eq + effect — skip one
    let items = [Widget { name: "x" }, Widget { name: "y" }, Widget { name: "z" }]
    let skip = Widget { name: "y" }
    let r6 = try_render_list(items, skip) catch { e => e }
    print("T6: ${r6}")

    // Test 7: generic with both trait + Eq + effect — all skipped
    let items2 = [Widget { name: "only" }]
    let r7 = try_render_list(items2, Widget { name: "only" }) catch { e => e }
    print("T7: ${r7}")

    print("adversarial_combo_effect_trait_dispatch: done")
}
