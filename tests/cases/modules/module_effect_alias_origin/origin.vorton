pub effect alias Bundle = {Signal}

// Alias identity must not depend on declaration order. Its body captures this
// module's Signal, never a consumer's same-spelled decoy.
pub effect Signal {
    fn number() -> Int
}

pub fn emit() -> Int with {Bundle} {
    Signal.number()
}
