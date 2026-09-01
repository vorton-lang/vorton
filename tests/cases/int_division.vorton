fn main() {
    assert(7 / 2 == 3, "int div truncates")
    assert(10 / 3 == 3, "int div truncates 2")
    assert(-7 / 2 == -3, "negative int div toward zero")
    assert(6 / 3 == 2, "exact div unchanged")
    assert(1 / 3 == 0, "small div truncates to zero")
    assert(100 / 7 == 14, "larger div")

    // Float division should NOT be truncated
    assert(7.0 / 2.0 == 3.5, "float div not truncated")

    // Modulo should still work correctly
    assert(7 % 2 == 1, "int mod")
    assert(10 % 3 == 1, "int mod 2")

    print("int_division: all tests passed")
}
