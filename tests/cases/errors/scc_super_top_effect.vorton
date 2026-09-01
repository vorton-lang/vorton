// A first-level inline super:: call targets the file-root function.  The root
// callee must participate in the same leaf-first precheck as inline nodes.
effect Pulse {
    fn hit() -> Unit
}

fn main() {
    outer::call()
}

pub mod outer {
    pub fn call() {
        super::leaf()
    }
}

fn leaf() {
    Pulse.hit()
}
