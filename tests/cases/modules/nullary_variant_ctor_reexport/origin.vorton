pub enum Signal {
    Ready,
    Waiting,
}

// A private module value may shadow the leaf binding after enum registration.
// Exporting Signal must reconstruct its public constructors from EnumDef rather
// than leaking this unrelated scheme into ModuleExports.
const Ready: Int = 99

pub fn local_ready_value() -> Int {
    Ready
}

pub mod local_probe {
    use super::{Ready as LocalReady}

    pub fn ready_value() -> Int {
        LocalReady
    }
}

pub enum Status {
    Up,
    Down,
}
