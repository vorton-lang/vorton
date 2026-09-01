fn maybe_text(should_fail: Bool) -> Str with {fail<Str>} {
    if should_fail {
        fail.raise("caught")
    }
    "success"
}

fn main() {
    let protected = maybe_text(false) catch {
        error => "unexpected:${error}"
    }
    let caught = maybe_text(true) catch {
        error => "${error}:${error}"
    }
    assert(protected == "success",
        "protected result stays owned on the success successor")
    assert(caught == "caught:caught",
        "caught fresh error stays owned through the caught successor")
    print("B_TRY_RESULT_PATHS_OK:${protected}/${caught}")
}
