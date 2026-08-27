fn raise_text() -> Int with {fail<Str>} {
    fail.raise("caught")
}

fn main() {
    let score = raise_text() catch {
        error => error.len() + error.len()
    }
    assert(score == 12,
        "caught fresh error is live and remains owned through the arm")
    print("B_TRY_CAUGHT_RESULT_OK:${score}")
}
