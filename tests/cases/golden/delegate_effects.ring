// delegate forwarding a trait method that carries an io effect, with args, and a
// delegated method calling a sibling trait method. The forwarded calls must thread
// io evidence through the generated delegate stub on the LLVM backend, preserving
// stdout side-effect ordering.
//
// NOTE: forwarding a *custom* effect through a delegate (raised inside the
// delegated method, intercepted by a handler around the outer call) diverges on
// LLVM — the custom effect is silently dropped, because custom-effect handlers
// are broken on LLVM (recorded under B-087 in docs/worker_feedback.md).

trait Describe {
    fn describe(self) -> Str with {console}
    fn greet(self, who: Str) -> Str with {console}
}

struct Inner { name: Str, value: Int }

impl Describe for Inner {
    fn describe(self) -> Str with {console} {
        print("describing ${self.name}")
        "${self.name}=${self.value}"
    }
    fn greet(self, who: Str) -> Str with {console} {
        print("greeting ${who} from ${self.name}")
        "hi ${who}, I am ${self.name}"
    }
}

struct Wrapper { inner: Inner }

impl Wrapper {
    delegate inner: Describe
}

fn main() {
    let w = Wrapper { inner: Inner { name: "node", value: 7 } }

    // delegated no-arg method carrying io
    let r = w.describe()                     // prints "describing node"
    print("result: ${r}")                   // result: node=7

    // delegated method WITH an argument, also carrying io
    let g = w.greet("ada")                   // prints "greeting ada from node"
    print("greet: ${g}")                    // greet: hi ada, I am node

    // a second wrapper confirms the delegate stub is reusable
    let w2 = Wrapper { inner: Inner { name: "leaf", value: 99 } }
    print("result2: ${w2.describe()}")      // describing leaf / result2: leaf=99
    print("greet2: ${w2.greet("bo")}")      // greeting bo from leaf / greet2: hi bo, I am leaf
}
