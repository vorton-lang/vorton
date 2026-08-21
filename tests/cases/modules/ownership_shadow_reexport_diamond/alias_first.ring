use facade::{second as via_alias}
use leaf::{bump as direct}

pub fn run(mut value: Int) {
    via_alias(value)
    direct(value)
}
