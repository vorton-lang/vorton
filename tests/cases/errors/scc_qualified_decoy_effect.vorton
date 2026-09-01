// Qualified callees must resolve before a same-spelled bare decoy in the SCC graph.
effect Pulse {
    fn hit() -> Unit
}

fn f() {}

fn main() {
    caller::call()
}

pub mod caller {
    pub fn call() {
        target::f()
    }
}

pub mod target {
    pub fn f() {
        Pulse.hit()
    }
}
