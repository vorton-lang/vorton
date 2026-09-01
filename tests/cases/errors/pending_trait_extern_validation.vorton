// Checker-only: the foreign ABI receives no dictionary, but the call must
// still validate its bound after the result annotation supplies T.
trait Marker {
    fn marker(self) -> Int
}

struct NoMarker {}

extern fn pending_extern<T: Marker>(items: List<T>) -> T

fn main() {
    let _invalid: NoMarker = pending_extern([])
}
