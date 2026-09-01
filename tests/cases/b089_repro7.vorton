// B-089 G-b v7: single arm match with fail — minimal
struct P { pos: Int }

impl P {
    fn err(mut self) {
        fail.raise("error at ${self.pos.to_str()}")
    }

    fn step(mut self) -> Int {
        self.pos = self.pos + 1
        self.pos
    }

    fn do_work(mut self) -> Int {
        let v = self.step()
        match v {
            _ => {
                self.err()
                0
            }
        }
    }
}

fn main() {
    let mut p = P { pos: 0 }
    let r = p.do_work() catch { _ => 0 }
}
