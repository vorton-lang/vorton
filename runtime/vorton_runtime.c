/* Vorton C11 runtime. The compiler places this text at the start of every
 * generated translation unit. */

#include <float.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* With VT_CHECK_LEAKS defined, the runtime counts live heap strings and a\n * program that ends normally reports any string it did not release exactly\n * once. Tests build with it. */
#ifdef VT_CHECK_LEAKS
static int64_t vt_live_strings = 0;
#define VT_COUNT(delta) (vt_live_strings += (delta))
#else
#define VT_COUNT(delta) ((void)0)
#endif

/* An immutable UTF-8 string. A negative `rc` marks a static literal that is
 * never counted or freed. */
typedef struct vt_str {
    int64_t rc;
    int64_t len;
    const char *data;
} vt_str;

static _Noreturn void vt_panic(const char *message) {
    fflush(stdout);
    fprintf(stderr, "panic: %s\n", message);
    exit(101);
}

static _Noreturn void vt_panic_str(const vt_str *message) {
    fflush(stdout);
    fputs("panic: ", stderr);
    fwrite(message->data, 1, (size_t)message->len, stderr);
    fputc('\n', stderr);
    exit(101);
}

/* Reached only if the compiler wrongly judged a `match` exhaustive. */
static _Noreturn void vt_unreachable(void) {
    vt_panic("internal error: no `match` arm applies");
}

static _Noreturn void vt_panic_assert(const vt_str *message) {
    fflush(stdout);
    fputs("panic: assertion failed: ", stderr);
    fwrite(message->data, 1, (size_t)message->len, stderr);
    fputc('\n', stderr);
    exit(101);
}

static vt_str *vt_str_alloc(int64_t len) {
    vt_str *result = malloc(sizeof(vt_str) + (size_t)len + 1);
    if (result == NULL) {
        vt_panic("out of memory");
    }
    char *data = (char *)(result + 1);
    data[len] = '\0';
    VT_COUNT(1);
    result->rc = 1;
    result->len = len;
    result->data = data;
    return result;
}

static void vt_str_retain(vt_str *value) {
    if (value->rc >= 0) {
        value->rc += 1;
    }
}

static void vt_str_release(vt_str *value) {
    if (value->rc > 0 && --value->rc == 0) {
        VT_COUNT(-1);
        free(value);
    }
}

static vt_str *vt_str_from_bytes(const char *bytes, size_t len) {
    vt_str *result = vt_str_alloc((int64_t)len);
    memcpy((char *)result->data, bytes, len);
    return result;
}

static vt_str *vt_str_join(int count, vt_str *const *parts) {
    int64_t len = 0;
    for (int index = 0; index < count; index += 1) {
        len += parts[index]->len;
    }
    vt_str *result = vt_str_alloc(len);
    char *cursor = (char *)result->data;
    for (int index = 0; index < count; index += 1) {
        memcpy(cursor, parts[index]->data, (size_t)parts[index]->len);
        cursor += parts[index]->len;
    }
    return result;
}

static int vt_str_compare(const vt_str *left, const vt_str *right) {
    int64_t shorter = left->len < right->len ? left->len : right->len;
    int order = memcmp(left->data, right->data, (size_t)shorter);
    if (order != 0) {
        return order < 0 ? -1 : 1;
    }
    return left->len < right->len ? -1 : left->len > right->len ? 1 : 0;
}

static bool vt_str_eq(const vt_str *left, const vt_str *right) {
    return left->len == right->len && memcmp(left->data, right->data, (size_t)left->len) == 0;
}

static int64_t vt_int_add(int64_t left, int64_t right) {
    int64_t result;
    if (__builtin_add_overflow(left, right, &result)) {
        vt_panic("integer overflow");
    }
    return result;
}

static int64_t vt_int_sub(int64_t left, int64_t right) {
    int64_t result;
    if (__builtin_sub_overflow(left, right, &result)) {
        vt_panic("integer overflow");
    }
    return result;
}

static int64_t vt_int_mul(int64_t left, int64_t right) {
    int64_t result;
    if (__builtin_mul_overflow(left, right, &result)) {
        vt_panic("integer overflow");
    }
    return result;
}

static int64_t vt_int_div(int64_t left, int64_t right) {
    if (right == 0) {
        vt_panic("division by zero");
    }
    if (left == INT64_MIN && right == -1) {
        vt_panic("integer overflow");
    }
    return left / right;
}

static int64_t vt_int_rem(int64_t left, int64_t right) {
    if (right == 0) {
        vt_panic("division by zero");
    }
    if (left == INT64_MIN && right == -1) {
        vt_panic("integer overflow");
    }
    return left % right;
}

static int64_t vt_int_neg(int64_t value) {
    if (value == INT64_MIN) {
        vt_panic("integer overflow");
    }
    return -value;
}

static vt_str *vt_int_to_str(int64_t value) {
    char buffer[32];
    int len = snprintf(buffer, sizeof buffer, "%lld", (long long)value);
    return vt_str_from_bytes(buffer, (size_t)len);
}

/* Formats a binary64 value like ECMAScript Number::toString: the shortest
 * digit string that reads back as the same value, in positional notation for
 * decimal exponents from -6 to 20 and in exponent notation otherwise. */
static vt_str *vt_float_to_str(double value) {
    char out[64];
    size_t len = 0;
    if (isnan(value)) {
        return vt_str_from_bytes("NaN", 3);
    }
    if (value == 0.0) {
        return vt_str_from_bytes("0", 1);
    }
    if (value < 0) {
        out[len++] = '-';
        value = -value;
    }
    if (isinf(value)) {
        memcpy(out + len, "Infinity", 8);
        return vt_str_from_bytes(out, len + 8);
    }
    char scientific[40];
    for (int precision = 1; precision <= 17; precision += 1) {
        snprintf(scientific, sizeof scientific, "%.*e", precision - 1, value);
        if (strtod(scientific, NULL) == value) {
            break;
        }
    }
    char digits[20];
    int count = 0;
    char *cursor = scientific;
    for (; *cursor != 'e'; cursor += 1) {
        if (*cursor != '.') {
            digits[count++] = *cursor;
        }
    }
    while (count > 1 && digits[count - 1] == '0') {
        count -= 1;
    }
    int point = atoi(cursor + 1) + 1;
    if (count <= point && point <= 21) {
        memcpy(out + len, digits, (size_t)count);
        len += (size_t)count;
        for (int index = count; index < point; index += 1) {
            out[len++] = '0';
        }
    } else if (0 < point && point <= 21) {
        memcpy(out + len, digits, (size_t)point);
        len += (size_t)point;
        out[len++] = '.';
        memcpy(out + len, digits + point, (size_t)(count - point));
        len += (size_t)(count - point);
    } else if (-6 < point && point <= 0) {
        out[len++] = '0';
        out[len++] = '.';
        for (int index = point; index < 0; index += 1) {
            out[len++] = '0';
        }
        memcpy(out + len, digits, (size_t)count);
        len += (size_t)count;
    } else {
        out[len++] = digits[0];
        if (count > 1) {
            out[len++] = '.';
            memcpy(out + len, digits + 1, (size_t)(count - 1));
            len += (size_t)(count - 1);
        }
        len += (size_t)snprintf(out + len, sizeof out - len, "e%c%d", point > 0 ? '+' : '-',
                                abs(point - 1));
    }
    return vt_str_from_bytes(out, len);
}

static vt_str vt_str_true = {-1, 4, "true"};
static vt_str vt_str_false = {-1, 5, "false"};

static vt_str *vt_bool_to_str(bool value) {
    return value ? &vt_str_true : &vt_str_false;
}

static void vt_print(const vt_str *value) {
    fwrite(value->data, 1, (size_t)value->len, stdout);
    fputc('\n', stdout);
}

/* Runs after the program's main returns normally. */
static void vt_finish(void) {
#ifdef VT_CHECK_LEAKS
    if (vt_live_strings != 0) {
        fflush(stdout);
        fprintf(stderr, "leak check: %lld strings still live\n", (long long)vt_live_strings);
        exit(102);
    }
#endif
}
