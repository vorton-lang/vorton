// B-107: tuple patterns must refine unresolved scrutinee types and establish
// lexical bindings before arm bodies are inferred.

fn picked(seed: Int) -> Int {
    if seed == 0 {
        consume(make_pair)
    } else {
        seed
    }
}

fn consume(factory) -> Int {
    match factory() {
        (picked, rest) => picked + rest
    }
}

fn make_pair() with {} {
    (20, 22)
}

fn sum_unannotated(pair) -> Int {
    match pair {
        (left, right) => left + right
    }
}

fn main() {
    print(consume(make_pair))
    print(sum_unannotated((19, 23)))
}
