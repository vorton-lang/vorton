// B-104 D1 Stage 2 regression: EFFECT-OP ARG position — fresh-owned args to an
// effect op are materialised + scope-end-dropped.
//
// The balance this pins (the W1-era conservative hold-out, now closed):
//   * a tail-resumptive handler arm returning its PARAMETER verbatim
//     (`Echo.echo(s) => s`) is transformed in escape position — the tail is
//     Clone-wrapped, so the op's resume value is an independent dup.  The
//     materialised arg's scope-end drop releases the original; a missing dup
//     (or a wrong early drop) double-frees / UAFs → native crash, while the
//     golden .expected pins the values.
//   * handler arms COMBINING / storing args exercise the handler-side escape
//     Clones.
//   * the ABORT path (fail.raise with a constructed payload): the raise
//     longjmps past the materialised arg's drop (leak, not UAF) and the catch
//     arm still reads a valid value.

effect Echo {
    fn echo(s: Str) -> Str
    fn combine(a: Str, b: Int) -> Str
}

enum E { Boom(Str) }

fn speak() -> Str {
    // Fresh-owned args: interp string, call result, arithmetic box.
    let direct = Echo.echo("hi-${1 + 1}")
    let mixed = Echo.combine("v${2 + 3}".to_upper(), 10 + 7)
    "${direct}|${mixed}"
}

fn boom(n: Int) -> Int with {fail<E>} {
    if n > 2 { fail.raise(E::Boom("big-${n}")) }
    n
}

fn main() {
    let out = handle {
        speak()
    } with {
        Echo.echo(s) => s,
        Echo.combine(a, b) => "${a}+${b}",
    }
    print(out)

    let ok = boom(1) catch { _ => -1 }
    print("ok=${ok}")
    let caught = boom(9) catch {
        E::Boom(m) => 0 - m.len(),
        _ => -99,
    }
    print("caught=${caught}")
}
