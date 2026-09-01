// C-native regression: effect handlers (tail-resumptive +
// abort) + try/catch + default evidence.
// Coverage: multi-op evidence slot ordering (perform order != declaration
// order), handler arms capturing outer scope, evidence forwarding through
// callee fns, nested handles for the same effect (inner shadows outer,
// B-100 Fix 7 restore), fail.raise abort handle form, try/catch with
// multi-arm ctor dispatch + nested literal sub-patterns + guards (#246),
// deep-recursion raise (setjmp/longjmp across frames), return inside a
// handle body (#173 cleanup), default evidence with sibling op calls
// (B-097), and a complete table replacing defaulted operations (B-161).
// Runs on BOTH backends — differential-oracle coverage for step 6.

effect Calc {
    fn add(a: Int, b: Int) -> Int
    fn scale(x: Int) -> Int
    fn label() -> Str
}

effect Counter {
    fn get() -> Int { 0 }
    fn increment() -> Int {
        let current = Counter.get()
        current + 1
    }
}

enum AppErr {
    Code(Int),
    Named { tag: Str, n: Int },
    Plain,
}

fn compute() -> Str with {Calc} {
    let s = Calc.scale(10)          // declared 2nd, performed 1st
    let a = Calc.add(s, 5)          // declared 1st, performed 2nd
    let name = Calc.label()         // declared 3rd, performed 3rd
    "${name}=${a}"
}

fn use_counter() -> Int with {Counter} {
    Counter.increment()
}

fn raise_code(n: Int) -> Int with {fail<AppErr>} {
    if n == 0 { fail.raise(AppErr::Plain) }
    if n < 0 { fail.raise(AppErr::Named { tag: "neg", n: n }) }
    if n < 100 { fail.raise(AppErr::Code(n)) }
    n + 1
}

fn deep(n: Int) -> Str with {fail<Str>} {
    if n == 0 { fail.raise("bottom") }
    deep(n - 1)
}

fn raise_int(n: Int) -> Int with {fail<Int>} {
    fail.raise(n * 3)
}

fn early_return(flag: Bool) -> Int {
    let r = handle {
        if flag { return 99 }       // #173: pops the catch frame on the way out
        raise_code(1) catch { _ => 7 }
    } with {
        fail.raise(e) => -1,
    }
    r + 1
}

fn main() {
    // --- multi-op handler: slot ordering + outer capture ---
    let base = 3
    let r1 = handle {
        compute()
    } with {
        Calc.label() => "total",
        Calc.add(a, b) => a + b + base,
        Calc.scale(x) => x * base,
    }
    print("handler: ${r1}")                    // total=38

    // --- evidence forwarding + nested handle (inner shadows outer) ---
    let r2 = handle {
        let outer = Calc.scale(2)
        let inner = handle {
            Calc.scale(2)
        } with {
            Calc.add(a, b) => 0,
            Calc.scale(x) => x * 100,
            Calc.label() => "inner",
        }
        let after = Calc.scale(2)              // outer evidence restored
        "${outer},${inner},${after}"
    } with {
        Calc.add(a, b) => 0,
        Calc.scale(x) => x + 1,
        Calc.label() => "outer",
    }
    print("nested: ${r2}")                     // 3,200,3

    // --- abort form: handle with fail.raise ---
    // Audit #251: the catch path binds the payload and executes this nonidentity
    // arm after the current frame/evidence is inactive.
    let r3 = handle {
        raise_int(4)
    } with {
        fail.raise(e) => e + 5,
    }
    print("abort: ${r3}")                      // 17

    // --- catch: multi-arm ctor dispatch + nested literal + guard (#246) ---
    let c1 = raise_code(5) catch {
        AppErr::Code(0) => 100,
        AppErr::Code(n) if n > 4 => n * 10,
        AppErr::Code(n) => n,
        AppErr::Named { tag, n } => -2,
        AppErr::Plain => -3,
    }
    let c2 = raise_code(0) catch {
        AppErr::Code(n) => n,
        AppErr::Named { tag, n } => -2,
        AppErr::Plain => -3,
    }
    let c3 = raise_code(-4) catch {
        AppErr::Code(n) => n,
        AppErr::Named { tag: "pos", n } => -9,
        AppErr::Named { tag, n } => n,
        AppErr::Plain => -3,
    }
    print("catch: ${c1} ${c2} ${c3}")          // 50 -3 -4

    // --- deep recursion raise (longjmp across many frames) ---
    let d1 = deep(40) catch { m => "caught ${m}" }
    print("deep: ${d1}")                       // caught bottom

    // --- catch body succeeding (normal path pops the frame) ---
    let ok = raise_code(200) catch { _ => -1 }
    print("ok: ${ok}")                         // 201

    // --- return inside a handle body (#173): returns from the FUNCTION,
    //     popping the catch frame on the way out ---
    print("early: ${early_return(true)} ${early_return(false)}")   // 99 8

    // --- default evidence: sibling op through the default struct (B-097) ---
    print("default: ${use_counter()}")         // 1

    // --- a complete Counter table may replace both declared operations ---
    let ov = handle {
        use_counter()
    } with {
        Counter.get() => 10,
        Counter.increment() => 11,
    }
    print("override: ${ov}")                   // 11
}
