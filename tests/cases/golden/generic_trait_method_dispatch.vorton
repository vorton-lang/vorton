// B-092: generic user-defined trait-method dispatch through a <T: Trait> bound.
// The method is reached via dict-passing (monomorphized dict): run<T: Greet>(x)
// loads the Greet dict's method slot and calls it on x. The LLVM backend used to
// store the bare impl method fn (direct ABI fn(self)) in the dict but invoke it
// through the closure ABI fn(env, self), passing env(=null) as the receiver. Any
// method reading self (e.g. self.name) then dereferenced null and crashed in
// str_from_cstr. Fixed by emitting an env-first thunk for each dict method slot.

trait Greet { fn greet(self) -> Str }

struct En { name: Str }
impl Greet for En { fn greet(self) -> Str { self.name } }   // reads self.<field>

struct Fr {}
impl Greet for Fr { fn greet(self) -> Str { "bonjour" } }   // ignores self

fn run<T: Greet>(x: T) -> Str { x.greet() }

fn main() {
    print(run(En{ name: "hello" }))   // hello   (self.name on a real receiver)
    print(run(Fr{}))                  // bonjour (constant, self unused)
}
