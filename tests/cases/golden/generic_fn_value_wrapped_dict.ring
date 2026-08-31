// B-107/#214: first-class generic functions retain full DictRef evidence.
// The direct HOF case is fully static; the generic let/later-call case needs
// a dynamic Wrap<T> dictionary whose lifetime must stay visible to Perceus.

struct Wrap<T> {
    value: T
}

enum Payload {
    Value(Int),
}

impl<T: Hash> Hash for Wrap<T> {
    fn hash(self) -> Int {
        self.value.hash()
    }
}

fn hash_one<T: Hash>(value: T) -> Int with {} {
    value.hash()
}

fn apply_wrap_hash(
    f: fn(Wrap<Int>) -> Int,
    value: Wrap<Int>
) -> Int {
    f(value)
}

fn hash_later<T: Hash>(value: Wrap<T>) -> Int {
    // #214: this type becomes concrete only after the later closure call.
    // Zonk must resolve hash_one<Wrap<T>> to Wrapped{inner=Simple(T)}.
    let later = hash_one
    later(value)
}

fn constant<T>(_value: T) -> Int with {} {
    107
}

fn apply_float(f: fn(Float) -> Int, value: Float) -> Int {
    f(value)
}

fn apply_int(f: fn(Int) -> Int, value: Int) -> Int {
    f(value)
}

fn apply_payload(
    f: fn(Int) -> Payload,
    value: Int
) -> Payload {
    f(value)
}

fn apply_option(
    f: fn(Int) -> Option<Int>,
    value: Int
) -> Option<Int> {
    f(value)
}

fn local_print_shadow(
    print: fn(Int) -> Int,
    value: Int
) -> Int {
    apply_int(print, value)
}

fn local_cell_shadow(
    Cell: fn(Int) -> Int,
    value: Int
) -> Int {
    apply_int(Cell, value)
}

fn plus_one(value: Int) -> Int with {} {
    value + 1
}

// A const whose value is callable is read through its generated zero-argument
// getter.  In the Match below this deliberately mixes a checker-marked module
// function wrapper with a fresh getter Call result.
const PLUS_ONE: fn(Int) -> Int = plus_one

fn match_callable(flag: Bool, value: Int) -> Int {
    apply_int(
        match flag {
            true => plus_one,
            false => PLUS_ONE,
        },
        value
    )
}

// Unlike ReturnExpr, panic is represented as a Never-typed Call.  The
// divergence proof must use that type so the value-producing marker branch
// can still be materialised as one Match-shaped callable.
fn match_panic_callable(flag: Bool, value: Int) -> Int {
    apply_int(
        match flag {
            true => plus_one,
            false => panic("unselected callable branch"),
        },
        value
    )
}

// The true path produces a checker-marked wrapper and the other path diverges.
// Keep the If as the tail of a Block so Perceus has to prove the whole callable
// control-flow shape materialisable before using it as an argument.
fn block_if_callable(flag: Bool, value: Int) -> Int {
    apply_int(
        {
            if flag {
                plus_one
            } else {
                return 700
                // The current If typer still asks a returning block for a
                // same-typed unreachable tail; expr_diverges recognises the
                // preceding Return and this value is never evaluated.
                plus_one
            }
        },
        value
    )
}

fn apply_generic<T>(
    f: fn(Wrap<T>) -> Int,
    value: Wrap<T>
) -> Int {
    f(value)
}

// Both sites need a dynamic Wrapped{inner=Simple(T)} dictionary.  The first
// passes the generated Block wrapper directly as an argument; the second uses
// the same Block wrapper as an immediate callee.
fn dynamic_wrapper_argument<T: Hash>(value: Wrap<T>) -> Int {
    apply_generic(hash_one, value)
}

fn dynamic_wrapper_callee<T: Hash>(value: Wrap<T>) -> Int {
    ({ hash_one })(value)
}

fn identity<Renamed>(value: Renamed) -> Renamed with {} {
    value
}

fn apply_ground(value: Int, f: fn(Int) -> Int) -> Int {
    f(value)
}

fn apply_generic_identity<Outer>(
    value: Outer,
    f: fn(Outer) -> Outer
) -> Outer {
    f(value)
}

fn forty_two() -> Int with {} {
    42
}

fn apply_zero(f: fn() -> Int) -> Int {
    f()
}

// `print<T>` is an extern generic.  As a first-class value it must use the
// closure ABI while retaining the ordinary backend's scalar-to-display
// conversion, Unit normalisation, and (on LLVM-C) cross-engine marshalling.
fn call_print(
    f: fn(Int) -> Unit with {console},
    value: Int
) -> Unit with {console} {
    f(value)
}

fn call_assert(
    f: fn(Bool, Str) -> Unit with {console},
    condition: Bool,
    message: Str
) -> Unit with {console} {
    f(condition, message)
}

fn call_json(
    f: fn(Str) -> Str,
    value: Str
) -> Str {
    f(value)
}

fn main() {
    let direct = apply_wrap_hash(hash_one, Wrap { value: 42 })
    assert(direct == hash_one(42), "formal HOF captures static Wrap<Int> Hash")

    let delayed = hash_later(Wrap { value: 17 })
    assert(delayed == hash_one(17), "let/later call captures dynamic Wrap<T> Hash")

    assert(apply_float(constant, 1.5) == 107,
        "unconditional generic<Float> remains a zero-dict function value")

    assert(match_callable(true, 10) == 11,
        "Match marker branch materialises")
    assert(match_callable(false, 20) == 21,
        "Match const-getter Call branch materialises")
    assert(match_panic_callable(true, 25) == 26,
        "Match Never-typed panic Call branch does not veto materialisation")
    assert(block_if_callable(true, 30) == 31,
        "Block-tail If marker branch materialises")
    assert(block_if_callable(false, 40) == 700,
        "Block-tail If divergent branch returns")

    assert(dynamic_wrapper_argument(Wrap { value: 23 }) == hash_one(23),
        "dynamic wrapped-dict Block materialises as an immediate argument")
    assert(dynamic_wrapper_callee(Wrap { value: 29 }) == hash_one(29),
        "dynamic wrapped-dict Block materialises as an immediate callee")

    assert(apply_ground(40, plus_one) == 41,
        "ground callable argument resolves")
    assert(apply_generic_identity("renamed", identity) == "renamed",
        "generic callable argument resolves after renamed parameter substitution")
    assert(apply_zero(forty_two) == 42,
        "zero-argument callable argument resolves")

    assert(local_print_shadow(plus_one, 50) == 51,
        "local print binding fails closed instead of becoming builtin extern")
    assert(local_cell_shadow(plus_one, 60) == 61,
        "local Cell binding fails closed instead of becoming prelude callable")

    match apply_payload(fn(value) { Payload::Value(value) }, 70) {
        Payload::Value(value) =>
            assert(value == 70, "explicit lambda constructs user positional enum"),
    }
    match apply_option(fn(value) { some(value) }, 80) {
        some(value) =>
            assert(value == 80, "explicit lambda constructs builtin Option.some"),
        none => panic("builtin positional enum ctor returned none"),
    }

    call_assert(assert, true,
        "first-class assert keeps Bool runtime marshalling")
    assert(call_json(json_stringify, "raw") == "\"raw\"",
        "implicit ring_ runtime fallback survives first-class extern lowering")
    call_print(print, 107)
    print("generic fn value wrapped dict: all ok")
}
