// self:: must stay in the caller's exact inline scope for SCC effect propagation.
effect Pulse {
    fn hit() -> Unit
}

fn main() {
    scope::call()
}

pub mod scope {
    pub fn call() {
        self::leaf()
    }

    fn leaf() {
        Pulse.hit()
    }
}
