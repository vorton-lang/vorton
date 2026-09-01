// Refinement recurses through List<fn(...)>; the nested callback must still
// carry the handler's Str payload contract.

fn recover_nested(callbacks: List<fn() -> Int>) -> Int {
    handle {
        let callback = callbacks[0]
        callback()
    } with {
        fail.raise(message: Str) => message.len(),
    }
}

fn raise_number() -> Int with {fail<Int>} {
    fail.raise(7)
}

fn main() {
    recover_nested([fn() -> Int { raise_number() }])
}
