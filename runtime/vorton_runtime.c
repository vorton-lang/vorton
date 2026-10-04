/* Vorton C11 runtime. The compiler places this text at the start of every
 * generated translation unit. */

#include <float.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

/* With VT_CHECK_LEAKS defined, the runtime counts live heap blocks (strings
 * and list buffers), and a program that ends normally reports any block it
 * did not free exactly once. Tests build with it. */
#ifdef VT_CHECK_LEAKS
static int64_t vt_live_blocks = 0;
#define VT_COUNT(delta) (vt_live_blocks += (delta))
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

/* A moved-from or never-assigned string is NULL; retaining or releasing it
 * does nothing. */
static void vt_str_retain(vt_str *value) {
    if (value != NULL && value->rc >= 0) {
        value->rc += 1;
    }
}

static void vt_str_release(vt_str *value) {
    if (value != NULL && value->rc > 0 && --value->rc == 0) {
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
/* Whether `mantissa` times ten to `exponent` reads back as `value`. */
static bool vt_float_reads_back(uint64_t mantissa, int exponent, double value) {
    char text[40];
    snprintf(text, sizeof text, "%llue%d", (unsigned long long)mantissa, exponent);
    return strtod(text, NULL) == value;
}
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
    /* The fewest digits that read back as `value`: `mantissa` times ten to
     * `exponent`. */
    uint64_t mantissa = 0;
    int exponent = 0;
    for (int precision = 1; precision <= 17; precision += 1) {
        char scientific[40];
        snprintf(scientific, sizeof scientific, "%.*e", precision - 1, value);
        mantissa = 0;
        char *cursor = scientific;
        for (; *cursor != 'e'; cursor += 1) {
            if (*cursor != '.') {
                mantissa = mantissa * 10 + (uint64_t)(*cursor - '0');
            }
        }
        exponent = atoi(cursor + 1) - (precision - 1);
        if (vt_float_reads_back(mantissa, exponent, value)) {
            break;
        }
        /* The nearest decimal with this many digits does not read back. At
         * a power of two the values that do are not centred on `value`, so
         * the next decimal on the other side may: it is the only other
         * candidate with this many digits. */
        uint64_t other = strtod(scientific, NULL) > value ? mantissa - 1 : mantissa + 1;
        if (vt_float_reads_back(other, exponent, value)) {
            mantissa = other;
            break;
        }
    }
    char digits[24];
    int count = snprintf(digits, sizeof digits, "%llu", (unsigned long long)mantissa);
    int point = exponent + count;
    while (count > 1 && digits[count - 1] == '0') {
        count -= 1;
    }
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

/* Resizes a list buffer to cap elements of size bytes. */
static void *vt_items_resize(void *items, int64_t cap, size_t size) {
    void *result = realloc(items, (size_t)cap * size);
    if (result == NULL) {
        vt_panic("out of memory");
    }
    if (items == NULL) {
        VT_COUNT(1);
    }
    return result;
}

static void vt_items_free(void *items) {
    if (items != NULL) {
        VT_COUNT(-1);
        free(items);
    }
}

static void vt_check_index(int64_t index, int64_t len) {
    if (index < 0 || index >= len) {
        vt_panic("index out of bounds");
    }
}

/* `Str` methods. Positions and lengths count the bytes of UTF-8. */

/* The first position at or after `from` where `part` occurs in `text`, or
 * -1. A short pattern is compared at each position, a few bytes each; a
 * longer one is searched with Knuth-Morris-Pratt, so the work stays linear
 * in the lengths of the text and the pattern. */
static int64_t vt_str_find_from(const vt_str *text, const vt_str *part, int64_t from) {
    int64_t len = part->len;
    if (len <= 16) {
        for (int64_t at = from; at + len <= text->len; at += 1) {
            if (memcmp(text->data + at, part->data, (size_t)len) == 0) {
                return at;
            }
        }
        return -1;
    }
    if (len > text->len - from) {
        return -1;
    }
    /* border[i] is the length of the longest proper prefix of the first
     * i + 1 bytes of `part` that is also their suffix. */
    int64_t *border = vt_items_resize(NULL, len, sizeof(int64_t));
    border[0] = 0;
    for (int64_t i = 1, matched = 0; i < len; i += 1) {
        while (matched > 0 && part->data[i] != part->data[matched]) {
            matched = border[matched - 1];
        }
        if (part->data[i] == part->data[matched]) {
            matched += 1;
        }
        border[i] = matched;
    }
    int64_t found = -1;
    for (int64_t at = from, matched = 0; at < text->len; at += 1) {
        while (matched > 0 && text->data[at] != part->data[matched]) {
            matched = border[matched - 1];
        }
        if (text->data[at] == part->data[matched]) {
            matched += 1;
        }
        if (matched == len) {
            found = at - len + 1;
            break;
        }
    }
    vt_items_free(border);
    return found;
}

static bool vt_str_starts_with(const vt_str *text, const vt_str *prefix) {
    return prefix->len <= text->len &&
           memcmp(text->data, prefix->data, (size_t)prefix->len) == 0;
}

static bool vt_str_ends_with(const vt_str *text, const vt_str *suffix) {
    return suffix->len <= text->len &&
           memcmp(text->data + text->len - suffix->len, suffix->data, (size_t)suffix->len) == 0;
}

/* Whether byte position `at` starts a character or ends the text. */
static bool vt_str_is_boundary(const vt_str *text, int64_t at) {
    return at == text->len || ((unsigned char)text->data[at] & 0xC0) != 0x80;
}

static vt_str *vt_str_slice(const vt_str *text, int64_t start, int64_t end) {
    if (start < 0 || start > end || end > text->len) {
        vt_panic("slice out of bounds");
    }
    if (!vt_str_is_boundary(text, start) || !vt_str_is_boundary(text, end)) {
        vt_panic("slice is not on a character boundary");
    }
    return vt_str_from_bytes(text->data + start, (size_t)(end - start));
}

/* Appends a new string of `len` bytes from `bytes` to the array `*parts`
 * of `*count` strings with room for `*cap`. */
static void vt_str_add_part(vt_str ***parts, int64_t *count, int64_t *cap, const char *bytes,
                            int64_t len) {
    if (*count == *cap) {
        *cap = *cap == 0 ? 4 : *cap * 2;
        *parts = vt_items_resize(*parts, *cap, sizeof(vt_str *));
    }
    (*parts)[*count] = vt_str_from_bytes(bytes, (size_t)len);
    *count += 1;
}

/* Splits `text` at every `separator`. The parts go to `*parts`, an array
 * that the caller frees with `vt_items_free` after taking the strings; the
 * result is their number. */
static int64_t vt_str_split(const vt_str *text, const vt_str *separator, vt_str ***parts) {
    if (separator->len == 0) {
        vt_panic("empty separator");
    }
    int64_t count = 0;
    int64_t cap = 0;
    int64_t from = 0;
    *parts = NULL;
    for (;;) {
        int64_t at = vt_str_find_from(text, separator, from);
        int64_t end = at < 0 ? text->len : at;
        vt_str_add_part(parts, &count, &cap, text->data + from, end - from);
        if (at < 0) {
            return count;
        }
        from = at + separator->len;
    }
}

/* Splits `text` into its characters, like `vt_str_split`. */
static int64_t vt_str_chars(const vt_str *text, vt_str ***parts) {
    int64_t count = 0;
    int64_t cap = 0;
    *parts = NULL;
    for (int64_t at = 0; at < text->len;) {
        int64_t next = at + 1;
        while (!vt_str_is_boundary(text, next)) {
            next += 1;
        }
        vt_str_add_part(parts, &count, &cap, text->data + at, next - at);
        at = next;
    }
    return count;
}

static bool vt_is_space(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

static vt_str *vt_str_trim(const vt_str *text) {
    int64_t start = 0;
    int64_t end = text->len;
    while (start < end && vt_is_space(text->data[start])) {
        start += 1;
    }
    while (end > start && vt_is_space(text->data[end - 1])) {
        end -= 1;
    }
    return vt_str_from_bytes(text->data + start, (size_t)(end - start));
}

static vt_str *vt_str_replace(const vt_str *text, const vt_str *from, const vt_str *to) {
    if (from->len == 0) {
        vt_panic("empty pattern");
    }
    int64_t count = 0;
    for (int64_t at = vt_str_find_from(text, from, 0); at >= 0;
         at = vt_str_find_from(text, from, at + from->len)) {
        count += 1;
    }
    int64_t growth = to->len - from->len;
    if (count > 0 && growth > 0 && growth > (INT64_MAX - text->len) / count) {
        vt_panic("string too long");
    }
    vt_str *result = vt_str_alloc(text->len + count * growth);    char *out = (char *)result->data;
    int64_t position = 0;
    for (int64_t at = vt_str_find_from(text, from, 0); at >= 0;
         at = vt_str_find_from(text, from, position)) {
        memcpy(out, text->data + position, (size_t)(at - position));
        out += at - position;
        memcpy(out, to->data, (size_t)to->len);
        out += to->len;
        position = at + from->len;
    }
    memcpy(out, text->data + position, (size_t)(text->len - position));
    return result;
}

static vt_str *vt_str_repeat(const vt_str *text, int64_t count) {
    if (count < 0) {
        vt_panic("negative repeat count");
    }
    /* The work follows the length of the result, which is empty here
     * however large the count. */
    if (text->len == 0 || count == 0) {
        return vt_str_alloc(0);
    }
    if (count > INT64_MAX / text->len) {
        vt_panic("string too long");
    }
    vt_str *result = vt_str_alloc(text->len * count);
    char *out = (char *)result->data;
    for (int64_t i = 0; i < count; i += 1) {
        memcpy(out + i * text->len, text->data, (size_t)text->len);
    }
    return result;
}

/* Converts ASCII letters to upper case, or to lower case. */
static vt_str *vt_str_case(const vt_str *text, bool upper) {
    vt_str *result = vt_str_alloc(text->len);
    char *out = (char *)result->data;
    for (int64_t i = 0; i < text->len; i += 1) {
        char c = text->data[i];
        if (upper && c >= 'a' && c <= 'z') {
            c = (char)(c - 'a' + 'A');
        } else if (!upper && c >= 'A' && c <= 'Z') {
            c = (char)(c - 'A' + 'a');
        }
        out[i] = c;
    }
    return result;
}

/* Parses an optionally signed decimal `Int` into `*out`. The digits
 * accumulate as a negative number so the smallest `Int` fits. */
static bool vt_str_parse_int(const vt_str *text, int64_t *out) {
    int64_t i = 0;
    bool negative = false;
    if (i < text->len && (text->data[i] == '-' || text->data[i] == '+')) {
        negative = text->data[i] == '-';
        i += 1;
    }
    if (i == text->len) {
        return false;
    }
    int64_t value = 0;
    for (; i < text->len; i += 1) {
        char c = text->data[i];
        if (c < '0' || c > '9') {
            return false;
        }
        int digit = c - '0';
        if (value < (INT64_MIN + digit) / 10) {
            return false;
        }
        value = value * 10 - digit;
    }
    if (!negative) {
        if (value == INT64_MIN) {
            return false;
        }
        value = -value;
    }
    *out = value;
    return true;
}

/* A `Range<Int>` value: `start..end`, or `start..=end` when `inclusive`. */
typedef struct vt_range {
    int64_t start;
    int64_t end;
    bool inclusive;
} vt_range;

/* Three-way comparisons for `<`, `>`, `<=` and `>=` on structs, enums and
 * tuples: -1, 0 or 1, or 2 when the operands are unordered (a NaN). */
static int vt_cmp_int(int64_t left, int64_t right) {
    return (left > right) - (left < right);
}

static int vt_cmp_float(double left, double right) {
    if (left < right) {
        return -1;
    }
    if (left > right) {
        return 1;
    }
    return left == right ? 0 : 2;
}

static int vt_cmp_str(const vt_str *left, const vt_str *right) {
    int result = vt_str_compare(left, right);
    return (result > 0) - (result < 0);
}

/* Hashes for map keys. */
static uint64_t vt_hash_mix(uint64_t hash, uint64_t value) {
    return hash ^ (value + 0x9e3779b97f4a7c15ULL + (hash << 6) + (hash >> 2));
}

static uint64_t vt_hash_int(int64_t value) {
    uint64_t x = (uint64_t)value + 0x9e3779b97f4a7c15ULL;
    x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ULL;
    x = (x ^ (x >> 27)) * 0x94d049bb133111ebULL;
    return x ^ (x >> 31);
}

static uint64_t vt_hash_str(const vt_str *value) {
    uint64_t hash = 0xcbf29ce484222325ULL;
    for (int64_t i = 0; i < value->len; i += 1) {
        hash = (hash ^ (unsigned char)value->data[i]) * 0x100000001b3ULL;
    }
    return hash;
}

/* How a map stores its entries: the sizes of keys and values, and how keys
 * hash and compare. */
typedef struct vt_map_type {
    size_t key_size;
    size_t value_size;
    uint64_t (*hash)(const void *key);
    bool (*eq)(const void *left, const void *right);
} vt_map_type;

/* A map that keeps its entries in insertion order. Entry `i` has its key at
 * `keys + i * key_size` and its value at `values + i * value_size`; a removed
 * entry stays behind as a gap (`live[i]` is false) until the map is rebuilt.
 * `slots` finds entries by hash with open addressing: -1 marks an empty slot
 * and -2 the slot of a removed entry. Every entry, live or removed, holds one
 * slot, and `slot_cap` is at least twice `cap`, so a search always reaches an
 * empty slot. A zeroed map is empty. */
typedef struct vt_map {
    int64_t len;
    int64_t used;
    int64_t cap;
    char *keys;
    char *values;
    bool *live;
    int64_t *slots;
    int64_t slot_cap;
} vt_map;

static int64_t vt_map_find(const vt_map *map, const vt_map_type *type, const void *key) {
    if (map->len == 0) {
        return -1;
    }
    uint64_t mask = (uint64_t)map->slot_cap - 1;
    for (uint64_t slot = type->hash(key) & mask;; slot = (slot + 1) & mask) {
        int64_t entry = map->slots[slot];
        if (entry == -1) {
            return -1;
        }
        if (entry >= 0 && type->eq(map->keys + (size_t)entry * type->key_size, key)) {
            return entry;
        }
    }
}

/* Records entry `entry` in the first free slot for its key. */
static void vt_map_place(vt_map *map, const vt_map_type *type, int64_t entry) {
    uint64_t mask = (uint64_t)map->slot_cap - 1;
    uint64_t slot = type->hash(map->keys + (size_t)entry * type->key_size) & mask;
    while (map->slots[slot] >= 0) {
        slot = (slot + 1) & mask;
    }
    map->slots[slot] = entry;
}

/* Closes the gaps of removed entries, grows to room for `need` entries, and
 * rebuilds the slots. */
static void vt_map_rebuild(vt_map *map, const vt_map_type *type, int64_t need) {
    int64_t to = 0;
    for (int64_t from = 0; from < map->used; from += 1) {
        if (!map->live[from]) {
            continue;
        }
        if (to != from) {
            memcpy(map->keys + (size_t)to * type->key_size,
                   map->keys + (size_t)from * type->key_size, type->key_size);
            memcpy(map->values + (size_t)to * type->value_size,
                   map->values + (size_t)from * type->value_size, type->value_size);
            map->live[to] = true;
        }
        to += 1;
    }
    map->used = to;
    if (need > map->cap) {
        int64_t cap = map->cap == 0 ? 4 : map->cap;
        while (cap < need) {
            cap *= 2;
        }
        map->keys = vt_items_resize(map->keys, cap, type->key_size);
        map->values = vt_items_resize(map->values, cap, type->value_size);
        map->live = vt_items_resize(map->live, cap, sizeof(bool));
        map->cap = cap;
        int64_t slot_cap = 8;
        while (slot_cap < 2 * cap) {
            slot_cap *= 2;
        }
        vt_items_free(map->slots);
        map->slots = vt_items_resize(NULL, slot_cap, sizeof(int64_t));
        map->slot_cap = slot_cap;
    }
    for (int64_t slot = 0; slot < map->slot_cap; slot += 1) {
        map->slots[slot] = -1;
    }
    for (int64_t entry = 0; entry < map->used; entry += 1) {
        vt_map_place(map, type, entry);
    }
}

/* Adds `key` with `value`, both moved into the map. If the key is present,
 * only its value is replaced: the old value is moved to `old`, `key` stays
 * with the caller, and the result is true. */
static bool vt_map_insert(vt_map *map, const vt_map_type *type, const void *key,
                          const void *value, void *old) {
    int64_t entry = vt_map_find(map, type, key);
    if (entry >= 0) {
        char *place = map->values + (size_t)entry * type->value_size;
        memcpy(old, place, type->value_size);
        memcpy(place, value, type->value_size);
        return true;
    }
    if (map->used == map->cap) {
        int64_t need = map->len + 1;
        vt_map_rebuild(map, type, need * 2 > map->cap ? need * 2 : need);
    }
    entry = map->used;
    memcpy(map->keys + (size_t)entry * type->key_size, key, type->key_size);
    memcpy(map->values + (size_t)entry * type->value_size, value, type->value_size);
    map->live[entry] = true;
    map->used += 1;
    map->len += 1;
    vt_map_place(map, type, entry);
    return false;
}

/* Removes `key`. If it was present, its key and value are moved to
 * `old_key` and `old_value`, and the result is true. */
static bool vt_map_remove(vt_map *map, const vt_map_type *type, const void *key,
                          void *old_key, void *old_value) {
    if (map->len == 0) {
        return false;
    }
    uint64_t mask = (uint64_t)map->slot_cap - 1;
    for (uint64_t slot = type->hash(key) & mask;; slot = (slot + 1) & mask) {
        int64_t entry = map->slots[slot];
        if (entry == -1) {
            return false;
        }
        if (entry >= 0 && type->eq(map->keys + (size_t)entry * type->key_size, key)) {
            memcpy(old_key, map->keys + (size_t)entry * type->key_size, type->key_size);
            memcpy(old_value, map->values + (size_t)entry * type->value_size, type->value_size);
            map->slots[slot] = -2;
            map->live[entry] = false;
            map->len -= 1;
            return true;
        }
    }
}

/* The value of `key`; panics if the key is absent. */
static void *vt_map_at(const vt_map *map, const vt_map_type *type, const void *key) {
    int64_t entry = vt_map_find(map, type, key);
    if (entry < 0) {
        vt_panic("key not found");
    }
    return map->values + (size_t)entry * type->value_size;
}

/* Empties a map whose keys and values were already released, keeping its
 * storage. */
static void vt_map_reset(vt_map *map) {
    map->len = 0;
    map->used = 0;
    for (int64_t slot = 0; slot < map->slot_cap; slot += 1) {
        map->slots[slot] = -1;
    }
}

/* Frees the storage of a map whose keys and values were already released. */
static void vt_map_free(vt_map *map) {
    vt_items_free(map->keys);
    vt_items_free(map->values);
    vt_items_free(map->live);
    vt_items_free(map->slots);
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
/* Output is the bytes the program prints: on Windows, the standard streams
 * would otherwise turn every "\n" into "\r\n". */
static void vt_start(void) {
#ifdef _WIN32
    _setmode(_fileno(stdout), _O_BINARY);
    _setmode(_fileno(stderr), _O_BINARY);
#endif
}

static void vt_finish(void) {
#ifdef VT_CHECK_LEAKS
    if (vt_live_blocks != 0) {
        fflush(stdout);
        fprintf(stderr, "leak check: %lld heap blocks still live\n", (long long)vt_live_blocks);
        exit(102);
    }
#endif
}
