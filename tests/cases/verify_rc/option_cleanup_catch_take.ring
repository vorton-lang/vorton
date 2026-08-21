// The normal catch arm is state-neutral.  A post-planner mutation prepends one
// exact outer-slot Drop, which the verifier must reject before snapshot restore.

struct CatchResource {
    id: Int
}

impl Drop for CatchResource {
    fn drop(self) {}
}

fn raise_catch_option() -> Bool with {fail<Int>} {
    fail.raise(1)
}

fn main() {
    let mut wrapped: Option<CatchResource> = none
    wrapped = some(CatchResource { id: 1 })
    raise_catch_option() catch {
        _ => false
    }
    print(wrapped.is_some())
}
