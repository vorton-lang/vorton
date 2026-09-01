// #246 regression: catch arm patterns must run the FULL nested pattern check
// (ctor tags at every depth + literal sub-patterns + top-level literals), not
// just the top-level tag test.  Before the fix the LLVM catch lowering:
//   - multi-arm same-tag ctor arms (Code(0) / Code(n)) built a tag switch with
//     duplicate cases — the literal 0 was never compared (wrong arm taken);
//   - nested ctor sub-patterns (W(A) / W(B)) were never tag-tested;
//   - guarded ctor arms skipped nested literal checks entirely;
//   - top-level literal arms fell into the single-arm fast path (first arm
//     body executed unconditionally).
// The .expected file is HAND-WRITTEN (the LLVM backend is the bug side here —
// no external oracle); lock the language-level constructor-tag contract.

enum MyErr {
    Code(Int),
    Other(Str),
}

enum Inner {
    A,
    B,
}

enum Wrapped {
    W(Inner),
    Z,
}

fn raise_code(n: Int) -> Int with {fail<MyErr>} {
    fail.raise(MyErr::Code(n))
}

fn raise_wrapped() -> Int with {fail<Wrapped>} {
    fail.raise(Wrapped::W(Inner::B))
}

fn raise_int(n: Int) -> Int with {fail<Int>} {
    fail.raise(n)
}

fn main() {
    // 1. Same-tag ctor arms discriminated by a literal sub-pattern.
    let r1 = raise_code(0) catch {
        MyErr::Code(0) => 100,
        MyErr::Code(n) => n,
        MyErr::Other(s) => -1,
    }
    print("r1=${r1}")

    let r2 = raise_code(5) catch {
        MyErr::Code(0) => 100,
        MyErr::Code(n) => n,
        MyErr::Other(s) => -1,
    }
    print("r2=${r2}")

    // 2. Nested ctor tag sub-patterns.
    let r3 = raise_wrapped() catch {
        Wrapped::W(Inner::A) => 1,
        Wrapped::W(Inner::B) => 2,
        Wrapped::Z => 3,
    }
    print("r3=${r3}")

    // 3. Top-level literal arms.
    let r4 = raise_int(7) catch {
        0 => 100,
        n => n,
    }
    print("r4=${r4}")

    // 4. Guarded ctor arm with a literal sub-pattern.
    let r5 = raise_code(3) catch {
        MyErr::Code(0) if true => 90,
        MyErr::Code(n) => n,
        MyErr::Other(s) => -1,
    }
    print("r5=${r5}")
}
