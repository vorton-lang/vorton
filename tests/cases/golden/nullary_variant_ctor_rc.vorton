// A zero-field enum variant is Ident-shaped in HIR but fresh-owned at runtime.
// Exercise every ownership-sensitive position that previously either inserted
// an escape Clone or left an operand temporary unmaterialised.

enum Pulse {
    On,
    Off,
}

enum Packet {
    Empty,
    Value(Int),
}

const DEFAULT_PULSE: Pulse = Pulse::Off

fn take(p: Pulse) -> Int {
    match p {
        Pulse::On => 1,
        Pulse::Off => 0,
    }
}

// Direct function-tail escape.
fn always_on() -> Pulse {
    Pulse::On
}

// If-branch escape.
fn choose(flag: Bool) -> Pulse {
    if flag { Pulse::On } else { Pulse::Off }
}

// Match-branch escape.
fn flip(p: Pulse) -> Pulse {
    match p {
        Pulse::On => Pulse::Off,
        Pulse::Off => Pulse::On,
    }
}

// Negative control: an ordinary local Ident remains owner-bearing.
fn passthrough(p: Pulse) -> Pulse {
    p
}

// Negative controls for spelling-based constructor guesses. These bindings
// have the same enum type, collide with a variant leaf, or resemble the
// canonical generated symbol, but all are ordinary owner-bearing values.
fn shadow_variant(On: Pulse) -> Pulse {
    On
}

fn canonical_lookalike(Pulse_On: Pulse) -> Pulse {
    Pulse_On
}

// This locks in the current qualified-lookup fallback: when the leaf is
// shadowed, Pulse::On resolves to that lexical binding. It must remain
// owner-bearing even though the spelling is explicitly qualified.
fn qualified_shadow(On: Pulse) -> Pulse {
    Pulse::On
}

fn packet_score(packet: Packet) -> Int {
    match packet {
        Packet::Empty => 0,
        Packet::Value(value) => value,
    }
}

fn option_score(value: Int?) -> Int {
    match value {
        some(_) => 1,
        none => 0,
    }
}

fn main() {
    let mut total = 0
    for i in 0..8 {
        // Let-binding escape.
        let p = Pulse::On
        total = total + take(p)

        total = total + take(always_on())

        // Direct borrow-call operand: must be ANF-materialised and dropped.
        total = total + take(Pulse::Off)

        let q = choose(i % 2 == 0)
        total = total + take(q)
        total = total + take(flip(q))

        // Ordinary local/global enum Idents must keep their old borrow model.
        total = total + take(passthrough(p))
        total = total + take(DEFAULT_PULSE)
        total = total + take(shadow_variant(Pulse::On))
        total = total + take(canonical_lookalike(Pulse::On))
        total = total + take(qualified_shadow(Pulse::Off))

        // Positional-payload constructors share the same exact provenance
        // path; losing resolved_name here would break call lowering and sink
        // classification.
        total = total + packet_score(Packet::Value(i))

        // Built-in none needs canonical ctor provenance for C/LLVM codegen,
        // but is a borrowed runtime singleton and must not be classified as a
        // fresh nullary user-enum allocation.
        total = total + option_score(none)
    }
    print(total)
}
