use left::{Payload as DirectLeft}
use right::{Payload as DirectRight}
use facade::{LeftPayload as FacadeLeft}
use middle::{ThroughRight as TransitiveRight}

fn main() {
    print(json_stringify(DirectLeft { left: 1 }))
    print(json_stringify(FacadeLeft { left: 2 }))
    print(json_stringify(DirectRight { right: "direct", count: 3 }))
    print(json_stringify(TransitiveRight { right: "transitive", count: 4 }))
}
