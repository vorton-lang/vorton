struct ExternOwner {}

extern fn ring_probe_top(value: Int) -> Option<Int>

trait ExternProbe {
    fn ring_probe_member(self) -> Option<Int>
}

impl ExternProbe for ExternOwner {
    extern fn ring_probe_member(self) -> Option<Int>
}

fn main() {
    print(1)
}
