// vorton_runtime.cpp — C ABI runtime for Vorton native programs
// Target: x86_64-pc-windows-msvc (MSVC compatible)
// Convention: all functions extern "C", void* in/out (or int64_t/double for unboxing)
// Memory: Perceus RC (L0) — every heap object has an 8-byte header [rc:u32 | typeid:u32]
//         before the data pointer.  vorton_alloc returns data ptr; vorton_dup/vorton_drop
//         manage the refcount; vorton_drop dispatches per-type destructors via drop_table.

#include <cstdint>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <csetjmp>
#include <string>
#include <stdexcept>
#include <vector>
#include <unordered_map>
#include <algorithm>
#include <chrono>

#include <cctype>
#include <sstream>

#ifdef _WIN32
#include <direct.h>  // _getcwd
#include <io.h>      // _access
#include <windows.h> // GetFullPathName
#include <intrin.h>  // _ReturnAddress
#include <process.h> // _spawnvp (B-163 exec_sync)
#define PATH_SEP '\\'
#else
#include <unistd.h>  // getcwd, access, fork/execvp (B-163 exec_sync)
#include <sys/wait.h> // waitpid (B-163 exec_sync)
#define PATH_SEP '/'
#endif

// ============================================================================
// Type aliases (documentation only — all cross-boundary types are void*)
//   Str          = VortonStr*         (data ptr into vorton_alloc'd block)
//   List         = VortonList*        (Vorton struct: {buf, len_tagged, cap_tagged})
//   Map          = VortonMapStruct*    (pure-Vorton: {meta, keys, values, len, cap})
//   MapInt       = no distinct ABI type (Map<Int, V> uses the same VortonMapStruct)
//   Set          = pure-Vorton struct { entries: Map<T, Unit> }
//   StringBuilder = std::string*
//
// Object layout (after vorton_alloc):
//   [rc:u32 | typeid:u32 | ...data...]
//    ^                     ^
//    ptr-8                 ptr  (returned by vorton_alloc, used everywhere)
// ============================================================================

// B-152 P1 Step 1: VortonStr — C struct replacement for std::string in Str data area.
// Invariants: buf always non-NULL, buf[len]=='\0', cap >= len+1.
struct VortonStr {
    char* buf;     // always non-NULL, always null-terminated at buf[len]
    int64_t len;   // content byte count (excluding null terminator)
    int64_t cap;   // total malloc'd bytes for buf (cap >= len + 1)
};

static inline VortonStr* as_str(void* p) { return (VortonStr*)p; }

// B-152 P2: VortonList — Vorton struct replacement for std::vector<void*> in List data area.
// Layout mirrors the Vorton struct: { buf: Ptr<T>, len: Int, cap: Int }
// where Int is a tagged pointer: (value << 1) | 1.
struct VortonList {
    void** buf;        // slot buffer (calloc'd array of void*)
    void*  len_tagged; // tagged int: (len << 1) | 1
    void*  cap_tagged; // tagged int: (cap << 1) | 1
};

static inline VortonList* as_list(void* p) { return (VortonList*)p; }
static inline int64_t list_len(VortonList* l) { return (int64_t)((uintptr_t)l->len_tagged >> 1); }
static inline int64_t list_cap(VortonList* l) { return (int64_t)((uintptr_t)l->cap_tagged >> 1); }
static inline void list_set_len(VortonList* l, int64_t n) { l->len_tagged = (void*)(((uintptr_t)n << 1) | 1); }
static inline void list_set_cap(VortonList* l, int64_t n) { l->cap_tagged = (void*)(((uintptr_t)n << 1) | 1); }

// P2: an explicit typed handled-effect context is borrowed by every ordinary
// Vorton call. The runtime never creates or interprets typed instance identity;
// it only compares opaque tokens supplied by the typed IR/Core producer.
struct EffectCtxEntry {
    const void* token;
    void* evidence;
};

struct EffectCtx {
    EffectCtx* parent;
    int64_t entry_count;
};

static inline EffectCtxEntry* effect_ctx_entries(EffectCtx* ctx) {
    return (EffectCtxEntry*)((char*)ctx + sizeof(EffectCtx));
}

static inline const EffectCtxEntry* effect_ctx_entries(const EffectCtx* ctx) {
    return (const EffectCtxEntry*)((const char*)ctx + sizeof(EffectCtx));
}

// Helper: byte-level substring search (no memmem on Windows)
static inline const char* vorton_memmem(const char* hay, size_t hlen,
                                       const char* needle, size_t nlen) {
    if (nlen == 0) return hay;
    if (nlen > hlen) return nullptr;
    for (size_t i = 0; i <= hlen - nlen; i++) {
        if (memcmp(hay + i, needle, nlen) == 0) return hay + i;
    }
    return nullptr;
}

// ============================================================================
// Perceus RC L0 — TypeID constants
// ============================================================================

#define VORTON_TYPEID_INT       0
#define VORTON_TYPEID_FLOAT     1
#define VORTON_TYPEID_BOOL      2
#define VORTON_TYPEID_STR       3
#define VORTON_TYPEID_LIST      4
#define VORTON_TYPEID_MAP       5
#define VORTON_TYPEID_CLOSURE   7
#define VORTON_TYPEID_OPTION    8
#define VORTON_TYPEID_UNIT      9
#define VORTON_TYPEID_TUPLE    10
#define VORTON_TYPEID_SB       13   // StringBuilder (same underlying type as Str)
#define VORTON_TYPEID_CELL     14   // boxed mut-cell: { void* value } — write-through closure capture (B-091)
#define VORTON_TYPEID_CLOSURE_ENV 15 // closure env struct: { int64 count, void* cap0, ... } — owned-capture drop (B-084)
// B-104 D4 (#151): trait dicts are first-class.  Layout for BOTH dict typeids:
//   { int64 method_count, void* method_closure0, ... }  (count-prefixed, like
//   CLOSURE_ENV) — dispatch GEPs slot i at offset 8 + i*8.
//   DICT_STATIC — module-level singletons (impl dicts / builtin primitive dicts
//                 / fully-static wrapped instances).  Registered NEVER-DROP:
//                 they live for the program lifetime, so a stray vorton_dup/
//                 vorton_drop (e.g. a closure env capturing one) is a no-op —
//                 defense in depth for the singleton model.
//   DICT_DYN    — locally constructed dynamic wrapped dicts (HExpr::
//                 DictConstruct).  drop_dict releases the method closures
//                 (whose envs hold dup'd inner-dict references) when the
//                 owning binding is scope-end-dropped.
#define VORTON_TYPEID_DICT_STATIC 16
#define VORTON_TYPEID_DICT_DYN    17
// B-104 D6 (#153/#154): module-level immutable singletons, mirroring the JS
// backend's frozen `Option_none` / module-level consts.  Both NEVER-DROP
// (registered in vorton_runtime_init) — stray dup/drop are no-ops, same
// defense-in-depth leg as DICT_STATIC.
//   OPTION_NONE  — THE process-wide `none` value (layout identical to a
//                  tag==1 OPTION; pattern matches read the tag and never the
//                  typeid).  Built lazily by vorton_enum_none; every producer
//                  (codegen's vorton_Option_none + all runtime helpers) returns
//                  this one pointer, so none==none pointer identity matches
//                  the JS oracle's `Option_none === Option_none`.
//   CONST_STATIC — a `const` declaration's initialiser value, built once
//                  inside the codegen-emitted memoised getter and retagged
//                  via vorton_const_intern (data layout unchanged — a retagged
//                  Str is still read as VortonStr* by every str op).
#define VORTON_TYPEID_OPTION_NONE 18
#define VORTON_TYPEID_CONST_STATIC 19
// B-104 D9 Part 2: a module-level `const` whose initialiser is a heap-allocating
// non-Str value (the compiler's `Type`-valued consts UNIT/INT/STR/.../ANY +
// EffectRow EMPTY_ROW etc. — zero-field enum / pure struct singletons).  Pre-D9
// each access re-evaluated the const getter, constructing a fresh box that
// nobody dropped (use sites borrow a module-level value, mirroring the JS
// backend's module `const` — D8 attributed Type::UnitType ≈22.7M live @2.382B,
// 98.7% pure leak).  Now the getter is a lazy memoised SINGLETON (D6
// CONST_STATIC mirror, dedicated typeid for clean per-class counting), retagged
// once via vorton_unit_intern.  NEVER-DROP: stray dup/drop are no-ops.  Layout is
// untouched by the retag — a retagged Type enum is still read by its tag/payload
// exactly as before (nothing dispatches on this typeid except dup/drop +
// diagnostics; the immortal Type-scalar consts have no payload to free anyway).
#define VORTON_TYPEID_CONST_HEAP_STATIC 20
#define VORTON_TYPEID_EVIDENCE 21   // B-096: evidence struct { i64 count, ptr slot0, ... } — each slot is a closure
#define VORTON_TYPEID_EFFECT_CTX_EMPTY 22 // P2: immortal process-wide empty context
#define VORTON_TYPEID_EFFECT_CTX 23  // P2: owned typed handled-effect overlay
#define VORTON_TYPEID_USER_BASE 64  // user-defined types start here

// ============================================================================
// Perceus RC L0 — drop dispatch table
// ============================================================================

typedef void (*vorton_drop_fn)(void* data);
static vorton_drop_fn drop_table[4096];
static int drop_table_size = VORTON_TYPEID_USER_BASE;

// B-101 never-drop (interned / arena) typeids — RETIRED for the compiler's
// `Type` DAG by B-102 R-clean (2026-06-07; Type participates in ordinary
// Perceus RC, see design §7.11 "pure Perceus RC").  RE-ACTIVATED by B-104 D4
// (#151) for exactly ONE typeid: VORTON_TYPEID_DICT_STATIC — trait-dict
// singletons are immortal module-level values (bounded: one per dict instance
// per program), so dup/drop on them are no-ops.  This makes every stray RC op
// on a singleton (closure-env capture dup, env-drop release, scope-end drop of
// a binding that aliased one) safe by construction — the defense-in-depth leg
// of the D4 singleton model.  vorton_runtime_init registers it; no codegen-side
// registration exists.
static bool never_drop_table[4096];

// Forward declarations for RC infrastructure
static void vorton_drop_by_typeid(uint32_t tid, void* data);

// ============================================================================
// Perceus RC L0 — vorton_alloc / vorton_dup / vorton_drop
// ============================================================================

// ─────────────────────────────────────────────────────────────────────────────
// B-080 P0 — boxed-INT call-site attribution (opt-in, -DVORTON_BOX_PROFILE).
// g_live_tid (below) says HOW MANY INT boxes are live; this says WHERE they were
// born.  Samples 1/VORTON_BOX_PROFILE_SAMPLE box_int allocations into a side table
// keyed by the IR return address, erases on free, and at report time aggregates
// the still-live samples by call site.  Decides whether residual INT is boundary
// boxing (List<Int>/Option<Int>/dict/tuple/variant slots — spread across many
// sites) vs a specific RC gap (one site dominates), and confirms no non-scalar
// typeid is masked.  Prints RVA (= RA - image base) so a linker .map symbolizes
// the sites.  Throwaway diagnostic; inert without the flag.  Build the diagnostic
// run with BOTH -DVORTON_ALLOC_STATS -DVORTON_BOX_PROFILE.
// ─────────────────────────────────────────────────────────────────────────────
#ifdef VORTON_BOX_PROFILE
#ifndef VORTON_BOX_PROFILE_SAMPLE
#define VORTON_BOX_PROFILE_SAMPLE 64   // must be a power of two
#endif
// B-109: extended to per-typeid attribution.  INT recorded at vorton_box_int (RA = IR
// site).  Report splits by typeid.
// B-104 D5 run-2 refinement: OPTION moved from vorton_enum_some/none to vorton_alloc —
// run 1 showed ZERO live OPTION samples because IR-level Option constructors call
// vorton_alloc(typeid=8) directly and bypass the (runtime-internal, static) enum
// helpers entirely; recording in vorton_alloc covers both paths (RA = IR ctor site,
// or the runtime helper that enum_some inlined into).  STR moved from vorton_alloc
// to vorton_str_from_cstr + vorton_sb_to_str (RA = IR site instead of one collapsed
// runtime-helper bucket) — run 1 measured those two helpers at 99.9% of live STR
// (88.2% / 11.7%); the remaining helpers (map_entries / join / int_to_str …) were
// < 0.01% live and are deliberately not recorded.
// B-104 D5: BOOL recorded at vorton_box_bool (RA = IR site — note that predicate
// closures called by runtime HOFs box their result inside the closure body, so
// HOF-discarded BOOLs attribute to lambda IR functions; the exact HOF share comes
// from the direct [hof-stats] counters below, the profile cross-validates and
// attributes the non-HOF remainder, e.g. And/Or phi sites).
struct VortonBoxRec { void* ra; uint32_t tid; };
// B-104 D8: born record now carries the tid so per-class born can be aggregated
// over ALL recorded sites (including sites whose every sample has since been
// freed) — a born-only/0-live site would otherwise vanish from g_box_live and
// silently inflate the retention% of a plateauing class.
struct VortonBornRec { uint64_t born; uint32_t tid; };
static std::unordered_map<void*, VortonBoxRec>* g_box_live = nullptr; // live ptr -> (RA, typeid)
static std::unordered_map<void*, VortonBornRec>* g_box_born = nullptr; // RA -> (cumulative sampled births, tid)
static uint64_t g_box_seq = 0;
static uintptr_t vorton_image_base() {
#ifdef _WIN32
    static uintptr_t base = (uintptr_t)GetModuleHandleW(NULL);
    return base;
#else
    return 0;
#endif
}
static const char* vorton_tid_name(uint32_t tid) {
    switch (tid) {
        case 0:  return "INT";    case 2:  return "BOOL";   case 3:  return "STR";
        case 7:  return "CLOSURE"; case 8: return "OPTION"; case 10: return "TUPLE";
        case 13: return "SB";     // B-104 D8: StringBuilder
        case 21: return "EVIDENCE"; // B-096: evidence struct
        case 22: return "EFFECT_CTX_EMPTY";
        case 23: return "EFFECT_CTX";
        default: return (tid >= VORTON_TYPEID_USER_BASE) ? "USER" : "?"; // D8: user types (Type≈tid103)
    }
}
static void vorton_box_profile_record(void* ptr, void* ra, uint32_t tid) {
    if (!g_box_live) {
        g_box_live = new std::unordered_map<void*, VortonBoxRec>();
        g_box_born = new std::unordered_map<void*, VortonBornRec>();
    }
    if ((g_box_seq++ & (VORTON_BOX_PROFILE_SAMPLE - 1)) != 0) return; // sample 1/N
    (*g_box_live)[ptr] = VortonBoxRec{ ra, tid };
    VortonBornRec& b = (*g_box_born)[ra]; b.born++; b.tid = tid;
}
static void vorton_box_profile_erase(void* ptr) {
    if (g_box_live) g_box_live->erase(ptr);
}
static void vorton_box_profile_report() {
    if (!g_box_live) return;
    uintptr_t base = vorton_image_base();
    // aggregate live samples by (typeid, RA)
    std::unordered_map<uint32_t, std::unordered_map<void*, uint64_t>> per; // tid -> ra -> live
    std::unordered_map<uint32_t, uint64_t> tid_total;
    for (auto& kv : *g_box_live) { per[kv.second.tid][kv.second.ra]++; tid_total[kv.second.tid]++; }
    // B-104 D8 — per-class retention summary (live samples / born samples → %),
    // aggregated over all sites of the tid.  retention≈100% & rising = pure leak
    // (orphan); retention«100% & plateau = legit working set; «100% & rising =
    // growth-type (cache-like or slow leak, flag for human review).  born is the
    // cumulative sampled births recorded at every recorded site of this tid.
    {
        // born aggregated over the FULL born map (every site that ever recorded
        // this tid), not just currently-live sites — so a born-only site can't
        // vanish and inflate retention.
        std::unordered_map<uint32_t, uint64_t> born_per; // tid -> cumulative born
        for (auto& kv : *g_box_born) born_per[kv.second.tid] += kv.second.born;
        // emit a [box-summary] line for every tid that has born or live samples
        std::unordered_map<uint32_t, char> seen;
        for (auto& tp : tid_total) seen[tp.first] = 1;
        for (auto& tp : born_per)   seen[tp.first] = 1;
        for (auto& s : seen) {
            uint32_t tid = s.first;
            uint64_t live = tid_total.count(tid) ? tid_total[tid] : 0;
            uint64_t born = born_per.count(tid) ? born_per[tid] : 0;
            double ret = born ? (100.0 * (double)live / (double)born) : 0.0;
            fprintf(stderr, "[box-summary] tid%u(%s) live_samp=%llu born_samp=%llu retention=%.1f%% (x%d: ~%lluM live / ~%lluM born)\n",
                    tid, vorton_tid_name(tid), (unsigned long long)live, (unsigned long long)born, ret,
                    VORTON_BOX_PROFILE_SAMPLE,
                    (unsigned long long)(live * VORTON_BOX_PROFILE_SAMPLE / 1000000),
                    (unsigned long long)(born * VORTON_BOX_PROFILE_SAMPLE / 1000000));
        }
    }
    for (auto& tp : per) {
        uint32_t tid = tp.first;
        std::vector<std::pair<void*, uint64_t>> v(tp.second.begin(), tp.second.end());
        std::sort(v.begin(), v.end(),
            [](const std::pair<void*,uint64_t>& a, const std::pair<void*,uint64_t>& b){ return a.second > b.second; });
        fprintf(stderr, "[box-profile] %s live sites: %zu distinct, %llu samples (x%d = ~%llu boxes), top:\n",
                vorton_tid_name(tid), v.size(), (unsigned long long)tid_total[tid], VORTON_BOX_PROFILE_SAMPLE,
                (unsigned long long)tid_total[tid] * VORTON_BOX_PROFILE_SAMPLE);
        int n = (int)v.size(); if (n > 12) n = 12;
        for (int i = 0; i < n; i++) {
            void* ra = v[i].first;
            uint64_t born = (*g_box_born)[ra].born;
            fprintf(stderr, "  [%s] rva=0x%llx live=%llu born=%llu (RA=%p)\n",
                    vorton_tid_name(tid), (unsigned long long)((uintptr_t)ra - base),
                    (unsigned long long)v[i].second, (unsigned long long)born, ra);
        }
    }
    fflush(stderr);
}
#if !defined(VORTON_ALLOC_STATS)
static bool g_box_atexit = (atexit(vorton_box_profile_report), true);
#endif
#endif // VORTON_BOX_PROFILE

// ─────────────────────────────────────────────────────────────────────────────
// Alloc/free leak counter (opt-in diagnostic, -DVORTON_ALLOC_STATS).  Inert in
// normal builds.  Tracks `live = allocs - frees` overall and per-typeid; a leaking
// program has live ≈ allocs (1:1, never plateaus), a reclaiming one has live
// plateau (frees keep pace).  Periodic stderr reports (every ~32M allocs) + atexit
// give a leak% trajectory even when a self-compile is memory-capped before exit.
// typeid quick-ref: 0=INT 2=BOOL 3=STR 4=LIST 7=CLOSURE 8=OPTION 10=TUPLE
// 16/17=DICT(static/dyn) 18=NONE-SINGLETON 19=CONST-STATIC 64+=user.
// Used to attribute the G-a memory wall (B-104): the precise-Perceus waves drive
// the leak% down by dropping owned temporaries that clone-all-escape leaves alive.
// ─────────────────────────────────────────────────────────────────────────────
#ifdef VORTON_ALLOC_STATS
static uint64_t g_allocs = 0;
static uint64_t g_frees  = 0;
static int64_t  g_live_tid[4096] = {0};
static uint64_t g_next_report = (1ULL << 25); // first report at 32M allocs
// ─────────────────────────────────────────────────────────────────────────────
static void vorton_alloc_stats_report() {
    uint64_t live = g_allocs - g_frees;
    double pct = g_allocs ? (100.0 * (double)live / (double)g_allocs) : 0.0;
    // top-6 live typeids
    int top[6]; for (int i = 0; i < 6; i++) top[i] = -1;
    for (int t = 0; t < 4096; t++) {
        if (g_live_tid[t] <= 0) continue;
        for (int s = 0; s < 6; s++) {
            if (top[s] < 0 || g_live_tid[t] > g_live_tid[top[s]]) {
                for (int k = 5; k > s; k--) top[k] = top[k-1];
                top[s] = t; break;
            }
        }
    }
    fprintf(stderr, "[alloc-stats] allocs=%llu frees=%llu live=%llu (%.1f%% leak) | top:",
            (unsigned long long)g_allocs, (unsigned long long)g_frees,
            (unsigned long long)live, pct);
    for (int s = 0; s < 6; s++) {
        if (top[s] >= 0) fprintf(stderr, " tid%d=%lld", top[s], (long long)g_live_tid[top[s]]);
    }
    fprintf(stderr, "\n");
    fflush(stderr);
#ifdef VORTON_BOX_PROFILE
    vorton_box_profile_report();
#endif
}
static bool g_stats_atexit = (atexit(vorton_alloc_stats_report), true);
#else
#define VORTON_D5_COUNT(counter) ((void)0)
#endif

extern "C" void* vorton_alloc(int64_t size, int64_t typeid_val) {
    char* raw = (char*)malloc(8 + (size_t)size);
    if (!raw) {
        fprintf(stderr, "vorton panic: vorton_alloc failed (size=%lld, typeid=%lld)\n",
                (long long)size, (long long)typeid_val);
        exit(1);
    }
    *(uint32_t*)(raw)     = 1;                    // rc = 1 (new allocation)
    *(uint32_t*)(raw + 4) = (uint32_t)typeid_val; // typeid
#ifdef VORTON_ALLOC_STATS
    g_allocs++;
    if (typeid_val >= 0 && typeid_val < 4096) g_live_tid[typeid_val]++;
    if (g_allocs >= g_next_report) { vorton_alloc_stats_report(); g_next_report += (1ULL << 25); }
#endif
#ifdef VORTON_BOX_PROFILE
    // OPTION is allocated both by IR-level Option constructors (direct vorton_alloc
    // calls, the dominant leak path per D5 run 1) and by runtime helpers (via the
    // static, inlined vorton_enum_some/none) — record here so both attribute.
    // INT is recorded at vorton_box_int, STR at vorton_str_from_cstr / vorton_sb_to_str
    // (IR-site RA; see the box-profile header note).
    if (typeid_val == VORTON_TYPEID_OPTION) vorton_box_profile_record(raw + 8, _ReturnAddress(), VORTON_TYPEID_OPTION);
    // B-104 D8 — user-type attribution (Type≈tid103 + every other user struct/enum):
    // IR-level struct/enum constructors call vorton_alloc directly, so _ReturnAddress()
    // is the IR ctor site (same as OPTION).  Records ALL user typeids (>=64) rather
    // than hard-coding 103; the per-typeid report splits them out and the dominant
    // user tid IS Type (cross-check the tid via the [drop-reg] RVA → vorton_drop_<Name>).
    else if (typeid_val >= VORTON_TYPEID_USER_BASE && typeid_val < 4096)
        vorton_box_profile_record(raw + 8, _ReturnAddress(), (uint32_t)typeid_val);
#endif
    return raw + 8;                               // return data pointer
}

// B-152 P2: VortonList helpers (deferred from early forward-declaration).
static void* make_vorton_list(int64_t cap) {
    void* data = vorton_alloc(sizeof(VortonList), VORTON_TYPEID_LIST);
    VortonList* l = as_list(data);
    if (cap > 0) {
        l->buf = (void**)calloc((size_t)cap, sizeof(void*));
    } else {
        l->buf = nullptr;
    }
    list_set_len(l, 0);
    list_set_cap(l, cap);
    return data;
}

static void vorton_list_push_raw(void* list, void* val) {
    VortonList* l = as_list(list);
    int64_t ln = list_len(l);
    int64_t cp = list_cap(l);
    if (ln >= cp) {
        int64_t new_cap = cp < 4 ? 4 : cp + cp / 2;
        void** new_buf = (void**)calloc((size_t)new_cap, sizeof(void*));
        if (l->buf) {
            memmove(new_buf, l->buf, (size_t)ln * sizeof(void*));
            free(l->buf);
        }
        l->buf = new_buf;
        list_set_cap(l, new_cap);
    }
    l->buf[ln] = val;
    list_set_len(l, ln + 1);
}

extern "C" void vorton_dup(void* ptr) {
    if (!ptr) return;
    if ((uintptr_t)ptr & 1) return;  // B-080: tagged scalar — no RC
    uint32_t tid = *(uint32_t*)((char*)ptr - 4);
    // B-099: foreign-pointer guard — extern type values (opaque handles etc.)
    // are NOT Vorton-allocated.  Their ptr-4/ptr-8 bytes are arbitrary heap data.
    // Validating tid + rc catches most foreign pointers cheaply (reads are safe;
    // only writes corrupt).  This is defense-in-depth alongside Perceus/HIR-level
    // extern-type exclusion from HStmt::Drop and HExpr::Clone.
    if (tid >= 4096u) return;
    uint32_t rc = *(uint32_t*)((char*)ptr - 8);
    if (rc == 0u || rc > 100000u) return;
    if (never_drop_table[tid]) return; // B-101: interned, no RC
    *(uint32_t*)((char*)ptr - 8) = rc + 1;
}

extern "C" void vorton_drop(void* ptr) {
    if (!ptr) return;
    if ((uintptr_t)ptr & 1) return;  // B-080: tagged scalar — no RC
    uint32_t tid = *(uint32_t*)((char*)ptr - 4);
    // B-099: foreign-pointer guard (same rationale as vorton_dup above).
    if (tid >= 4096u) return;
    {
        uint32_t rcv = *(uint32_t*)((char*)ptr - 8);
        if (rcv == 0u || rcv > 100000u) return;
    }
#ifdef VORTON_RC_DEBUG
    {
        uint32_t rcv = *(uint32_t*)((char*)ptr - 8);
        if (tid >= 4096u || rcv == 0u || rcv > 1000000u) {
            fprintf(stderr, "[rc-debug] suspicious vorton_drop ptr=%p tid=%u rc=%u ra=%p\n",
                    ptr, tid, rcv, _ReturnAddress());
            fflush(stderr);
        }
    }
#endif
    if (tid < 4096 && never_drop_table[tid]) return; // B-101: interned, never freed
    uint32_t* rc = (uint32_t*)((char*)ptr - 8);
    if (*rc <= 1) {
        vorton_drop_by_typeid(tid, ptr);
#ifdef VORTON_BOX_PROFILE
        // B-104 D8: erase covers every profiled class — scalars + STR + OPTION +
        // SB + all user typeids (>=64).  Cheap: erase is a no-op miss for unsampled
        // ptrs.  Erasing all profiled tids keeps g_box_live = live-set exactly.
        if (tid == VORTON_TYPEID_INT || tid == VORTON_TYPEID_BOOL || tid == VORTON_TYPEID_STR ||
            tid == VORTON_TYPEID_OPTION || tid == VORTON_TYPEID_SB || tid >= VORTON_TYPEID_USER_BASE)
            vorton_box_profile_erase(ptr);
#endif
        free((char*)ptr - 8);
#ifdef VORTON_ALLOC_STATS
        g_frees++;
        if (tid < 4096) g_live_tid[tid]--;
#endif
    } else {
        *rc -= 1;
    }
}

extern "C" void vorton_register_drop(int64_t typeid_val, void* drop_fn_ptr) {
#ifdef VORTON_ALLOC_STATS
    // B-104 D5: typeid → type-name attribution.  User typeids (64+) are assigned
    // in deterministic codegen order but the mapping lives only in the compiler
    // (get_or_assign_typeid); print each registration's drop-fn RVA so the linker
    // map resolves it to `vorton_drop_<TypeName>` — identifies e.g. tid103.
    {
        uintptr_t base = 0;
#ifdef _WIN32
        base = (uintptr_t)GetModuleHandleW(NULL);
#endif
        fprintf(stderr, "[drop-reg] tid=%lld drop_rva=0x%llx\n", (long long)typeid_val,
                (unsigned long long)((uintptr_t)drop_fn_ptr - base));
    }
#endif
    if (typeid_val >= 0 && typeid_val < 4096) {
        drop_table[(int)typeid_val] = (vorton_drop_fn)drop_fn_ptr;
    }
}

// B-152 P1 Step 1: helper — allocate a new Vorton Str (VortonStr) from a C buffer + length.
// Calls vorton_alloc (RC header), then malloc's the buf.  Used by almost every Str-
// returning function.
static inline void* make_vorton_str(const char* src, int64_t len) {
    void* data = vorton_alloc(sizeof(VortonStr), VORTON_TYPEID_STR);
    VortonStr* s = as_str(data);
    s->len = len;
    s->cap = len + 1;
    s->buf = (char*)malloc((size_t)s->cap);
    if (len > 0) memcpy(s->buf, src, (size_t)len);
    s->buf[len] = '\0';
    return data;
}

// B-101 — mark a typeid as never-drop (interned / arena lifetime).  vorton_dup and
// vorton_drop become no-ops for such blocks; they live until process exit.  Used for
// the compiler's immutable shared `Type` DAG (see never_drop_table above).
extern "C" void vorton_register_never_drop(int64_t typeid_val) {
    if (typeid_val >= 0 && typeid_val < 4096) {
        never_drop_table[(int)typeid_val] = true;
    }
}

// B-104 D6 (#154): retag a freshly built `const` initialiser as an immortal
// module-level singleton.  Called exactly once per const, from the build leg of
// the codegen-emitted memoised getter (emit_const_body's lazy path).  Only the
// header typeid changes — the data layout is untouched, so e.g. a retagged Str
// is still read as VortonStr* by every str op (nothing in the runtime
// dispatches on the STR typeid except dup/drop + diagnostics).  After the
// retag, stray dup/drop on the singleton are no-ops (never-drop table).
extern "C" void* vorton_const_intern(void* p) {
    if (!p) return p;
    uint32_t* tid_p = (uint32_t*)((char*)p - 4);
#ifdef VORTON_ALLOC_STATS
    // Move the live-count to the CONST_STATIC class so the original class
    // (e.g. STR) is not polluted by one immortal entry per const decl.
    if (*tid_p < 4096) g_live_tid[*tid_p]--;
    g_live_tid[VORTON_TYPEID_CONST_STATIC]++;
#endif
#ifdef VORTON_BOX_PROFILE
    // Drop the box-profile sample recorded at allocation (immortal by design;
    // keeping it would show one permanent fake "leak" per const decl).
    vorton_box_profile_erase(p);
#endif
    *tid_p = VORTON_TYPEID_CONST_STATIC;
    return p;
}

// B-104 D9 Part 2: retag a freshly built heap-valued (non-Str) `const`
// initialiser as an immortal module-level singleton.  Called exactly once per
// such const, from the build leg of the codegen-emitted memoised getter
// (emit_const_body's heap-const path).  Sibling of vorton_const_intern — only the
// header typeid changes (data layout untouched); see VORTON_TYPEID_CONST_HEAP_STATIC.
extern "C" void* vorton_unit_intern(void* p) {
    if (!p) return p;
    uint32_t* tid_p = (uint32_t*)((char*)p - 4);
#ifdef VORTON_ALLOC_STATS
    // Move the live-count to the CONST_HEAP_STATIC class so the original class
    // (e.g. the user Type tid) is not polluted by one immortal entry per const.
    if (*tid_p < 4096) g_live_tid[*tid_p]--;
    g_live_tid[VORTON_TYPEID_CONST_HEAP_STATIC]++;
#endif
#ifdef VORTON_BOX_PROFILE
    // Drop the box-profile sample recorded at allocation (immortal by design).
    vorton_box_profile_erase(p);
#endif
    *tid_p = VORTON_TYPEID_CONST_HEAP_STATIC;
    return p;
}

static void vorton_drop_by_typeid(uint32_t tid, void* data) {
    if (tid < 4096 && drop_table[tid]) {
        drop_table[tid](data);
    }
    // If no drop function registered (e.g. user types without fields to drop),
    // the raw block is still freed by vorton_drop — the destructor is a no-op.
}

// ============================================================================
// Perceus RC L0 — per-builtin drop functions (scalars + Str)
// Container drops are defined after VortonClosure / Map / Set typedefs.
// ============================================================================

static void drop_int(void* /*data*/)   { /* no-op, scalar */ }
static void drop_float(void* /*data*/) { /* no-op, scalar */ }
static void drop_bool(void* /*data*/)  { /* no-op, scalar */ }
static void drop_unit(void* /*data*/)  { /* no-op, no payload */ }

static void drop_str(void* data) {
    // data points at a VortonStr; free the internal buf (the RC block
    // including header is freed by vorton_drop).
    free(as_str(data)->buf);
}

static void drop_cell(void* data) {
    // Boxed mut-cell (B-091): { void* value }.  A `let mut` captured by a
    // write-through closure is auto-boxed into this single-slot heap cell so the
    // outer scope and the closure env share one mutable container.  When the cell
    // itself dies, release the value it currently holds.  Must NOT reuse the
    // CLOSURE typeid: drop_closure reads field[1] (env_ptr) which is OOB for a
    // 1-slot cell.
    void* value = *(void**)data;
    if (value) vorton_drop(value);
}

// Forward-declared; defined after container layouts are available.
static void drop_list(void* data);
static void drop_map(void* data);
static void drop_closure(void* data);
static void drop_closure_env(void* data);
static void drop_option(void* data);
static void drop_tuple(void* data);
static void drop_sb(void* data);
static void drop_dict(void* data);
static void drop_evidence(void* data);
static void drop_effect_ctx(void* data);

// ============================================================================
// VortonClosure — closure representation for higher-order functions
// ============================================================================

struct VortonClosure {
    void* fn_ptr;   // function pointer
    void* env_ptr;  // captured environment pointer
};

typedef void* (*vorton_fn_1)(void* env, void* arg);
typedef void* (*vorton_fn_2)(void* env, void* a, void* b);
typedef void* (*vorton_fn_3)(void* env, void* a, void* b, void* c);

// ============================================================================
// Forward declarations
// ============================================================================

static void* vorton_enum_some(void* val);
static void* vorton_enum_none();
extern "C" void vorton_raise(void* error);

// ============================================================================
// Global state
// ============================================================================

static int g_argc = 0;
static char** g_argv = nullptr;

// CHK / CHK_ARG were a lightweight per-call crash-context tracer used during the
// #134 native RC double-free hunt (B-098).  The hunt is closed; they are now
// no-ops (left at call sites so the diagnostic can be re-enabled in one place if
// ever needed).  Normal null / bounds / key-not-found panics remain (below).
#define CHK(name) do { } while(0)
#define CHK_ARG(name, arg) do { } while(0)

extern "C" void vorton_runtime_init(int argc, char** argv) {
    g_argc = argc;
    g_argv = argv;

    // Perceus L0: register builtin drop functions
    drop_table[VORTON_TYPEID_INT]     = drop_int;
    drop_table[VORTON_TYPEID_FLOAT]   = drop_float;
    drop_table[VORTON_TYPEID_BOOL]    = drop_bool;
    drop_table[VORTON_TYPEID_STR]     = drop_str;
    drop_table[VORTON_TYPEID_LIST]    = drop_list;
    drop_table[VORTON_TYPEID_MAP]     = drop_map;
    drop_table[VORTON_TYPEID_CLOSURE] = drop_closure;
    drop_table[VORTON_TYPEID_OPTION]  = drop_option;
    drop_table[VORTON_TYPEID_UNIT]    = drop_unit;
    drop_table[VORTON_TYPEID_TUPLE]   = drop_tuple;
    drop_table[VORTON_TYPEID_SB]      = drop_sb;
    drop_table[VORTON_TYPEID_CELL]    = drop_cell;
    drop_table[VORTON_TYPEID_CLOSURE_ENV] = drop_closure_env;
    // B-096: evidence struct { count, closure0, closure1, ... }.
    drop_table[VORTON_TYPEID_EVIDENCE] = drop_evidence;
    // P2: the empty context is immortal. Each non-empty overlay owns its
    // evidence values and one reference to its parent overlay.
    never_drop_table[VORTON_TYPEID_EFFECT_CTX_EMPTY] = true;
    drop_table[VORTON_TYPEID_EFFECT_CTX] = drop_effect_ctx;
    // B-104 D4 (#151): first-class trait dicts.  Static singletons never drop
    // (immortal, bounded); dynamic wrapped dicts release their method closures.
    never_drop_table[VORTON_TYPEID_DICT_STATIC] = true;
    drop_table[VORTON_TYPEID_DICT_DYN] = drop_dict;
    // B-104 D6 (#153/#154): the none singleton + const-initialiser singletons
    // are immortal module-level values (bounded: 1 none + one per const decl).
    never_drop_table[VORTON_TYPEID_OPTION_NONE] = true;
    never_drop_table[VORTON_TYPEID_CONST_STATIC] = true;
    // B-104 D9 Part 2: heap-valued non-Str const singletons (Type/EffectRow
    // consts) — immortal module-level values (bounded: one per such const decl).
    never_drop_table[VORTON_TYPEID_CONST_HEAP_STATIC] = true;
}

static EffectCtx* g_vorton_effect_ctx_empty = nullptr;

extern "C" EffectCtx* vorton_effect_ctx_empty() {
    if (!g_vorton_effect_ctx_empty) {
        // Embedders may request the empty context before runtime_init; install
        // its explicit never-drop rule here as well as in runtime_init.
        never_drop_table[VORTON_TYPEID_EFFECT_CTX_EMPTY] = true;
        EffectCtx* empty = (EffectCtx*)vorton_alloc(
            (int64_t)sizeof(EffectCtx), VORTON_TYPEID_EFFECT_CTX_EMPTY);
        empty->parent = nullptr;
        empty->entry_count = 0;
        g_vorton_effect_ctx_empty = empty;
    }
    return g_vorton_effect_ctx_empty;
}

// The token/evidence arrays are borrowed only while this function runs. Each
// evidence value is transferred into the returned owned overlay; `parent`
// remains borrowed by the caller and is duplicated once for the child edge.
extern "C" EffectCtx* vorton_effect_ctx_overlay(
    EffectCtx* parent, int64_t entry_count,
    const void* const* tokens, void* const* evidence_values
) {
    if (!parent || entry_count < 0 ||
        (entry_count > 0 && (!tokens || !evidence_values))) {
        fprintf(stderr, "vorton panic: invalid effect context overlay\n");
        exit(1);
    }
    for (int64_t i = 0; i < entry_count; i++) {
        if (!tokens[i]) {
            fprintf(stderr, "vorton panic: null typed effect token\n");
            exit(1);
        }
    }

    const size_t payload_size = sizeof(EffectCtx) +
        (size_t)entry_count * sizeof(EffectCtxEntry);
    EffectCtx* child = (EffectCtx*)vorton_alloc(
        (int64_t)payload_size, VORTON_TYPEID_EFFECT_CTX);
    child->parent = parent;
    child->entry_count = entry_count;
    vorton_dup(parent);

    EffectCtxEntry* entries = effect_ctx_entries(child);
    for (int64_t i = 0; i < entry_count; i++) {
        entries[i].token = tokens[i];
        entries[i].evidence = evidence_values[i];
    }
    return child;
}

// Search inner-to-outer and compare only producer-issued opaque token identity.
// The returned evidence pointer is borrowed from the matching overlay.
extern "C" void* vorton_effect_ctx_lookup(
    const EffectCtx* ctx, const void* token
) {
    if (!token) return nullptr;
    for (const EffectCtx* current = ctx; current; current = current->parent) {
        const EffectCtxEntry* entries = effect_ctx_entries(current);
        for (int64_t i = 0; i < current->entry_count; i++) {
            if (entries[i].token == token) return entries[i].evidence;
        }
    }
    return nullptr;
}

// Borrowed parent view for the handler-arm/re-perform internal callable path.
extern "C" EffectCtx* vorton_effect_ctx_parent(EffectCtx* ctx) {
    return ctx ? ctx->parent : nullptr;
}

// ============================================================================
// Boxing / Unboxing (6)
// ============================================================================

extern "C" void* vorton_box_int(int64_t val) {
    // B-080: tagged pointer — no heap allocation.
    // Encoding: (val << 1) | 1.  63-bit signed range.
    return (void*)(((uintptr_t)val << 1) | 1);
}

// Compiler-internal B-176 measurement clock. This deliberately has no std
// declaration: only compiler/phase_timing.vorton can opt into it. A process-local
// steady-clock origin keeps the boxed result inside Vorton's signed 63-bit Int
// representation; saturation preserves monotonicity in the theoretical limit.
extern "C" void* vorton_bench_monotonic_ns() {
    using Clock = std::chrono::steady_clock;
    static const Clock::time_point origin = Clock::now();
    const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(
        Clock::now() - origin).count();
    constexpr int64_t vorton_int_max = INT64_MAX >> 1;
    const int64_t bounded = elapsed < 0
        ? 0
        : (elapsed > vorton_int_max ? vorton_int_max : (int64_t)elapsed);
    return vorton_box_int(bounded);
}

extern "C" int64_t vorton_unbox_int(void* p) {
    // B-080: tagged pointer — (val << 1) | 1; arithmetic shift right recovers val.
    if ((uintptr_t)p & 1) return (int64_t)((intptr_t)p >> 1);
    // Legacy boxed path (runtime internal — e.g. Option<Int> payload)
    CHK("unbox_int");
    if (!p) { fprintf(stderr, "vorton panic: unbox_int(null)\n"); exit(1); }
    return *(int64_t*)p;
}

extern "C" void* vorton_box_float(double val) {
    void* data = vorton_alloc(sizeof(double), VORTON_TYPEID_FLOAT);
    *(double*)data = val;
    return data;
}

extern "C" double vorton_unbox_float(void* p) {
    if (!p) {
        fprintf(stderr, "vorton panic: unbox_float(null)\n");
        fflush(stderr);
        exit(1);
    }
    return *(double*)p;
}

extern "C" void* vorton_box_bool(int64_t val) {
    // B-080: tagged pointer — true = 3 ((1<<1)|1), false = 1 ((0<<1)|1).
    return (void*)((((uintptr_t)(val != 0 ? 1 : 0)) << 1) | 1);
}

extern "C" int64_t vorton_unbox_bool(void* p) {
    // B-080: tagged pointer — same encoding as Int.
    if ((uintptr_t)p & 1) return (int64_t)((intptr_t)p >> 1);
    // Legacy boxed path (runtime internal)
    CHK("unbox_bool");
    if (!p) { fprintf(stderr, "vorton panic: unbox_bool(null)\n"); exit(1); }
    return *(int64_t*)p;
}

// ============================================================================
// Str (~15)
// ============================================================================

extern "C" void* vorton_str_new() {
    void* data = vorton_alloc(sizeof(VortonStr), VORTON_TYPEID_STR);
    VortonStr* s = as_str(data);
    s->buf = (char*)malloc(1);
    s->buf[0] = '\0';
    s->len = 0;
    s->cap = 1;
    return data;
}

extern "C" void* vorton_str_from_cstr(const char* cstr) {
    CHK("str_from_cstr");
    int64_t len = (int64_t)strlen(cstr);
    void* data = vorton_alloc(sizeof(VortonStr), VORTON_TYPEID_STR);
    VortonStr* s = as_str(data);
    s->len = len;
    s->cap = len + 1;
    s->buf = (char*)malloc((size_t)s->cap);
    memcpy(s->buf, cstr, (size_t)(len + 1)); // includes null terminator
#ifdef VORTON_BOX_PROFILE
    // B-104 D5: string-literal materialization — RA = the IR site evaluating the
    // literal (D5 run 1: 88.2% of live STR was this one class).
    vorton_box_profile_record(data, _ReturnAddress(), VORTON_TYPEID_STR);
#endif
    return data;
}

extern "C" int64_t vorton_str_len(void* s) {
    CHK("str_len");
    return as_str(s)->len;
}

extern "C" void* vorton_str_concat(void* a, void* b) {
    VortonStr* sa = as_str(a);
    VortonStr* sb = as_str(b);
    int64_t new_len = sa->len + sb->len;
    void* data = vorton_alloc(sizeof(VortonStr), VORTON_TYPEID_STR);
    VortonStr* rs = as_str(data);
    rs->len = new_len;
    rs->cap = new_len + 1;
    rs->buf = (char*)malloc((size_t)rs->cap);
    if (sa->len > 0) memcpy(rs->buf, sa->buf, (size_t)sa->len);
    if (sb->len > 0) memcpy(rs->buf + sa->len, sb->buf, (size_t)sb->len);
    rs->buf[new_len] = '\0';
    return data;
}

extern "C" int64_t vorton_str_eq(void* a, void* b) {
    CHK("str_eq");
    if (!a || !b) return (a == b) ? 1 : 0;
    VortonStr* sa = as_str(a);
    VortonStr* sb = as_str(b);
    if (sa->len != sb->len) return 0;
    return (sa->len == 0 || memcmp(sa->buf, sb->buf, (size_t)sa->len) == 0) ? 1 : 0;
}

extern "C" int64_t vorton_str_lt(void* a, void* b) {
    if (!a || !b) return (!a && b) ? 1 : 0;  // null < non-null
    VortonStr* sa = as_str(a);
    VortonStr* sb = as_str(b);
    int64_t min_len = sa->len < sb->len ? sa->len : sb->len;
    int cmp = (min_len > 0) ? memcmp(sa->buf, sb->buf, (size_t)min_len) : 0;
    if (cmp != 0) return cmp < 0 ? 1 : 0;
    return sa->len < sb->len ? 1 : 0;
}

extern "C" void* vorton_str_get(void* s, int64_t idx) {
    VortonStr* str = as_str(s);
    if (idx < 0 || idx >= str->len) {
        fprintf(stderr, "vorton panic: string index %lld out of bounds (len %lld)\n",
                (long long)idx, (long long)str->len);
        exit(1);
    }
    return make_vorton_str(str->buf + idx, 1);
}

extern "C" void* vorton_str_slice(void* s, int64_t start, int64_t end) {
    VortonStr* str = as_str(s);
    if (start < 0) start = 0;
    if (end > str->len) end = str->len;
    if (start >= end) {
        return make_vorton_str("", 0);
    }
    return make_vorton_str(str->buf + start, end - start);
}

extern "C" int64_t vorton_str_contains(void* s, void* sub) {
    VortonStr* str = as_str(s);
    VortonStr* needle = as_str(sub);
    if (needle->len == 0) return 1;
    return vorton_memmem(str->buf, (size_t)str->len, needle->buf, (size_t)needle->len) != nullptr ? 1 : 0;
}

extern "C" int64_t vorton_str_starts_with(void* s, void* prefix) {
    VortonStr* str = as_str(s);
    VortonStr* pre = as_str(prefix);
    if (pre->len > str->len) return 0;
    return (pre->len == 0 || memcmp(str->buf, pre->buf, (size_t)pre->len) == 0) ? 1 : 0;
}

extern "C" int64_t vorton_str_ends_with(void* s, void* suffix) {
    VortonStr* str = as_str(s);
    VortonStr* suf = as_str(suffix);
    if (suf->len > str->len) return 0;
    return (suf->len == 0 || memcmp(str->buf + str->len - suf->len, suf->buf, (size_t)suf->len) == 0) ? 1 : 0;
}

extern "C" void* vorton_str_split(void* s, void* delim) {
    VortonStr* str = as_str(s);
    VortonStr* del = as_str(delim);
    void* ldata = make_vorton_list(0);
    if (del->len == 0) {
        for (int64_t i = 0; i < str->len; i++) {
            vorton_list_push_raw(ldata, make_vorton_str(str->buf + i, 1));
        }
        return ldata;
    }
    size_t pos = 0;
    const char* found;
    while ((found = vorton_memmem(str->buf + pos, (size_t)(str->len - (int64_t)pos),
                                 del->buf, (size_t)del->len)) != nullptr) {
        size_t found_pos = (size_t)(found - str->buf);
        vorton_list_push_raw(ldata, make_vorton_str(str->buf + pos, (int64_t)(found_pos - pos)));
        pos = found_pos + (size_t)del->len;
    }
    vorton_list_push_raw(ldata, make_vorton_str(str->buf + pos, str->len - (int64_t)pos));
    return ldata;
}

extern "C" void* vorton_str_join(void* sep, void* list) {
    VortonStr* separator = as_str(sep);
    VortonList* l = as_list(list);
    int64_t ln = list_len(l);
    int64_t total = 0;
    for (int64_t i = 0; i < ln; i++) {
        if (i > 0) total += separator->len;
        total += as_str(l->buf[i])->len;
    }
    void* data = vorton_alloc(sizeof(VortonStr), VORTON_TYPEID_STR);
    VortonStr* rs = as_str(data);
    rs->len = total;
    rs->cap = total + 1;
    rs->buf = (char*)malloc((size_t)rs->cap);
    int64_t off = 0;
    for (int64_t i = 0; i < ln; i++) {
        if (i > 0 && separator->len > 0) {
            memcpy(rs->buf + off, separator->buf, (size_t)separator->len);
            off += separator->len;
        }
        VortonStr* elem = as_str(l->buf[i]);
        if (elem->len > 0) {
            memcpy(rs->buf + off, elem->buf, (size_t)elem->len);
            off += elem->len;
        }
    }
    rs->buf[total] = '\0';
    return data;
}

extern "C" void* vorton_str_replace(void* s, void* from, void* to) {
    VortonStr* str = as_str(s);
    VortonStr* f = as_str(from);
    VortonStr* t = as_str(to);
    if (f->len == 0) {
        return make_vorton_str(str->buf, str->len);
    }
    // Use std::string locally for replace logic
    std::string result(str->buf, (size_t)str->len);
    std::string fs(f->buf, (size_t)f->len);
    std::string ts(t->buf, (size_t)t->len);
    size_t pos = 0;
    while ((pos = result.find(fs, pos)) != std::string::npos) {
        result.replace(pos, fs.size(), ts);
        pos += ts.size();
    }
    return make_vorton_str(result.c_str(), (int64_t)result.size());
}

extern "C" void* vorton_int_to_str(int64_t val) {
    char buf[32];
    int len = snprintf(buf, sizeof(buf), "%lld", (long long)val);
    return make_vorton_str(buf, (int64_t)len);
}

// JS-parity double formatting: ECMAScript Number→String (String(x) / console.log)
// produces the *shortest* decimal that round-trips back to the same double
// (3.5 → "3.5", 3.0 → "3", 100.0 → "100", not std::to_string's "3.500000"), and
// chooses fixed vs exponential notation by the ECMA-262 §6.1.6.1.20 rules — NOT by
// printf's "%g" thresholds, which diverge (e.g. "%g" of 100.0 at 1 sig-fig is
// "1e+02" but JS yields "100"). Used by Float.to_str and by print() of a Float arg
// and preserves Vorton's established shortest-roundtrip formatting contract.
//
// Algorithm: (1) find the fewest significant digits (1..17) whose decimal rendering
// round-trips, capturing the digit string `digits` (no '.') and the base-10 point
// exponent `n` such that value = sign * digits * 10^(n - k) where k=len(digits).
// (2) Apply the ECMAScript ToString(Number) case split on n and k.
static std::string js_double_to_string(double val) {
    if (val != val) return "NaN";
    if (val == 0.0) return "0";          // -0.0 → "0" too (String(-0) === "0")
    bool neg = val < 0.0;
    double a = neg ? -val : val;
    if (a == 1.0/0.0) return neg ? "-Infinity" : "Infinity";

    // Find shortest round-tripping significant-digit string via "%.*e".
    char buf[40];
    int prec = 0;                         // digits after the decimal point in %e
    for (prec = 0; prec <= 16; prec++) {
        snprintf(buf, sizeof(buf), "%.*e", prec, a);
        if (strtod(buf, nullptr) == a) break;
    }
    // buf looks like "d.ddde±XX". Extract significant digits and exponent E
    // (the power of ten of the leading digit).
    std::string s(buf);
    size_t epos = s.find('e');
    std::string mant = s.substr(0, epos);
    int E = atoi(s.c_str() + epos + 1);
    std::string digits;
    for (char c : mant) { if (c >= '0' && c <= '9') digits.push_back(c); }
    // Strip trailing zeros (shortest form); keep at least one digit.
    while (digits.size() > 1 && digits.back() == '0') digits.pop_back();
    int k = (int)digits.size();           // number of significant digits
    int n = E + 1;                        // ECMA's n: value = digits * 10^(n-k)

    std::string out;
    if (k <= n && n <= 21) {
        // Integer with trailing zeros: digits followed by (n-k) zeros.
        out = digits;
        out.append(n - k, '0');
    } else if (0 < n && n <= 21) {
        // Decimal point inside the digit string.
        out = digits.substr(0, n) + "." + digits.substr(n);
    } else if (-6 < n && n <= 0) {
        // 0.00…digits
        out = "0.";
        out.append(-n, '0');
        out += digits;
    } else {
        // Exponential form: d[.ddd]e±(n-1)
        std::string m = digits.substr(0, 1);
        if (k > 1) m += "." + digits.substr(1);
        int exp = n - 1;
        out = m + "e" + (exp >= 0 ? "+" : "-") + std::to_string(exp >= 0 ? exp : -exp);
    }
    return neg ? ("-" + out) : out;
}

extern "C" void* vorton_float_to_str(double val) {
    std::string tmp = js_double_to_string(val);
    return make_vorton_str(tmp.c_str(), (int64_t)tmp.size());
}

extern "C" void* vorton_bool_to_str(int64_t val) {
    if (val) return make_vorton_str("true", 4);
    return make_vorton_str("false", 5);
}

// ============================================================================
// B-152 P2: slot bridge functions for Vorton List RIIR
// ============================================================================

[[noreturn]] static void vorton_raw_request_panic(const char* function,
                                                 const char* reason,
                                                 int64_t request) {
    fprintf(stderr, "vorton panic: %s %s (request=%lld)\n",
            function, reason, (long long)request);
    fflush(stderr);
    exit(1);
}

extern "C" void* vorton_slot_alloc(void* count_tagged) {
    int64_t count = vorton_unbox_int(count_tagged);
    if (count < 0) {
        vorton_raw_request_panic("vorton_slot_alloc", "negative allocation request", count);
    }
    if (count == 0) return nullptr;
    if ((uint64_t)count > (uint64_t)(SIZE_MAX / sizeof(void*))) {
        vorton_raw_request_panic("vorton_slot_alloc", "slot byte-size overflow", count);
    }
    void* slots = calloc((size_t)count, sizeof(void*));
    if (!slots) {
        vorton_raw_request_panic("vorton_slot_alloc", "allocation failed", count);
    }
    return slots;
}

extern "C" void* vorton_slot_dealloc(void* buf, void* count_tagged) {
    (void)count_tagged;
    free(buf);
    return nullptr;
}

extern "C" void* vorton_slot_read(void* buf, void* idx_tagged) {
    int64_t idx = vorton_unbox_int(idx_tagged);
    void* val = ((void**)buf)[idx];
    if (val) vorton_dup(val);
    return val;
}

extern "C" void* vorton_slot_take(void* buf, void* idx_tagged) {
    int64_t idx = vorton_unbox_int(idx_tagged);
    void* val = ((void**)buf)[idx];
    ((void**)buf)[idx] = nullptr;
    return val;
}

extern "C" void* vorton_slot_write(void* buf, void* idx_tagged, void* val) {
    int64_t idx = vorton_unbox_int(idx_tagged);
    ((void**)buf)[idx] = val;
    return nullptr;
}

// Borrowed replacement boundary: acquire the new slot reference before
// releasing the old one so replacing a slot with itself is safe.
extern "C" void* vorton_slot_replace(void* buf, void* idx_tagged, void* val) {
    int64_t idx = vorton_unbox_int(idx_tagged);
    void** slot = &((void**)buf)[idx];
    if (val) vorton_dup(val);
    void* old = *slot;
    *slot = val;
    if (old) vorton_drop(old);
    return nullptr;
}

extern "C" void* vorton_slot_swap(void* buf, void* i_tagged, void* j_tagged) {
    int64_t i = vorton_unbox_int(i_tagged);
    int64_t j = vorton_unbox_int(j_tagged);
    void** arr = (void**)buf;
    void* tmp = arr[i]; arr[i] = arr[j]; arr[j] = tmp;
    return nullptr;
}

extern "C" void* vorton_slot_move(void* src, void* src_off_tagged, void* dst, void* dst_off_tagged, void* count_tagged) {
    int64_t count = vorton_unbox_int(count_tagged);
    if (count < 0) {
        vorton_raw_request_panic("vorton_slot_move", "negative count", count);
    }
    if (count == 0) return nullptr;
    int64_t src_off = vorton_unbox_int(src_off_tagged);
    int64_t dst_off = vorton_unbox_int(dst_off_tagged);
    memmove((void**)dst + dst_off, (void**)src + src_off, (size_t)count * sizeof(void*));
    return nullptr;
}

extern "C" void* vorton_slot_drop(void* buf, void* idx_tagged) {
    int64_t idx = vorton_unbox_int(idx_tagged);
    void* val = ((void**)buf)[idx];
    ((void**)buf)[idx] = nullptr;
    if (val) vorton_drop(val);
    return nullptr;
}

// ============================================================================
// List (codegen + bootstrap shims — gen_list_lit / gen_index_expr / gen_tuple_lit)
// ============================================================================

extern "C" void* vorton_list_new() {
    CHK("list_new");
    return make_vorton_list(0);
}

extern "C" void* vorton_list_push(void* list, void* val) {
    CHK("list_push");
    vorton_list_push_raw(list, val);
    return list;
}

extern "C" void* vorton_list_get(void* list, int64_t idx) {
    CHK("list_get");
    VortonList* l = as_list(list);
    int64_t ln = list_len(l);
    if (idx < 0 || idx >= ln) {
        fprintf(stderr, "vorton panic: list index %lld out of bounds (len %lld)\n",
                (long long)idx, (long long)ln);
        exit(1);
    }
    // B-098: a list element read is a BORROW — return the element WITHOUT
    // bumping its refcount (it still belongs to the list).  The borrow-inference
    // pass clones (vorton_dup) it only when it escapes into an owned sink.
    return l->buf[idx];
}

extern "C" void* vorton_list_set(void* list, int64_t idx, void* val) {
    VortonList* l = as_list(list);
    int64_t ln = list_len(l);
    if (idx < 0 || idx >= ln) {
        fprintf(stderr, "vorton panic: list index %lld out of bounds (len %lld)\n",
                (long long)idx, (long long)ln);
        exit(1);
    }
    void* old = l->buf[idx];
    l->buf[idx] = val;
    vorton_drop(old);
    return list;
}

extern "C" int64_t vorton_list_len(void* list) {
    CHK("list_len");
    if (!list) { return 0; }
    return list_len(as_list(list));
}

extern "C" void* vorton_list_concat(void* a, void* b) {
    VortonList* la = as_list(a);
    VortonList* lb = as_list(b);
    int64_t la_len = list_len(la);
    int64_t lb_len = list_len(lb);
    void* data = make_vorton_list(la_len + lb_len);
    VortonList* r = as_list(data);
    if (la_len > 0) memmove(r->buf, la->buf, (size_t)la_len * sizeof(void*));
    if (lb_len > 0) memmove(r->buf + la_len, lb->buf, (size_t)lb_len * sizeof(void*));
    list_set_len(r, la_len + lb_len);
    // B-103: the fresh list co-owns elements still owned by `a` and `b` — dup each
    for (int64_t i = 0; i < la_len + lb_len; i++) vorton_dup(r->buf[i]);
    return data;
}

extern "C" void* vorton_list_slice(void* list, int64_t start, int64_t end) {
    VortonList* l = as_list(list);
    int64_t len = list_len(l);
    if (start < 0) start = 0;
    if (end > len) end = len;
    if (start >= end) {
        return make_vorton_list(0);
    }
    int64_t count = end - start;
    void* data = make_vorton_list(count);
    VortonList* r = as_list(data);
    memmove(r->buf, l->buf + start, (size_t)count * sizeof(void*));
    list_set_len(r, count);
    // B-103: dup the copied range — the fresh slice co-owns elements still owned
    // by the source list (owned-container-constructor rule; see vorton_list_concat).
    for (int64_t i = 0; i < count; i++) vorton_dup(r->buf[i]);
    return data;
}

extern "C" void* vorton_list_pop(void* list) {
    VortonList* l = as_list(list);
    int64_t ln = list_len(l);
    if (ln == 0) {
        return vorton_enum_none();
    }
    void* val = l->buf[ln - 1];
    l->buf[ln - 1] = nullptr;
    list_set_len(l, ln - 1);
    void* data = vorton_alloc(sizeof(int64_t) + sizeof(void*), VORTON_TYPEID_OPTION);
    ((int64_t*)data)[0] = 0; // Some tag
    *((void**)((int64_t*)data + 1)) = val;
    return data;
}

extern "C" void* vorton_list_get_opt(void* list, int64_t idx) {
    VortonList* l = as_list(list);
    int64_t ln = list_len(l);
    if (idx < 0 || idx >= ln) {
        return vorton_enum_none();
    }
    void* elem = l->buf[idx];
    vorton_dup(elem);
    return vorton_enum_some(elem);
}

extern "C" void* vorton_list_reverse(void* list) {
    VortonList* l = as_list(list);
    int64_t ln = list_len(l);
    std::reverse(l->buf, l->buf + ln);
    return list;
}

// P2's sole 0.1 C-to-Vorton callback crossing. The borrowed context is forwarded
// synchronously to the comparator and is never retained by the runtime.
typedef void* (*vorton_sort_compare_fn)(
    void* env, void* a, void* b, EffectCtx* effect_ctx);

extern "C" void* vorton_list_sort(
    void* list, void* closure, EffectCtx* effect_ctx
) {
    VortonList* l = as_list(list);
    int64_t ln = list_len(l);
    VortonClosure* cmp = (VortonClosure*)closure;
    vorton_sort_compare_fn fn = (vorton_sort_compare_fn)(cmp->fn_ptr);
    std::sort(l->buf, l->buf + ln,
              [fn, cmp, effect_ctx](void* a, void* b) -> bool {
        void* r = fn(cmp->env_ptr, a, b, effect_ctx);
        int64_t result = vorton_unbox_int(r);
        vorton_drop(r);              // #170: drop comparator's boxed return value
        return result < 0;
    });
    return list;
}

// B-152 P2: bridge for Vorton sort_by method — same as vorton_list_sort.
extern "C" void* vorton_list_sort_bridge(
    void* list, void* closure, EffectCtx* effect_ctx
) {
    return vorton_list_sort(list, closure, effect_ctx);
}

static void* vorton_enum_some(void* val) {
    // (box-profile: OPTION is recorded inside vorton_alloc — see the header note;
    // a second record here would double-sample helper-built Options.)
    void* data = vorton_alloc(sizeof(int64_t) + sizeof(void*), VORTON_TYPEID_OPTION);
    ((int64_t*)data)[0] = 0;
    *((void**)((int64_t*)data + 1)) = val;
    return data;
}

// B-104 D6 (#153): `none` is a lazy memoised PROCESS SINGLETON — the runtime
// mirror of the JS backend's frozen module-level `Option_none` (runtime.vorton:208).
// Allocated once with the never-drop OPTION_NONE typeid (stray dup/drop are
// no-ops; OPTION alloc-stats/box-profile classes stay some-only).  Every none
// producer returns this pointer: the codegen-called vorton_Option_none (defined
// below — the generated module only DECLARES it since D6) and all runtime
// helpers (find/get_opt/pop/try...).  Kills the per-eval fresh none (D5: 64.2M
// live=born=100% @2.382B self-compile) — nobody ever dropped a none because
// HIR/perceus correctly treat `none` as a borrow of a module singleton; the
// fresh-per-eval lowering was the LLVM-backend deviation.
static void* g_vorton_none_singleton = nullptr;
static void* vorton_enum_none() {
    if (!g_vorton_none_singleton) {
        void* data = vorton_alloc(sizeof(int64_t) * 2, VORTON_TYPEID_OPTION_NONE);
        ((int64_t*)data)[0] = 1;
        ((int64_t*)data)[1] = 0;
        g_vorton_none_singleton = data;
    }
    return g_vorton_none_singleton;
}

// The symbol every codegen use-site of `none` calls (gen_ident →
// call_zero_arg_or_return).  Pre-D6 this was a codegen-EMITTED function body
// that vorton_alloc'd a fresh tag-1 OPTION per call; now codegen only forward-
// declares it and the runtime provides the singleton.
extern "C" void* vorton_Option_none() {
    return vorton_enum_none();
}

// ============================================================================
// Option methods
// Option layout: {tag: i64, payload: void*}  tag=0 → Some, tag=1 → None
// ============================================================================

extern "C" void* vorton_Option_unwrap_or(void* opt, void* default_val) {
    int64_t tag = *(int64_t*)opt;
    if (tag == 0) {
        void* value = *((void**)((int64_t*)opt + 1));
        vorton_dup(value);
        return value;
    }
    vorton_dup(default_val);
    return default_val;
}

extern "C" void* vorton_Option_unwrap(void* opt) {
    int64_t tag = *(int64_t*)opt;
    if (tag == 0) {
        void* value = *((void**)((int64_t*)opt + 1));
        vorton_dup(value);
        return value;
    }
    fprintf(stderr, "vorton panic: unwrap() called on None\n");
    exit(1);
    return nullptr;
}

extern "C" int64_t vorton_Option_is_some(void* opt) {
    return *(int64_t*)opt == 0 ? 1 : 0;
}

extern "C" int64_t vorton_Option_is_none(void* opt) {
    return *(int64_t*)opt == 1 ? 1 : 0;
}

typedef void* (*vorton_option_fn_1)(
    void* env, void* arg, EffectCtx* effect_ctx);
typedef void* (*vorton_option_fn_0)(void* env, EffectCtx* effect_ctx);

extern "C" void* vorton_Option_map(
    void* opt, void* closure, EffectCtx* effect_ctx
) {
    int64_t tag = *(int64_t*)opt;
    if (tag == 0) {
        void* val = *((void**)((int64_t*)opt + 1));
        VortonClosure* cl = (VortonClosure*)closure;
        vorton_option_fn_1 fn = (vorton_option_fn_1)cl->fn_ptr;
        void* result = fn(cl->env_ptr, val, effect_ctx);
        return vorton_enum_some(result);
    }
    return vorton_enum_none();
}

extern "C" void* vorton_Option_and_then(
    void* opt, void* closure, EffectCtx* effect_ctx
) {
    int64_t tag = *(int64_t*)opt;
    if (tag == 0) {
        void* val = *((void**)((int64_t*)opt + 1));
        VortonClosure* cl = (VortonClosure*)closure;
        vorton_option_fn_1 fn = (vorton_option_fn_1)cl->fn_ptr;
        return fn(cl->env_ptr, val, effect_ctx);
    }
    return vorton_enum_none();
}

// to_fail: Some(v) -> v; None -> raise the fail effect with `err` as the error
// value. The LLVM backend lowers `fail.raise` to a direct vorton_raise (longjmp
// into the enclosing vorton_try set up by `catch`), so to_fail can raise here
// without threading the fail evidence. Returns nullptr on the None branch only
// for type-correctness; vorton_raise never returns.
extern "C" void* vorton_Option_to_fail(void* opt, void* err) {
    int64_t tag = *(int64_t*)opt;
    if (tag == 0) {
        void* value = *((void**)((int64_t*)opt + 1));
        vorton_dup(value);
        return value;
    }
    vorton_dup(err);
    vorton_raise(err);
    return nullptr;
}

extern "C" void* vorton_Option_unwrap_or_else(
    void* opt, void* closure, EffectCtx* effect_ctx
) {
    int64_t tag = *(int64_t*)opt;
    if (tag == 0) {
        void* value = *((void**)((int64_t*)opt + 1));
        vorton_dup(value);
        return value;
    }
    VortonClosure* cl = (VortonClosure*)closure;
    vorton_option_fn_0 fn = (vorton_option_fn_0)cl->fn_ptr;
    return fn(cl->env_ptr, effect_ctx);
}

extern "C" int64_t vorton_list_any(void* list, void* closure) {
    VortonList* l = as_list(list);
    int64_t ln = list_len(l);
    VortonClosure* cls = (VortonClosure*)closure;
    vorton_fn_1 fn = (vorton_fn_1)(cls->fn_ptr);
    for (int64_t i = 0; i < ln; i++) {
        void* r = fn(cls->env_ptr, l->buf[i]);
        int match = vorton_unbox_int(r) != 0;
        vorton_drop(r);
        if (match) return 1;
    }
    return 0;
}

extern "C" int64_t vorton_list_all(void* list, void* closure) {
    VortonList* l = as_list(list);
    int64_t ln = list_len(l);
    VortonClosure* cls = (VortonClosure*)closure;
    vorton_fn_1 fn = (vorton_fn_1)(cls->fn_ptr);
    for (int64_t i = 0; i < ln; i++) {
        void* r = fn(cls->env_ptr, l->buf[i]);
        int match = vorton_unbox_int(r) == 0;
        vorton_drop(r);
        if (match) return 0;
    }
    return 1;
}

extern "C" void* vorton_list_find(void* list, void* closure) {
    VortonList* l = as_list(list);
    int64_t ln = list_len(l);
    VortonClosure* cls = (VortonClosure*)closure;
    vorton_fn_1 fn = (vorton_fn_1)(cls->fn_ptr);
    for (int64_t i = 0; i < ln; i++) {
        void* r = fn(cls->env_ptr, l->buf[i]);
        int match = vorton_unbox_int(r) != 0;
        vorton_drop(r);
        if (match) {
            void* elem = l->buf[i];
            vorton_dup(elem);
            return vorton_enum_some(elem);
        }
    }
    return vorton_enum_none();
}

extern "C" void* vorton_list_find_index(void* list, void* closure) {
    VortonList* l = as_list(list);
    int64_t ln = list_len(l);
    VortonClosure* cls = (VortonClosure*)closure;
    vorton_fn_1 fn = (vorton_fn_1)(cls->fn_ptr);
    for (int64_t i = 0; i < ln; i++) {
        void* r = fn(cls->env_ptr, l->buf[i]);
        int match = vorton_unbox_int(r) != 0;
        vorton_drop(r);
        if (match) {
            return vorton_enum_some(vorton_box_int(i));
        }
    }
    return vorton_enum_none();
}

extern "C" void* vorton_list_fold(void* list, void* init, void* closure) {
    VortonList* l = as_list(list);
    // B-104 D1 Stage 3 (audit #150): on the EMPTY path the result is `init`.
    // Returning it VERBATIM while the caller's result binding MOVES it would
    // make the binding co-own one box with init's owner — double-free at scope
    // end.  Dup so the fold result is owned on EVERY path (the non-empty path
    // returns the closure's owned result; B-103 dup-on-share pattern, see
    // vorton_list_filter / vorton_list_concat).  This dup is what retired `fold`
    // from is_arg_returning_call and the perceus anf_arg mechanism.
    int64_t ln = list_len(l);
    if (ln == 0) {
        vorton_dup(init);
        return init;
    }
    VortonClosure* cls = (VortonClosure*)closure;
    vorton_fn_2 fn = (vorton_fn_2)(cls->fn_ptr);
    void* acc = init;
    for (int64_t i = 0; i < ln; i++) {
        void* old_acc = acc;
        acc = fn(cls->env_ptr, old_acc, l->buf[i]);
        if (i > 0) vorton_drop(old_acc);
    }
    return acc;
}

extern "C" void* vorton_list_map(void* list, void* closure) {
    if (!list) {
        return make_vorton_list(0);
    }
    VortonList* l = as_list(list);
    int64_t ln = list_len(l);
    void* data = make_vorton_list(ln);
    VortonClosure* cls = (VortonClosure*)closure;
    vorton_fn_1 fn = (vorton_fn_1)(cls->fn_ptr);
    for (int64_t i = 0; i < ln; i++) {
        vorton_list_push_raw(data, fn(cls->env_ptr, l->buf[i]));
    }
    return data;
}

extern "C" void* vorton_list_filter(void* list, void* closure) {
    VortonList* l = as_list(list);
    int64_t ln = list_len(l);
    void* data = make_vorton_list(0);
    VortonClosure* cls = (VortonClosure*)closure;
    vorton_fn_1 fn = (vorton_fn_1)(cls->fn_ptr);
    for (int64_t i = 0; i < ln; i++) {
        void* r = fn(cls->env_ptr, l->buf[i]);
        int match = vorton_unbox_int(r) != 0;
        vorton_drop(r);
        if (match) {
            vorton_dup(l->buf[i]);
            vorton_list_push_raw(data, l->buf[i]);
        }
    }
    return data;
}

extern "C" void* vorton_list_for_each(void* list, void* closure) {
    VortonList* l = as_list(list);
    int64_t ln = list_len(l);
    VortonClosure* cls = (VortonClosure*)closure;
    vorton_fn_1 fn = (vorton_fn_1)(cls->fn_ptr);
    for (int64_t i = 0; i < ln; i++) {
        fn(cls->env_ptr, l->buf[i]);
    }
    return nullptr;
}

extern "C" int64_t vorton_list_is_empty(void* list) {
    return list_len(as_list(list)) == 0 ? 1 : 0;
}

extern "C" void* vorton_list_last(void* list) {
    VortonList* l = as_list(list);
    int64_t ln = list_len(l);
    if (ln == 0) {
        return vorton_enum_none();
    }
    void* elem = l->buf[ln - 1];
    vorton_dup(elem);
    return vorton_enum_some(elem);
}

extern "C" void* vorton_list_first(void* list) {
    VortonList* l = as_list(list);
    int64_t ln = list_len(l);
    if (ln == 0) {
        return vorton_enum_none();
    }
    void* elem = l->buf[0];
    vorton_dup(elem);
    return vorton_enum_some(elem);
}

extern "C" void* vorton_list_flat_map(void* list, void* closure) {
    void* data = make_vorton_list(0);
    if (!list) return data;
    VortonList* l = as_list(list);
    int64_t ln = list_len(l);
    VortonClosure* cls = (VortonClosure*)closure;
    vorton_fn_1 fn = (vorton_fn_1)(cls->fn_ptr);
    for (int64_t i = 0; i < ln; i++) {
        void* sub = fn(cls->env_ptr, l->buf[i]);
        if (sub) {
            VortonList* sl = as_list(sub);
            int64_t sln = list_len(sl);
            for (int64_t j = 0; j < sln; j++) {
                vorton_dup(sl->buf[j]);
                vorton_list_push_raw(data, sl->buf[j]);
            }
            vorton_drop(sub);
        }
    }
    return data;
}

// ============================================================================
// Map — B-152 P3: Map is now a pure Vorton struct
// ============================================================================
//
// New layout: { void* meta, void** keys, void** values, void* len_tagged, void* cap_tagged }
// meta: byte buffer (0=empty, 1=occupied, 2=tombstone), keys/values: slot buffers
// len/cap: tagged ints (Vorton boxed Int)
//
// Map operations are implemented by std/map.vorton.  The runtime keeps this
// layout mirror only so the fixed RC type-id can dispatch to drop_map.

struct VortonMapStruct {
    void*  meta;       // byte buffer (uint8_t array)
    void** keys;       // slot buffer (void* array)
    void** values;     // slot buffer (void* array)
    void*  len_tagged; // tagged int
    void*  cap_tagged; // tagged int
};

// ============================================================================
// IO / FS / Process (~8)
// ============================================================================

extern "C" void* vorton_print(void* s) {
    CHK("PRINT");
    VortonStr* str = as_str(s);
    fwrite(str->buf, 1, (size_t)str->len, stdout);
    fputc('\n', stdout);
    fflush(stdout);
    fflush(stderr);
    return nullptr;
}

extern "C" void* vorton_eprintln(void* s) {
    CHK("EPRINTLN");
    VortonStr* str = as_str(s);
    fwrite(str->buf, 1, (size_t)str->len, stderr);
    fputc('\n', stderr);
    fflush(stderr);
    return nullptr;
}

extern "C" void* vorton_panic(void* s) {
    CHK("PANIC");
    if (s) {
        fprintf(stderr, "vorton panic: %s\n", as_str(s)->buf);
    } else {
        fprintf(stderr, "vorton panic: (null message)\n");
    }
    fflush(stderr);
    exit(1);
    return nullptr;  // unreachable
}

// Diagnostic for non-exhaustive enum match: a value reached a match whose tag
// matched no arm. Reports the enum name + enclosing fn (baked in at codegen) and
// the runtime tag. A tag outside the variant range means a miscompiled value.
extern "C" void* vorton_match_fail(void* enum_name, int64_t tag, int64_t site, void* scrut) {
    (void)scrut;
    fprintf(stderr, "vorton panic: non-exhaustive match on enum '%s' (runtime tag=%lld, site #%lld)\n",
            enum_name ? as_str(enum_name)->buf : "?",
            (long long)tag, (long long)site);
    fflush(stderr);
    exit(1);
    return nullptr;  // unreachable
}

extern "C" void* vorton_read_file(void* path) {
    VortonStr* p = as_str(path);
    FILE* f = fopen(p->buf, "rb");
    if (!f) {
        fprintf(stderr, "vorton panic: cannot open file: %s\n", p->buf);
        exit(1);
    }
    fseek(f, 0, SEEK_END);
#ifdef _WIN32
    // #171: ftell returns 32-bit long on MSVC; _ftelli64 handles >2GB files.
    int64_t size = _ftelli64(f);
#else
    long size = ftell(f);
#endif
    if (size < 0) {
        fprintf(stderr, "vorton panic: cannot determine file size: %s\n", p->buf);
        fclose(f);
        exit(1);
    }
    fseek(f, 0, SEEK_SET);
    void* data = vorton_alloc(sizeof(VortonStr), VORTON_TYPEID_STR);
    VortonStr* rs = as_str(data);
    rs->len = (int64_t)size;
    rs->cap = (int64_t)size + 1;
    rs->buf = (char*)malloc((size_t)rs->cap);
    size_t read = fread(rs->buf, 1, (size_t)size, f);
    rs->len = (int64_t)read;  // use actual bytes read (may be less than size)
    rs->buf[read] = '\0';
    fclose(f);
    return data;
}

extern "C" void* vorton_write_file(void* path, void* content) {
    VortonStr* p = as_str(path);
    VortonStr* c = as_str(content);
    FILE* f = fopen(p->buf, "wb");
    if (!f) {
        fprintf(stderr, "vorton panic: cannot write file: %s\n", p->buf);
        exit(1);
    }
    fwrite(c->buf, 1, (size_t)c->len, f);
    fclose(f);
    return nullptr;
}

extern "C" void* vorton_exit(void* boxed_code) {
    int64_t code = vorton_unbox_int(boxed_code);
    exit((int)code);
    return nullptr;  // unreachable
}

extern "C" void* vorton_args() {
    void* ldata = make_vorton_list(g_argc > 1 ? (int64_t)(g_argc - 1) : 0);
    for (int i = 1; i < g_argc; i++) {
        vorton_list_push_raw(ldata, make_vorton_str(g_argv[i], (int64_t)strlen(g_argv[i])));
    }
    return ldata;
}

extern "C" void* vorton_cwd() {
    char buf[4096];
#ifdef _WIN32
    if (_getcwd(buf, sizeof(buf)) == nullptr) {
#else
    if (getcwd(buf, sizeof(buf)) == nullptr) {
#endif
        fprintf(stderr, "vorton panic: getcwd failed\n");
        exit(1);
    }
    return make_vorton_str(buf, (int64_t)strlen(buf));
}

// B-163 step 1: exec_sync(cmd: Str, args: List<Str>) -> Int (std/process.vorton).
// Declared in std since B-151 but never implemented in the native runtime; the
// C backend needs it to shell out `clang -c <file>.c -o <file>.o`.
// Uniform boxed ABI (extern fn fallback declaration): all params void*, returns
// a tagged Int (child exit code; -1 if the process could not be spawned).
// Windows: _spawnvp does NOT quote argv entries itself — quote any arg that
// contains spaces (paths under "C:\Users\Yufeng Ying\..." etc.).
extern "C" void* exec_sync(void* cmd, void* args) {
    VortonStr* c = as_str(cmd);
    int64_t n = vorton_list_len(args);
    std::vector<std::string> storage;
    storage.reserve((size_t)n + 1);
    storage.push_back(std::string(c->buf, (size_t)c->len));
    for (int64_t i = 0; i < n; i++) {
        VortonStr* a = as_str(vorton_list_get(args, i));
        storage.push_back(std::string(a->buf, (size_t)a->len));
    }
#ifdef _WIN32
    for (size_t i = 0; i < storage.size(); i++) {
        if (storage[i].empty() || storage[i].find(' ') != std::string::npos) {
            storage[i] = "\"" + storage[i] + "\"";
        }
    }
    std::vector<const char*> argv;
    for (size_t i = 0; i < storage.size(); i++) argv.push_back(storage[i].c_str());
    argv.push_back(nullptr);
    intptr_t code = _spawnvp(_P_WAIT, c->buf, argv.data());
    if (code == -1) return (void*)(((uintptr_t)(int64_t)-1 << 1) | 1);
    return (void*)(((uintptr_t)(int64_t)code << 1) | 1);
#else
    pid_t pid = fork();
    if (pid < 0) return (void*)(((uintptr_t)(int64_t)-1 << 1) | 1);
    if (pid == 0) {
        std::vector<char*> argv;
        for (size_t i = 0; i < storage.size(); i++) argv.push_back(const_cast<char*>(storage[i].c_str()));
        argv.push_back(nullptr);
        execvp(c->buf, argv.data());
        _exit(127);
    }
    int status = 0;
    if (waitpid(pid, &status, 0) < 0) return (void*)(((uintptr_t)(int64_t)-1 << 1) | 1);
    int64_t code = WIFEXITED(status) ? (int64_t)WEXITSTATUS(status) : (int64_t)-1;
    return (void*)(((uintptr_t)code << 1) | 1);
#endif
}

// ============================================================================
// StringBuilder (~4)
// ============================================================================

extern "C" void* vorton_sb_new() {
    void* data = vorton_alloc(sizeof(std::string), VORTON_TYPEID_SB);
    new (data) std::string();
#ifdef VORTON_BOX_PROFILE
    // B-104 D8: StringBuilder births — RA = the IR site allocating the SB (the
    // type_to_string / interp machinery is the dominant class per D5).  Distinct
    // from the STR recorded at vorton_sb_to_str (that's the RESULT string, this is
    // the builder itself).
    vorton_box_profile_record(data, _ReturnAddress(), VORTON_TYPEID_SB);
#endif
    return data;
}

extern "C" void* vorton_sb_add(void* sb, void* s) {
    VortonStr* rs = as_str(s);
    ((std::string*)sb)->append(rs->buf, (size_t)rs->len);
    return sb;
}

extern "C" void* vorton_sb_to_str(void* sb) {
    std::string* sbs = (std::string*)sb;
    void* data = vorton_alloc(sizeof(VortonStr), VORTON_TYPEID_STR);
    VortonStr* rs = as_str(data);
    rs->len = (int64_t)sbs->size();
    rs->cap = rs->len + 1;
    rs->buf = (char*)malloc((size_t)rs->cap);
    if (rs->len > 0) memcpy(rs->buf, sbs->c_str(), (size_t)rs->len);
    rs->buf[rs->len] = '\0';
#ifdef VORTON_BOX_PROFILE
    // B-104 D5: StringBuilder.to_str results — RA = the IR call site (D5 run 1:
    // 11.7% of live STR).
    vorton_box_profile_record(data, _ReturnAddress(), VORTON_TYPEID_STR);
#endif
    return data;
}

extern "C" int64_t vorton_sb_len(void* sb) {
    return (int64_t)((std::string*)sb)->size();
}

// ============================================================================
// Cell — user-facing mutable container (~4)
// ============================================================================
// Cell<T> wraps a single value. Internally it is a heap-allocated slot
// (same typeid as the compiler's write-through mut-cell, VORTON_TYPEID_CELL=14).
// Semantics mirror the JS runtime: Cell(v) → {value: v}, .get() → value,
// .set(v) replaces value (drop old, dup new), .update(f) applies callback.

extern "C" void* vorton_Cell_new(void* value) {
    void* data = vorton_alloc(sizeof(void*), VORTON_TYPEID_CELL);
    // Dup the value: Perceus treats Cell() constructor arguments as borrows
    // (Cell(x) lowers to HExpr::Call, not StructLit, so the arg is not an
    // escape/sink position — the ANF temp gets a scope-end drop).  The cell
    // must own its own reference so drop_cell's vorton_drop(value) is balanced.
    // Same owned-container-constructor pattern as vorton_list_get_opt / first /
    // last (B-103): dup on co-own, balanced by drop_cell.
    vorton_dup(value);
    *(void**)data = value;
    return data;
}

extern "C" void* vorton_Cell_get(void* cell) {
    void* value = *(void**)cell;
    // Dup the value: Perceus classifies .get() as an owned-returning call
    // (not in is_borrow_returning_call), so the result binding is scope-end-
    // dropped.  Without dup, that drop frees the cell's interior reference
    // (double-free when drop_cell runs).  Same owned-container-constructor
    // pattern as vorton_list_get_opt / first / last (B-103).
    vorton_dup(value);
    return value;
}

extern "C" void* vorton_Cell_set(void* cell, void* new_val) {
    // Sink pattern (same as vorton_list_set): the val arg is a sink position —
    // Perceus clones borrows and transfers owned temps. Store first, then drop
    // old (avoids UAF on self-assign where old == new_val with shared rc).
    void* old = *(void**)cell;
    *(void**)cell = new_val;
    vorton_drop(old);
    return cell;                 // return receiver (Unit-typed call site discards this)
}

typedef void* (*vorton_cell_update_fn)(
    void* env, void* arg, EffectCtx* effect_ctx);

extern "C" void* vorton_Cell_update(
    void* cell, void* closure, EffectCtx* effect_ctx
) {
    // #165: Reentrant-safe Cell.update. If the callback captures the same Cell
    // and calls .set(new_value), vorton_Cell_set would drop old_val (the value we
    // passed to the callback). Setting the cell to nullptr before the call
    // prevents set's drop from hitting our old_val. We dup old_val so the
    // callback consumes one ref and we drop the other after the call.
    void* old_val = *(void**)cell;
    *(void**)cell = nullptr;       // prevent callback's .set() from dropping old_val
    vorton_dup(old_val);             // callback consumes one ref, we drop the other
    VortonClosure* cl = (VortonClosure*)closure;
    vorton_cell_update_fn fn = (vorton_cell_update_fn)cl->fn_ptr;
    (void)effect_ctx;
    void* new_val = fn(
        cl->env_ptr, old_val, vorton_effect_ctx_empty());
    // A reentrant callback may have installed an interim value through
    // Cell.set. Install the callback result before releasing that separate
    // owned sink, matching vorton_Cell_set's store-before-drop discipline.
    void* interim = *(void**)cell;
    *(void**)cell = new_val;
    if (interim) vorton_drop(interim);
    vorton_drop(old_val);            // drop our retained reference exactly once
    return cell;
}

// ============================================================================
// setjmp/longjmp — fail effect handler stack (~5)
// ============================================================================

struct VortonCatchFrame {
    jmp_buf buf;
    void* error_value;
    VortonCatchFrame* prev;
};

#ifdef _WIN32
__declspec(thread) static VortonCatchFrame* vorton_catch_stack = nullptr;
#else
thread_local VortonCatchFrame* vorton_catch_stack = nullptr;
#endif

extern "C" void* vorton_catch_push() {
    VortonCatchFrame* frame = new VortonCatchFrame();
    frame->error_value = nullptr;
    frame->prev = vorton_catch_stack;
    vorton_catch_stack = frame;
    return (void*)frame;
}

extern "C" void vorton_raise(void* error) {
    if (!vorton_catch_stack) {
        fprintf(stderr, "vorton panic: unhandled effect raise (no catch frame)\n");
        exit(1);
    }
    VortonCatchFrame* frame = vorton_catch_stack;
    frame->error_value = error;
    longjmp(frame->buf, 1);
}

extern "C" void* __vorton_raise_fail(void* msg) {
    vorton_raise(msg);
    return nullptr;
}

extern "C" void* vorton_catch_get_error(void* frame_ptr) {
    return ((VortonCatchFrame*)frame_ptr)->error_value;
}

extern "C" void* vorton_catch_get_buf(void* frame_ptr) {
    return (void*)((VortonCatchFrame*)frame_ptr)->buf;
}

extern "C" void vorton_catch_pop() {
    VortonCatchFrame* frame = vorton_catch_stack;
    vorton_catch_stack = frame->prev;
    delete frame;
}

// vorton_try: correct setjmp/longjmp scoping for `body catch { arms }`.
// The catch frame and setjmp live in THIS function's stack frame, and the body
// closure is invoked nested from here — so a longjmp (from a deeply-nested
// fail.raise) returns into a frame that is still live, unlike a setjmp performed
// inside a wrapper that has already returned.
//   body_cl  : closure {fn(env)->ptr, env}
//   catch_cl : closure {fn(env, error)->ptr, env}
extern "C" void* vorton_try(void* body_cl, void* catch_cl) {
    VortonCatchFrame frame;
    frame.error_value = nullptr;
    frame.prev = vorton_catch_stack;
    vorton_catch_stack = &frame;
    void** bc = (void**)body_cl;
    void** cc = (void**)catch_cl;
    if (setjmp(frame.buf) == 0) {
        void* (*bfn)(void*) = (void* (*)(void*))bc[0];
        void* result = bfn(bc[1]);
        vorton_catch_stack = frame.prev;   // normal completion: pop
        return result;
    } else {
        vorton_catch_stack = frame.prev;   // caught: pop, then run catch arm
        void* err = frame.error_value;
        void* (*cfn)(void*, void*) = (void* (*)(void*, void*))cc[0];
        return cfn(cc[1], err);
    }
}

// ============================================================================
// Path operations (~5)
// ============================================================================

extern "C" void* vorton_path_join(void* a, void* b) {
    VortonStr* sa = as_str(a);
    VortonStr* sb = as_str(b);
    if (sa->len == 0) return make_vorton_str(sb->buf, sb->len);
    if (sb->len == 0) return make_vorton_str(sa->buf, sa->len);
    char last = sa->buf[sa->len - 1];
    if (last == '/' || last == '\\') {
        // a already ends with separator
        int64_t new_len = sa->len + sb->len;
        void* data = vorton_alloc(sizeof(VortonStr), VORTON_TYPEID_STR);
        VortonStr* rs = as_str(data);
        rs->len = new_len; rs->cap = new_len + 1;
        rs->buf = (char*)malloc((size_t)rs->cap);
        memcpy(rs->buf, sa->buf, (size_t)sa->len);
        memcpy(rs->buf + sa->len, sb->buf, (size_t)sb->len);
        rs->buf[new_len] = '\0';
        return data;
    }
    int64_t new_len = sa->len + 1 + sb->len;
    void* data = vorton_alloc(sizeof(VortonStr), VORTON_TYPEID_STR);
    VortonStr* rs = as_str(data);
    rs->len = new_len; rs->cap = new_len + 1;
    rs->buf = (char*)malloc((size_t)rs->cap);
    memcpy(rs->buf, sa->buf, (size_t)sa->len);
    rs->buf[sa->len] = PATH_SEP;
    memcpy(rs->buf + sa->len + 1, sb->buf, (size_t)sb->len);
    rs->buf[new_len] = '\0';
    return data;
}

extern "C" void* vorton_path_resolve(void* p) {
    VortonStr* sp = as_str(p);
#ifdef _WIN32
    char buf[4096];
    DWORD len = GetFullPathNameA(sp->buf, sizeof(buf), buf, nullptr);
    if (len == 0 || len >= sizeof(buf)) {
        return make_vorton_str(sp->buf, sp->len);
    }
    return make_vorton_str(buf, (int64_t)strlen(buf));
#else
    char* resolved = realpath(sp->buf, nullptr);
    if (!resolved) {
        return make_vorton_str(sp->buf, sp->len);
    }
    void* data = make_vorton_str(resolved, (int64_t)strlen(resolved));
    free(resolved);
    return data;
#endif
}

extern "C" void* vorton_path_dirname(void* p) {
    VortonStr* sp = as_str(p);
    int64_t pos = -1;
    for (int64_t i = sp->len - 1; i >= 0; i--) {
        if (sp->buf[i] == '/' || sp->buf[i] == '\\') { pos = i; break; }
    }
    if (pos < 0) return make_vorton_str(".", 1);
    return make_vorton_str(sp->buf, pos);
}

extern "C" void* vorton_path_basename(void* p) {
    VortonStr* sp = as_str(p);
    int64_t pos = -1;
    for (int64_t i = sp->len - 1; i >= 0; i--) {
        if (sp->buf[i] == '/' || sp->buf[i] == '\\') { pos = i; break; }
    }
    if (pos < 0) return make_vorton_str(sp->buf, sp->len);
    return make_vorton_str(sp->buf + pos + 1, sp->len - pos - 1);
}

extern "C" void* vorton_path_extname(void* p) {
    VortonStr* sp = as_str(p);
    int64_t slash = -1, dot = -1;
    for (int64_t i = sp->len - 1; i >= 0; i--) {
        if ((sp->buf[i] == '/' || sp->buf[i] == '\\') && slash < 0) slash = i;
        if (sp->buf[i] == '.' && dot < 0) dot = i;
    }
    if (dot < 0 || (slash >= 0 && dot < slash)) {
        return make_vorton_str("", 0);
    }
    return make_vorton_str(sp->buf + dot, sp->len - dot);
}

// ============================================================================
// File operations (additional)
// ============================================================================

extern "C" void* vorton_file_exists(void* path) {
    VortonStr* p = as_str(path);
#ifdef _WIN32
    int64_t exists = _access(p->buf, 0) == 0 ? 1 : 0;
#else
    int64_t exists = access(p->buf, F_OK) == 0 ? 1 : 0;
#endif
    return vorton_box_bool(exists);
}

extern "C" void* vorton_delete_file(void* path) {
    VortonStr* p = as_str(path);
    remove(p->buf);
    return nullptr;
}

// ============================================================================
// String operations (additional)
// ============================================================================

extern "C" void* vorton_str_trim(void* s) {
    VortonStr* str = as_str(s);
    int64_t start = 0;
    while (start < str->len && isspace((unsigned char)str->buf[start])) start++;
    int64_t end = str->len;
    while (end > start && isspace((unsigned char)str->buf[end - 1])) end--;
    return make_vorton_str(str->buf + start, end - start);
}

extern "C" void* vorton_str_trim_start(void* s) {
    VortonStr* str = as_str(s);
    int64_t start = 0;
    while (start < str->len && isspace((unsigned char)str->buf[start])) start++;
    return make_vorton_str(str->buf + start, str->len - start);
}

extern "C" void* vorton_str_trim_end(void* s) {
    VortonStr* str = as_str(s);
    int64_t end = str->len;
    while (end > 0 && isspace((unsigned char)str->buf[end - 1])) end--;
    return make_vorton_str(str->buf, end);
}

extern "C" void* vorton_str_to_upper(void* s) {
    VortonStr* str = as_str(s);
    void* data = vorton_alloc(sizeof(VortonStr), VORTON_TYPEID_STR);
    VortonStr* rs = as_str(data);
    rs->len = str->len;
    rs->cap = str->len + 1;
    rs->buf = (char*)malloc((size_t)rs->cap);
    for (int64_t i = 0; i < str->len; i++) {
        rs->buf[i] = (char)toupper((unsigned char)str->buf[i]);
    }
    rs->buf[str->len] = '\0';
    return data;
}

extern "C" void* vorton_str_to_lower(void* s) {
    VortonStr* str = as_str(s);
    void* data = vorton_alloc(sizeof(VortonStr), VORTON_TYPEID_STR);
    VortonStr* rs = as_str(data);
    rs->len = str->len;
    rs->cap = str->len + 1;
    rs->buf = (char*)malloc((size_t)rs->cap);
    for (int64_t i = 0; i < str->len; i++) {
        rs->buf[i] = (char)tolower((unsigned char)str->buf[i]);
    }
    rs->buf[str->len] = '\0';
    return data;
}

extern "C" void* vorton_str_char_at(void* s, int64_t idx) {
    VortonStr* str = as_str(s);
    if (idx < 0 || idx >= str->len) {
        return vorton_enum_none();
    }
    void* sd = make_vorton_str(str->buf + idx, 1);
    return vorton_enum_some(sd);
}

extern "C" void* vorton_str_index_of(void* s, void* sub) {
    VortonStr* str = as_str(s);
    VortonStr* needle = as_str(sub);
    const char* found = vorton_memmem(str->buf, (size_t)str->len, needle->buf, (size_t)needle->len);
    if (!found) {
        return vorton_enum_none();
    }
    return vorton_enum_some(vorton_box_int((int64_t)(found - str->buf)));
}

extern "C" void* vorton_str_last_index_of(void* s, void* sub) {
    VortonStr* str = as_str(s);
    VortonStr* needle = as_str(sub);
    if (needle->len == 0) {
        return vorton_enum_some(vorton_box_int(str->len));
    }
    if (needle->len > str->len) {
        return vorton_enum_none();
    }
    for (int64_t i = str->len - needle->len; i >= 0; i--) {
        if (memcmp(str->buf + i, needle->buf, (size_t)needle->len) == 0) {
            return vorton_enum_some(vorton_box_int(i));
        }
    }
    return vorton_enum_none();
}

extern "C" int64_t vorton_str_is_empty(void* s) {
    return as_str(s)->len == 0 ? 1 : 0;
}

extern "C" void* vorton_str_pad_start(void* s, int64_t length, void* fill) {
    VortonStr* str = as_str(s);
    VortonStr* filler = as_str(fill);
    if (str->len >= length || filler->len == 0) {
        return make_vorton_str(str->buf, str->len);
    }
    std::string pad(filler->buf, (size_t)filler->len);
    std::string result;
    while ((int64_t)(result.size() + (size_t)str->len) < length) {
        result += pad;
    }
    result = result.substr(0, (size_t)(length - str->len));
    result.append(str->buf, (size_t)str->len);
    return make_vorton_str(result.c_str(), (int64_t)result.size());
}

extern "C" void* vorton_str_pad_end(void* s, int64_t length, void* fill) {
    VortonStr* str = as_str(s);
    VortonStr* filler = as_str(fill);
    if (str->len >= length || filler->len == 0) {
        return make_vorton_str(str->buf, str->len);
    }
    std::string pad(filler->buf, (size_t)filler->len);
    std::string result(str->buf, (size_t)str->len);
    while ((int64_t)result.size() < length) {
        result += pad;
    }
    result = result.substr(0, (size_t)length);
    return make_vorton_str(result.c_str(), (int64_t)result.size());
}

extern "C" void* vorton_str_repeat(void* s, int64_t count) {
    VortonStr* str = as_str(s);
    int64_t total = str->len * count;
    void* data = vorton_alloc(sizeof(VortonStr), VORTON_TYPEID_STR);
    VortonStr* rs = as_str(data);
    rs->len = total;
    rs->cap = total + 1;
    rs->buf = (char*)malloc((size_t)rs->cap);
    int64_t off = 0;
    for (int64_t i = 0; i < count; i++) {
        if (str->len > 0) memcpy(rs->buf + off, str->buf, (size_t)str->len);
        off += str->len;
    }
    rs->buf[total] = '\0';
    return data;
}

extern "C" void* vorton_str_char_code_at(void* s, int64_t idx) {
    CHK("str_char_code_at");
    VortonStr* str = as_str(s);
    if (idx < 0 || idx >= str->len) {
        return vorton_enum_none();
    }
    return vorton_enum_some(vorton_box_int((int64_t)(unsigned char)str->buf[idx]));
}

// ============================================================================
// StringBuilder (additional)
// ============================================================================

extern "C" void* vorton_sb_line(void* sb, void* s) {
    if (s) {
        VortonStr* rs = as_str(s);
        ((std::string*)sb)->append(rs->buf, (size_t)rs->len);
    }
    *(std::string*)sb += "\n";
    return sb;
}

extern "C" void* vorton_sb_add_int(void* sb, int64_t n) {
    *(std::string*)sb += std::to_string(n);
    return sb;
}

// ============================================================================
// B-152 RIIR bridge functions — StringBuilder struct in Vorton, raw-memory ops in C
// NOTE: Int args are B-080 tagged pointers: (val << 1) | 1.  Use vorton_unbox_int.
// ============================================================================

extern "C" int64_t vorton_unbox_int(void*);  // forward decl

extern "C" void* vorton_str_as_ptr(void* s) {
    return (void*)as_str(s)->buf;
}

extern "C" void* vorton_str_from_ptr(void* ptr, void* len_tagged) {
    int64_t len = vorton_unbox_int(len_tagged);
    return make_vorton_str((const char*)ptr, len);
}

extern "C" void* vorton_buf_alloc(void* cap_tagged) {
    int64_t cap = vorton_unbox_int(cap_tagged);
    if (cap < 0) {
        vorton_raw_request_panic("vorton_buf_alloc", "negative allocation request", cap);
    }
    if (cap == 0) return nullptr;
    void* buffer = malloc((size_t)cap);
    if (!buffer) {
        vorton_raw_request_panic("vorton_buf_alloc", "allocation failed", cap);
    }
    return buffer;
}

extern "C" void* vorton_buf_alloc_zeroed(void* cap_tagged) {
    int64_t cap = vorton_unbox_int(cap_tagged);
    if (cap < 0) {
        vorton_raw_request_panic("vorton_buf_alloc_zeroed", "negative allocation request", cap);
    }
    if (cap == 0) return nullptr;
    void* buffer = calloc((size_t)cap, 1);
    if (!buffer) {
        vorton_raw_request_panic("vorton_buf_alloc_zeroed", "allocation failed", cap);
    }
    return buffer;
}

extern "C" void* vorton_buf_dealloc(void* p) {
    free(p);
    return nullptr;
}

extern "C" void* vorton_buf_grow(void* old, void* old_len_tagged, void* new_cap_tagged) {
    int64_t old_len = vorton_unbox_int(old_len_tagged);
    int64_t new_cap = vorton_unbox_int(new_cap_tagged);
    void* new_buf = malloc((size_t)new_cap);
    if (old_len > 0) memcpy(new_buf, old, (size_t)old_len);
    free(old);
    return new_buf;
}

extern "C" void* vorton_buf_copy_at(void* dst, void* offset_tagged, void* src, void* len_tagged) {
    int64_t offset = vorton_unbox_int(offset_tagged);
    int64_t len = vorton_unbox_int(len_tagged);
    if (len > 0) memcpy((char*)dst + offset, src, (size_t)len);
    return nullptr;
}

extern "C" void* vorton_buf_set_byte(void* p, void* offset_tagged, void* val_tagged) {
    int64_t offset = vorton_unbox_int(offset_tagged);
    int64_t val = vorton_unbox_int(val_tagged);
    ((uint8_t*)p)[(size_t)offset] = (uint8_t)val;
    return nullptr;
}

extern "C" void* vorton_buf_get_byte(void* p, void* offset_tagged) {
    int64_t offset = vorton_unbox_int(offset_tagged);
    return vorton_box_int((int64_t)((uint8_t*)p)[(size_t)offset]);
}

// ============================================================================
// Parse functions
// ============================================================================

extern "C" void* vorton_parse_int(void* s) {
    VortonStr* str = as_str(s);
    try {
        std::string tmp(str->buf, (size_t)str->len);
        size_t pos;
        int64_t val = std::stoll(tmp, &pos);
        if (pos == tmp.size()) {
            return vorton_enum_some(vorton_box_int(val));
        }
    } catch (const std::invalid_argument&) {
    } catch (const std::out_of_range&) {}
    return vorton_enum_none();
}

extern "C" void* vorton_parse_float(void* s) {
    VortonStr* str = as_str(s);
    try {
        std::string tmp(str->buf, (size_t)str->len);
        size_t pos;
        double val = std::stod(tmp, &pos);
        if (pos == tmp.size()) {
            return vorton_enum_some(vorton_box_float(val));
        }
    } catch (const std::invalid_argument&) {
    } catch (const std::out_of_range&) {}
    return vorton_enum_none();
}

// ============================================================================
// List operations (additional)
// ============================================================================

extern "C" void* vorton_list_shift(void* list) {
    VortonList* l = as_list(list);
    int64_t ln = list_len(l);
    if (ln == 0) {
        return vorton_enum_none();
    }
    void* val = l->buf[0];
    if (ln > 1) memmove(l->buf, l->buf + 1, (size_t)(ln - 1) * sizeof(void*));
    l->buf[ln - 1] = nullptr;
    list_set_len(l, ln - 1);
    return vorton_enum_some(val);
}

extern "C" void* vorton_list_clear(void* list) {
    VortonList* l = as_list(list);
    int64_t ln = list_len(l);
    for (int64_t i = 0; i < ln; i++) {
        if (l->buf[i]) vorton_drop(l->buf[i]);
        l->buf[i] = nullptr;
    }
    list_set_len(l, 0);
    return list;
}

extern "C" void* vorton_list_extend(void* list, void* other) {
    VortonList* la = as_list(list);
    VortonList* lb = as_list(other);
    int64_t lb_len = list_len(lb);
    for (int64_t i = 0; i < lb_len; i++) {
        vorton_dup(lb->buf[i]);
        vorton_list_push_raw(list, lb->buf[i]);
    }
    return list;
}

// ============================================================================
// Miscellaneous
// ============================================================================

extern "C" void* vorton_assert(int64_t cond, void* msg) {
    if (!cond) {
        fprintf(stderr, "vorton assertion failed: %s\n", as_str(msg)->buf);
        fflush(stderr);
        exit(1);
    }
    return nullptr;
}

// ============================================================================
// Builtin primitive trait dictionaries (Eq for Str/Int/Float/Bool).
// The bootstrap LLVM backend does not emit Vorton impls for primitive Eq, so a
// generic `x == item` (which dispatches through an Eq dict) needs a real dict.
// Each dict is { eq_closure, ne_closure, null, null }; each closure is
// { fn_ptr, null_env }; the closure ABI is
// fn(env, a, b, effect_ctx) -> boxed value.
// ============================================================================

extern "C" void* vorton_cl_eq_str(void* env, void* a, void* b, EffectCtx* /*effect_ctx*/) { return vorton_box_bool(vorton_str_eq(a, b)); }
extern "C" void* vorton_cl_ne_str(void* env, void* a, void* b, EffectCtx* /*effect_ctx*/) { return vorton_box_bool(vorton_str_eq(a, b) ? 0 : 1); }
extern "C" void* vorton_cl_eq_int(void* env, void* a, void* b, EffectCtx* /*effect_ctx*/) { return vorton_box_bool((vorton_unbox_int(a) == vorton_unbox_int(b)) ? 1 : 0); }
extern "C" void* vorton_cl_ne_int(void* env, void* a, void* b, EffectCtx* /*effect_ctx*/) { return vorton_box_bool((vorton_unbox_int(a) == vorton_unbox_int(b)) ? 0 : 1); }
extern "C" void* vorton_cl_eq_float(void* env, void* a, void* b, EffectCtx* /*effect_ctx*/) { return vorton_box_bool((*(double*)a == *(double*)b) ? 1 : 0); }
extern "C" void* vorton_cl_ne_float(void* env, void* a, void* b, EffectCtx* /*effect_ctx*/) { return vorton_box_bool((*(double*)a == *(double*)b) ? 0 : 1); }
extern "C" void* vorton_cl_eq_bool(void* env, void* a, void* b, EffectCtx* /*effect_ctx*/) { return vorton_box_bool((vorton_unbox_bool(a) == vorton_unbox_bool(b)) ? 1 : 0); }
extern "C" void* vorton_cl_ne_bool(void* env, void* a, void* b, EffectCtx* /*effect_ctx*/) { return vorton_box_bool((vorton_unbox_bool(a) == vorton_unbox_bool(b)) ? 0 : 1); }
// Tag comparison for enum Eq dicts (correct for field-less enum variants, which
// is what the bootstrap compiler compares with `==`). Reads the leading i64 tag.
extern "C" void* vorton_cl_eq_tag(void* env, void* a, void* b, EffectCtx* /*effect_ctx*/) {
    if (!a || !b || ((uintptr_t)a & 1) || ((uintptr_t)b & 1))
        return vorton_box_bool((a == b) ? 1 : 0);
    return vorton_box_bool((*(int64_t*)a == *(int64_t*)b) ? 1 : 0);
}
extern "C" void* vorton_cl_ne_tag(void* env, void* a, void* b, EffectCtx* /*effect_ctx*/) {
    if (!a || !b || ((uintptr_t)a & 1) || ((uintptr_t)b & 1))
        return vorton_box_bool((a == b) ? 0 : 1);
    return vorton_box_bool((*(int64_t*)a == *(int64_t*)b) ? 0 : 1);
}

// Ord cmp closures: return a boxed Int in {-1, 0, 1}. The Ord trait has a single
// method `cmp` at dict slot 0; the LLVM backend lowers a generic `a < b` / `a > b`
// to load_dict_method(dict, 0) + compare the unboxed result against 0. The same
// closure ABI as Eq: fn(env, a, b, effect_ctx) -> boxed value.
extern "C" void* vorton_cl_cmp_int(void* env, void* a, void* b, EffectCtx* /*effect_ctx*/) {
    int64_t x = vorton_unbox_int(a), y = vorton_unbox_int(b);
    return vorton_box_int(x < y ? -1 : (x > y ? 1 : 0));
}
extern "C" void* vorton_cl_cmp_float(void* env, void* a, void* b, EffectCtx* /*effect_ctx*/) {
    double x = *(double*)a, y = *(double*)b;
    return vorton_box_int(x < y ? -1 : (x > y ? 1 : 0));
}
extern "C" void* vorton_cl_cmp_str(void* env, void* a, void* b, EffectCtx* /*effect_ctx*/) {
    VortonStr* x = as_str(a);
    VortonStr* y = as_str(b);
    int64_t min_len = x->len < y->len ? x->len : y->len;
    int cmp = (min_len > 0) ? memcmp(x->buf, y->buf, (size_t)min_len) : 0;
    if (cmp != 0) return vorton_box_int(cmp < 0 ? -1 : 1);
    return vorton_box_int(x->len < y->len ? -1 : (x->len > y->len ? 1 : 0));
}
extern "C" void* vorton_cl_cmp_bool(void* env, void* a, void* b, EffectCtx* /*effect_ctx*/) {
    int64_t x = vorton_unbox_bool(a), y = vorton_unbox_bool(b);
    return vorton_box_int(x < y ? -1 : (x > y ? 1 : 0));
}

static void* vorton_make_closure(void* fn) {
    void* data = vorton_alloc(2 * sizeof(void*), VORTON_TYPEID_CLOSURE);
    void** c = (void**)data;
    c[0] = fn; c[1] = nullptr;
    return data;
}
static void* vorton_make_eq_dict(void* eqfn, void* nefn) {
    // B-104 D4 dict layout: { int64 count, eq_closure, ne_closure, null, null }.
    // DICT_STATIC: builtin dicts are only synthesised from the codegen's
    // memoised singleton getters — one per dict name per program, never dropped.
    void* data = vorton_alloc(sizeof(int64_t) + 4 * sizeof(void*), VORTON_TYPEID_DICT_STATIC);
    *(int64_t*)data = 4;
    void** d = (void**)((char*)data + 8);
    d[0] = vorton_make_closure(eqfn);
    d[1] = vorton_make_closure(nefn);
    d[2] = nullptr; d[3] = nullptr;
    return data;
}
static void* vorton_make_ord_dict(void* cmpfn) {
    // Ord dict: single `cmp` closure at slot 0 (matching the trait's method
    // order).  Same count-prefixed DICT_STATIC layout as the Eq dict.
    void* data = vorton_alloc(sizeof(int64_t) + 4 * sizeof(void*), VORTON_TYPEID_DICT_STATIC);
    *(int64_t*)data = 4;
    void** d = (void**)((char*)data + 8);
    d[0] = vorton_make_closure(cmpfn);
    d[1] = nullptr; d[2] = nullptr; d[3] = nullptr;
    return data;
}

// #179: Debug trait closure functions — Debug has a single method `debug(val) -> Str`.
// Each closure takes (env, val, effect_ctx) where val is a boxed Vorton value,
// returns a boxed Str, and ignores the context because Debug is pure.
static void* vorton_Int_debug(void* /*env*/, void* val, EffectCtx* /*effect_ctx*/) {
    return vorton_int_to_str(vorton_unbox_int(val));
}
static void* vorton_Bool_debug(void* /*env*/, void* val, EffectCtx* /*effect_ctx*/) {
    return vorton_bool_to_str(vorton_unbox_bool(val));
}
static void* vorton_Float_debug(void* /*env*/, void* val, EffectCtx* /*effect_ctx*/) {
    return vorton_float_to_str(*(double*)val);
}
static void* vorton_Str_debug(void* /*env*/, void* val, EffectCtx* /*effect_ctx*/) {
    // Debug for Str: wrap in quotes and escape special characters
    VortonStr* s = as_str(val);
    std::string result = "\"";
    for (int64_t i = 0; i < s->len; i++) {
        char c = s->buf[i];
        switch (c) {
            case '"':  result += "\\\""; break;
            case '\\': result += "\\\\"; break;
            case '\n': result += "\\n"; break;
            case '\t': result += "\\t"; break;
            case '\r': result += "\\r"; break;
            default:   result += c; break;
        }
    }
    result += "\"";
    return make_vorton_str(result.c_str(), (int64_t)result.size());
}
extern "C" void* vorton_cl_debug_int(void* env, void* val, EffectCtx* effect_ctx) {
    return vorton_Int_debug(env, val, effect_ctx);
}
extern "C" void* vorton_cl_debug_float(void* env, void* val, EffectCtx* effect_ctx) {
    return vorton_Float_debug(env, val, effect_ctx);
}
extern "C" void* vorton_cl_debug_str(void* env, void* val, EffectCtx* effect_ctx) {
    return vorton_Str_debug(env, val, effect_ctx);
}
extern "C" void* vorton_cl_debug_bool(void* env, void* val, EffectCtx* effect_ctx) {
    return vorton_Bool_debug(env, val, effect_ctx);
}
static void* vorton_make_debug_dict(void* debugfn) {
    // Debug dict: single `debug` closure at slot 0.
    // Same count-prefixed DICT_STATIC layout as Eq/Ord dicts.
    void* data = vorton_alloc(sizeof(int64_t) + 4 * sizeof(void*), VORTON_TYPEID_DICT_STATIC);
    *(int64_t*)data = 4;
    void** d = (void**)((char*)data + 8);
    d[0] = vorton_make_closure(debugfn);
    d[1] = nullptr; d[2] = nullptr; d[3] = nullptr;
    return data;
}

// ============================================================================
// Hash trait closure functions — Hash has a single method `hash(val) -> Int`.
// Each closure takes (env, val, effect_ctx) where val is a boxed Vorton value,
// returns a boxed Int, and ignores the context because Hash is pure.
// ============================================================================

extern "C" int64_t vorton_hash_combine(int64_t h1, int64_t h2) {
    // Deterministic, order-sensitive FNV combine.  Unsigned arithmetic makes
    // overflow defined; the public Vorton Int result is boxed by generated code.
    uint64_t h = (uint64_t)h1;
    h ^= (uint64_t)h2;
    h *= 1099511628211ULL;
    return (int64_t)h;
}

static void* vorton_cl_hash_int(void* /*env*/, void* val, EffectCtx* /*effect_ctx*/) {
    uint64_t x = (uint64_t)vorton_unbox_int(val);
    // multiply-xorshift mixing (splitmix64 finalizer)
    x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ULL;
    x = (x ^ (x >> 27)) * 0x94d049bb133111ebULL;
    x = x ^ (x >> 31);
    return vorton_box_int((int64_t)x);
}

static void* vorton_cl_hash_str(void* /*env*/, void* val, EffectCtx* /*effect_ctx*/) {
    VortonStr* s = as_str(val);
    // FNV-1a 64-bit
    uint64_t h = 14695981039346656037ULL;
    for (int64_t i = 0; i < s->len; i++) {
        h ^= (uint8_t)s->buf[i];
        h *= 1099511628211ULL;
    }
    return vorton_box_int((int64_t)h);
}

static void* vorton_cl_hash_bool(void* /*env*/, void* val, EffectCtx* /*effect_ctx*/) {
    return vorton_box_int(vorton_unbox_int(val) ? 1LL : 0LL);
}
extern "C" void* vorton_cl_hash_int_export(void* env, void* val, EffectCtx* effect_ctx) {
    return vorton_cl_hash_int(env, val, effect_ctx);
}
extern "C" void* vorton_cl_hash_str_export(void* env, void* val, EffectCtx* effect_ctx) {
    return vorton_cl_hash_str(env, val, effect_ctx);
}
extern "C" void* vorton_cl_hash_bool_export(void* env, void* val, EffectCtx* effect_ctx) {
    return vorton_cl_hash_bool(env, val, effect_ctx);
}

static void* vorton_make_hash_dict(void* hashfn) {
    // Hash dict: single `hash` closure at slot 0.
    // Same count-prefixed DICT_STATIC layout as Eq/Ord/Debug dicts.
    void* data = vorton_alloc(sizeof(int64_t) + 4 * sizeof(void*), VORTON_TYPEID_DICT_STATIC);
    *(int64_t*)data = 4;
    void** d = (void**)((char*)data + 8);
    d[0] = vorton_make_closure(hashfn);
    d[1] = nullptr; d[2] = nullptr; d[3] = nullptr;
    return data;
}

// ============================================================================
// Perceus RC L0 — container drop functions
// ============================================================================

static void drop_list(void* data) {
    VortonList* l = as_list(data);
    int64_t ln = list_len(l);
    for (int64_t i = 0; i < ln; i++) {
        void* elem = l->buf[i];
        if (elem) vorton_drop(elem);
    }
    free(l->buf);
}

// B-152 P3: drop_map for new Vorton struct layout
static void drop_map(void* data) {
    VortonMapStruct* m = (VortonMapStruct*)data;
    int64_t cap = vorton_unbox_int(m->cap_tagged);
    uint8_t* meta = (uint8_t*)m->meta;
    for (int64_t i = 0; i < cap; i++) {
        if (meta[i] == 1) {
            vorton_drop(m->keys[i]);
            vorton_drop(m->values[i]);
        }
    }
    free(meta);
    free(m->keys);
    free(m->values);
}

static void drop_closure(void* data) {
    // VortonClosure = { fn_ptr: void*, env_ptr: void* }
    // fn_ptr is a function pointer, don't drop.
    // env_ptr if non-null is a vorton_alloc'd env struct, needs vorton_drop.
    // The env carries its own typeid (VORTON_TYPEID_CLOSURE_ENV for gen_lambda
    // closures → drop_closure_env; VORTON_TYPEID_CLOSURE for catch/handle envs,
    // which vorton_try leaks and never drops), so vorton_drop dispatches correctly.
    void** cls = (void**)data;
    if (cls[1]) {  // env_ptr
        vorton_drop(cls[1]);
    }
}

static void drop_closure_env(void* data) {
    // Closure env struct (B-084): { int64 count, void* cap0, void* cap1, ... }.
    // gen_lambda gives every general-purpose closure env this dedicated typeid
    // (NOT VORTON_TYPEID_CLOSURE, which drop_closure mis-reads as a {fn,env} pair).
    // Each captured slot holds an OWNED RC reference — Perceus emits a vorton_dup at
    // capture (non-last-use) or moves the sole owned ref in (last-use), so the
    // enclosing scope does not also drop it.  Releasing the env therefore drops
    // every slot exactly once: vorton_drop dispatches on each slot's own typeid, so
    // mut-cells (VORTON_TYPEID_CELL, B-091) and plain owned heap values are handled
    // uniformly and stay RC-balanced (no double-free, no leak).
    int64_t count = *(int64_t*)data;
    void** slots = (void**)((char*)data + 8);
    for (int64_t i = 0; i < count; i++) {
        if (slots[i]) vorton_drop(slots[i]);
    }
}

static void drop_option(void* data) {
    // Option = { tag: i64, payload: void* }
    // tag==0 => Some(payload), tag==1 => None
    int64_t tag = *(int64_t*)data;
    if (tag == 0) {
        void* payload = *(void**)((int64_t*)data + 1);
        if (payload) vorton_drop(payload);
    }
}

static void drop_tuple(void* data) {
    // Tuple/struct fields are contiguous void* pointers.
    // L0 simplification: tuple drop handled by codegen-generated per-type drop_T.
    // Runtime fallback is a no-op.
    (void)data;
}

static void drop_sb(void* data) {
    // StringBuilder is just a std::string underneath.
    ((std::string*)data)->~basic_string();
}

static void drop_dict(void* data) {
    // B-104 D4: dynamic wrapped dict { int64 count, void* method_closure0, ... }.
    // Each non-null slot is a VortonClosure whose env (CLOSURE_ENV, count =
    // inner_count) holds dup'd inner-dict references — dropping the closure
    // drops the env, which releases the inners (no-op for DICT_STATIC inners,
    // real release for dict-param-backed dynamic inners).  Same walk as
    // drop_closure_env.
    int64_t count = *(int64_t*)data;
    void** slots = (void**)((char*)data + 8);
    for (int64_t i = 0; i < count; i++) {
        if (slots[i]) vorton_drop(slots[i]);
    }
}

static void drop_evidence(void* data) {
    // B-096: evidence struct { int64 count, ptr slot0, ptr slot1, ... }.
    // Each non-null slot is a vorton_alloc'd VortonClosure {fn_ptr, env_ptr} with
    // typeid VORTON_TYPEID_CLOSURE.  vorton_drop on the closure drops its env
    // (CLOSURE_ENV), releasing captured variables.  Same walk as drop_dict /
    // drop_closure_env — count-prefixed, drop each non-null slot.
    int64_t count = *(int64_t*)data;
    void** slots = (void**)((char*)data + 8);
    for (int64_t i = 0; i < count; i++) {
        if (slots[i]) vorton_drop(slots[i]);
    }
}

static void drop_effect_ctx(void* data) {
    EffectCtx* ctx = (EffectCtx*)data;
    EffectCtxEntry* entries = effect_ctx_entries(ctx);
    for (int64_t i = 0; i < ctx->entry_count; i++) {
        if (entries[i].evidence) vorton_drop(entries[i].evidence);
    }
    if (ctx->parent) vorton_drop(ctx->parent);
}

extern "C" void* vorton_get_builtin_dict(void* name_ptr) {
    if (!name_ptr) return nullptr;
    VortonStr* rs = as_str(name_ptr);
    std::string n(rs->buf, (size_t)rs->len);

    // #194: Use suffix matching for trait names and segment matching for type
    // names to avoid false positives from user types (e.g. "OrdinaryThing",
    // "StringHelper").  Dict names follow the pattern __TypeName_TraitName,
    // so the trait is always the suffix and the type is a _-delimited segment.
    auto has_trait_suffix = [&](const char* trait) -> bool {
        size_t tlen = strlen(trait);
        // Matches "_Ord", "_Eq", "_Debug" at end of string.
        if (n.size() < tlen + 1) return false;
        return n[n.size() - tlen - 1] == '_' &&
               n.compare(n.size() - tlen, tlen, trait) == 0;
    };
    auto has_type_segment = [&](const char* type) -> bool {
        // Matches "_Int_", "_Str_", etc. as a _-delimited segment.
        std::string pat = std::string("_") + type + "_";
        return n.find(pat) != std::string::npos;
    };

    // Ord dicts (single `cmp` method). Check before Eq: an Ord dict name never
    // contains "Eq", but keeping it first keeps the intent explicit.
    if (has_trait_suffix("Ord")) {
        if (has_type_segment("Str"))   return vorton_make_ord_dict((void*)vorton_cl_cmp_str);
        if (has_type_segment("Float")) return vorton_make_ord_dict((void*)vorton_cl_cmp_float);
        if (has_type_segment("Int"))   return vorton_make_ord_dict((void*)vorton_cl_cmp_int);
        if (has_type_segment("Bool"))  return vorton_make_ord_dict((void*)vorton_cl_cmp_bool);
        fprintf(stderr, "vorton: no builtin Ord dict for '%s'\n", n.c_str());
        fflush(stderr);
        return nullptr;
    }
    // Eq dicts (eq/ne).
    if (has_trait_suffix("Eq")) {
        if (has_type_segment("Str"))   return vorton_make_eq_dict((void*)vorton_cl_eq_str,   (void*)vorton_cl_ne_str);
        if (has_type_segment("Float")) return vorton_make_eq_dict((void*)vorton_cl_eq_float, (void*)vorton_cl_ne_float);
        if (has_type_segment("Int"))   return vorton_make_eq_dict((void*)vorton_cl_eq_int,   (void*)vorton_cl_ne_int);
        if (has_type_segment("Bool"))  return vorton_make_eq_dict((void*)vorton_cl_eq_bool,  (void*)vorton_cl_ne_bool);
        // Any other Eq dict (user enums) → tag comparison.
        return vorton_make_eq_dict((void*)vorton_cl_eq_tag, (void*)vorton_cl_ne_tag);
    }
    // #179: Debug dicts (single `debug` method).
    if (has_trait_suffix("Debug")) {
        if (has_type_segment("Int"))   return vorton_make_debug_dict((void*)vorton_Int_debug);
        if (has_type_segment("Str"))   return vorton_make_debug_dict((void*)vorton_Str_debug);
        if (has_type_segment("Bool"))  return vorton_make_debug_dict((void*)vorton_Bool_debug);
        if (has_type_segment("Float")) return vorton_make_debug_dict((void*)vorton_Float_debug);
        fprintf(stderr, "vorton: no builtin Debug dict for '%s'\n", n.c_str());
        fflush(stderr);
        return nullptr;
    }
    // Hash dicts (single `hash` method).
    if (has_trait_suffix("Hash")) {
        if (has_type_segment("Str"))   return vorton_make_hash_dict((void*)vorton_cl_hash_str);
        if (has_type_segment("Int"))   return vorton_make_hash_dict((void*)vorton_cl_hash_int);
        if (has_type_segment("Bool"))  return vorton_make_hash_dict((void*)vorton_cl_hash_bool);
        fprintf(stderr, "vorton: no builtin Hash dict for '%s'\n", n.c_str());
        fflush(stderr);
        return nullptr;
    }
    fprintf(stderr, "vorton: no builtin dict for '%s'\n", n.c_str());
    fflush(stderr);
    return nullptr;
}

// ============================================================================
// List operations (join already defined as vorton_list_join)
// ============================================================================

extern "C" void* vorton_list_join(void* list, void* sep) {
    VortonList* l = as_list(list);
    int64_t ln = list_len(l);
    VortonStr* separator = as_str(sep);
    int64_t total = 0;
    for (int64_t i = 0; i < ln; i++) {
        if (i > 0) total += separator->len;
        total += as_str(l->buf[i])->len;
    }
    void* data = vorton_alloc(sizeof(VortonStr), VORTON_TYPEID_STR);
    VortonStr* rs = as_str(data);
    rs->len = total;
    rs->cap = total + 1;
    rs->buf = (char*)malloc((size_t)rs->cap);
    int64_t off = 0;
    for (int64_t i = 0; i < ln; i++) {
        if (i > 0 && separator->len > 0) {
            memcpy(rs->buf + off, separator->buf, (size_t)separator->len);
            off += separator->len;
        }
        VortonStr* elem = as_str(l->buf[i]);
        if (elem->len > 0) {
            memcpy(rs->buf + off, elem->buf, (size_t)elem->len);
            off += elem->len;
        }
    }
    rs->buf[total] = '\0';
    return data;
}

// ============================================================
// B-125: Raw memory primitives for Ptr<T>
// These allocate/free raw memory WITHOUT RC headers.
// Each "slot" is 8 bytes (uniform boxing: every Vorton value is void*).
// Int arguments arrive as tagged Vorton Ints and are untagged here.
// ============================================================

extern "C" void* vorton_raw_alloc(int64_t tagged_count) {
    int64_t count = tagged_count >> 1;  // untag Vorton Int
    void* p = malloc((size_t)count * 8);
    if (!p) {
        fprintf(stderr, "vorton_raw_alloc: out of memory (count=%lld)\n", (long long)count);
        exit(1);
    }
    memset(p, 0, (size_t)count * 8);
    return p;
}

extern "C" void vorton_raw_dealloc(void* ptr, int64_t tagged_count) {
    (void)tagged_count;  // count kept for API symmetry (sized-dealloc future)
    free(ptr);
}

extern "C" void vorton_ptr_copy(void* src, void* dst, int64_t tagged_count) {
    int64_t count = tagged_count >> 1;  // untag Vorton Int
    memmove(dst, src, (size_t)count * 8);
}
