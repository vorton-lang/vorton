use origin::{Bundle, emit}

effect Signal {
    fn text() -> Str
}

// This declaration is checked even though main does not execute it. Bundle
// must expand to origin::Signal, never this module's same-spelled decoy.
pub fn forward() -> Int with {Bundle} {
    emit()
}
