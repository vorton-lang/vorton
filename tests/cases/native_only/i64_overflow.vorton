// I63 overflow wrap tests — oracle-blind (JS Number never wraps; native does).
//
// Tagged-pointer scheme means effective range is i63: -(2^62) to 2^62 - 1.
// Overflow wraps via 2's-complement on the underlying i64 tag word, then
// the unbox (arithmetic-shift-right 1) produces the wrapped i63 value.
// JS uses float64 for all numbers — no wrap, just growing magnitude.

fn main() {
    // --- compute i63 max = 2^62 - 1 = 4611686018427387903 ---
    let pow31 = 2147483648                    // 2^31
    let pow31_m1 = pow31 - 1                  // 2^31 - 1 = 2147483647
    let partial = pow31_m1 * pow31            // (2^31 - 1) * 2^31 = 2^62 - 2^31
    let max_i63 = partial + pow31_m1          // + (2^31 - 1) = 2^62 - 1
    print(max_i63)                            // 4611686018427387903

    // --- positive overflow: max + 1 wraps to min ---
    let overflow = max_i63 + 1
    print(overflow)                           // -4611686018427387904

    // --- negative underflow: min - 1 wraps to max ---
    let min_i63 = overflow                    // -(2^62)
    let underflow = min_i63 - 1
    print(underflow)                          // 4611686018427387903

    // --- double-positive overflow ---
    // max_i63 + max_i63 = 2*(2^62 - 1) = 2^63 - 2; tag = (2^63-2)<<1|1 = 2^64-3
    // i64 wraps: 2^64-3 mod 2^64 = -3; unbox: (-3)>>1 = -2
    let double_max = max_i63 + max_i63
    print(double_max)                         // -2

    // --- multiplication overflow ---
    let pow31_sq = pow31 * pow31              // 2^62 — overflows i63
    print(pow31_sq)                           // -4611686018427387904
}
