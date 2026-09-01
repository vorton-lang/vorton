// super:: must remove one inline scope level for SCC effect propagation.
effect Pulse {
    fn hit() -> Unit
}

fn main() {
    outer::child::call()
}

pub mod outer {
    pub mod child {
        pub fn call() {
            super::leaf()
        }
    }

    fn leaf() {
        Pulse.hit()
    }
}
