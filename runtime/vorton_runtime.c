/* Vorton C11 runtime. The compiler places this text at the start of every
 * generated translation unit. */

#include <float.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
static void vt_finish(void) {
#ifdef VT_CHECK_LEAKS
    if (vt_live_blocks != 0) {
        fflush(stdout);
        fprintf(stderr, "leak check: %lld heap blocks still live\n", (long long)vt_live_blocks);
        exit(102);
    }
#endif
}
