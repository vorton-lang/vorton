// #161 Str lte/gte + #168 Float mod — codegen regression test.

fn main() {
    // --- Str <= (Lte) ---
    print("abc_le_abd=${("abc" <= "abd")}")   // abc_le_abd=true
    print("abd_le_abc=${("abd" <= "abc")}")   // abd_le_abc=false
    print("abc_le_abc=${("abc" <= "abc")}")   // abc_le_abc=true  (equal)
    print("a_le_ab=${("a" <= "ab")}")         // a_le_ab=true     (prefix shorter)
    print("ab_le_a=${("ab" <= "a")}")         // ab_le_a=false

    // --- Str >= (Gte) ---
    print("abc_ge_abc=${("abc" >= "abc")}")   // abc_ge_abc=true  (equal)
    print("abd_ge_abc=${("abd" >= "abc")}")   // abd_ge_abc=true
    print("abc_ge_abd=${("abc" >= "abd")}")   // abc_ge_abd=false
    print("ab_ge_a=${("ab" >= "a")}")         // ab_ge_a=true
    print("a_ge_ab=${("a" >= "ab")}")         // a_ge_ab=false

    // --- Float mod (FRem) ---
    let r1 = 1.5 % 0.5
    print("fmod_1.5_0.5=${r1}")               // fmod_1.5_0.5=0
    let r2 = 7.5 % 2.0
    print("fmod_7.5_2.0=${r2}")               // fmod_7.5_2.0=1.5
    let r3 = 10.0 % 3.0
    print("fmod_10.0_3.0=${r3}")              // fmod_10.0_3.0=1
    let r4 = 5.5 % 5.5
    print("fmod_5.5_5.5=${r4}")               // fmod_5.5_5.5=0
}
