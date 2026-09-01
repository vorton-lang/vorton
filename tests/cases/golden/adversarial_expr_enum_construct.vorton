// B-100 P1.3 adversarial: enum variant construction + option wrapping.
// When constructing Some(f(x)), f(x) is evaluated first, then wrapped
// in the Some variant. If f(x) creates heap temporaries, those must
// be properly managed. Similarly, nested enum construction exercises
// the drop path for partially-built structures.

enum Result_ {
    Ok_(Str),
    Err_(Str),
}

fn make_ok(val: Int) -> Result_ {
    Result_::Ok_("value=${val}")
}

fn make_err(msg: Str) -> Result_ {
    Result_::Err_("error: ${msg}")
}

fn unwrap_result(r: Result_) -> Str {
    match r {
        Result_::Ok_(v) => v,
        Result_::Err_(e) => "ERR:${e}",
    }
}

fn maybe_find(xs: List<Int>, target: Int) -> Int? {
    let mut i = 0
    while i < xs.len() {
        if xs[i] == target {
            return some(xs[i])
        }
        i = i + 1
    }
    none
}

fn main() {
    // Some() wrapping a fresh string
    let opt1: Str? = some("hello ${1 + 2}")
    print("opt1=${opt1.unwrap_or("none")}")

    // Some() wrapping a function call result
    let opt2: Str? = some(unwrap_result(make_ok(42)))
    print("opt2=${opt2.unwrap_or("none")}")

    // none variant — no payload drop needed
    let opt3: Str? = none
    print("opt3=${opt3.unwrap_or("empty")}")

    // Custom enum construction with fresh string payload
    let r1 = make_ok(100)
    print("r1=${unwrap_result(r1)}")

    let r2 = make_err("not found")
    print("r2=${unwrap_result(r2)}")

    // Enum constructed and immediately matched (scrutinee is fresh)
    let msg = match make_ok(7) {
        Result_::Ok_(v) => "got: ${v}",
        Result_::Err_(e) => "err: ${e}",
    }
    print("immediate=${msg}")

    // Option from search — exercises Some(value) where value is from indexing
    let xs = [10, 20, 30, 40]
    let found = maybe_find(xs, 30)
    match found {
        some(v) => print("found=${v}"),
        none => print("not found"),
    }

    let missing = maybe_find(xs, 99)
    match missing {
        some(v) => print("found=${v}"),
        none => print("missing=true"),
    }

    // Enum in a list — multiple constructions
    let mut results: List<Result_> = []
    results.push(make_ok(1))
    results.push(make_err("bad"))
    results.push(make_ok(3))
    for r in results {
        print(unwrap_result(r))
    }

    // Nested option: Some(Some(x)) via function
    let opt_val = some(42)
    let inner = match opt_val {
        some(v) => "inner=${v}",
        none => "none",
    }
    print(inner)
}
