// expect-error: E0803
// B-002p1: Drop::drop must not have the fail effect — unwinding out of a
// scope-end drop has no defined resume point (E0803).
struct Res { id: Int }
impl Drop for Res {
    fn drop(self) with {fail} {
        fail.raise("cannot fail in drop")
    }
}
fn main() {
    let r = Res { id: 1 }
    print(r.id)
}
