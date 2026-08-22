use leaf::{Provider, provider}

fn use_default(
    callback: fn(Int) -> Option<Int> =
        fn(value: Int) -> Option<Int> {
            let local = fn(inner: Int) -> Option<Int> { some(inner) }
            let imported = provider().factory()
            match local(value) {
                some(inner) => imported(inner),
                none => none,
            }
        }
) -> Option<Int> {
    callback(7)
}

fn print_result(value: Option<Int>) {
    match value {
        some(result) => print(result),
        none => print(-1),
    }
}

fn main() {
    print_result(use_default())
    print_result(use_default())
}
