// This is intentionally check-only: the foreign symbol has no linked runtime
// implementation.  The unrelated type error keeps the runner in the negative
// lane while the forbidden contract proves the delayed extern validation
// accepted Int after the surrounding annotation supplied T.
extern fn pending_extern<T: Hash>(items: List<T>) -> T

fn main() {
    let _resolved: Int = pending_extern([])
    let _intentional_check_only_error: Int = "not linked"
}
