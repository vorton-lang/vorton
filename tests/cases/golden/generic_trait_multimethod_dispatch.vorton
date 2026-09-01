// B-092 variant: multi-method user trait + multiple impl types dispatched through a
// <T: Trait> bound. Exercises dict slot-index resolution: each method must land in
// its own dict slot (name=0, sound=1, legs=2, matching emit_trait_dict's order),
// not all fall through to slot 0. Methods mix Str/Int returns and self field reads.

trait Animal {
    fn name(self) -> Str
    fn sound(self) -> Str
    fn legs(self) -> Int
}

struct Dog { who: Str }
impl Animal for Dog {
    fn name(self) -> Str { self.who }
    fn sound(self) -> Str { "woof" }
    fn legs(self) -> Int { 4 }
}

struct Bird {}
impl Animal for Bird {
    fn name(self) -> Str { "bird" }
    fn sound(self) -> Str { "tweet" }
    fn legs(self) -> Int { 2 }
}

fn describe<T: Animal>(a: T) -> Str {
    "${a.name()} says ${a.sound()} and has ${a.legs()} legs"
}

fn main() {
    print(describe(Dog{ who: "Rex" }))   // Rex says woof and has 4 legs
    print(describe(Bird{}))              // bird says tweet and has 2 legs
}
