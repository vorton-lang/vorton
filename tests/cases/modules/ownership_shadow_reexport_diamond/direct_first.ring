use leaf::{bump as direct}
use facade::{first as via_alias}

pub fn run(mut value: Int) {
    direct(value)
    via_alias(value)
}
