// B-083 #1 regression: a closure stored in a collection captures a heap value
// that is ALSO used after the closure is created.  The Perceus pass must dup the
// captured variable at closure construction (the LLVM codegen stores the bare
// pointer into the env without a dup).  If the dup is missing, the env holds a
// dangling pointer once the original binding is later consumed/dropped → UAF or
// corrupted output under the LLVM backend.

fn run(f: fn() -> Str) -> Str {
    f()
}

fn main() {
    // `tag` is a heap Str captured by two closures; it is ALSO used again
    // (printed) after the closures are built → non-last use → must dup.
    let tag = "T-${100 + 23}"

    let mut fns: List<fn() -> Str> = []
    fns.push(fn() -> Str { "a:${tag}" })
    fns.push(fn() -> Str { "b:${tag}" })

    // Use the original AFTER the closures captured it.
    print("orig: ${tag}")

    // Now invoke the captured closures — they must still see a live `tag`.
    for f in fns {
        print(run(f))
    }

    // And the original is still usable here too.
    print("again: ${tag}")
}
