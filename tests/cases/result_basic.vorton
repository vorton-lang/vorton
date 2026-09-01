fn main() {
    let ok: Result<Int, Str> = Result::Ok(42)
    let err: Result<Int, Str> = Result::Err("oops")

    assert(ok.is_ok(), "Ok is_ok")
    assert(err.is_err(), "Err is_err")
    assert(ok.unwrap_or(0) == 42, "Ok unwrap_or")
    assert(err.unwrap_or(0) == 0, "Err unwrap_or")

    let mapped = ok.map(fn(x) { x * 2 })
    assert(mapped.unwrap_or(0) == 84, "map Ok")

    let mapped_err = err.map(fn(x) { x * 2 })
    assert(mapped_err.unwrap_or(0) == 0, "map Err passthrough")

    let chained = ok.and_then(fn(x) {
        if x > 0 { Result::Ok(x + 100) }
        else {
            let e: Result<Int, Str> = Result::Err("negative")
            e
        }
    })
    assert(chained.unwrap_or(0) == 142, "and_then Ok")

    print("result_basic: all tests passed")
}
