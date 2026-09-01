// expect-error: E0801
struct Handle { id: Int }
impl Drop for Handle {
    fn drop(self) { print("drop") }
}

fn main() {
    let h = Handle { id: 1 }
    let h2 = h    // move
    print("${h.id}")   // error: use of moved value
}
