use alpha::{apply_base as via_alpha, apply_alpha}
use beta::{apply_base as via_beta, apply_beta}

effect AlphaStep {
    fn apply(value: Int) -> Int
}

effect BetaStep {
    fn apply(value: Int) -> Int
}

fn alpha_step(value: Int) -> Int with {AlphaStep} {
    AlphaStep.apply(value)
}

fn beta_step(value: Int) -> Int with {BetaStep} {
    BetaStep.apply(value)
}

fn main() {
    let alpha = handle {
        apply_alpha(alpha_step, 1)
    } with {
        AlphaStep.apply(value) => value + 10,
    }
    let beta = handle {
        apply_beta(beta_step, 2)
    } with {
        BetaStep.apply(value) => value * 10,
    }
    let via_left = handle {
        via_alpha(alpha_step, 3)
    } with {
        AlphaStep.apply(value) => value + 10,
    }
    let via_right = handle {
        via_beta(beta_step, 4)
    } with {
        BetaStep.apply(value) => value * 10,
    }

    assert(alpha == 111 && beta == 220 &&
        via_left == 13 && via_right == 40,
        "dependency-local tails and same-origin delivery stay exact")
    print("D_EFFECT_DEP_ORDER_OK:${alpha}/${beta}/${via_left}/${via_right}")
}
