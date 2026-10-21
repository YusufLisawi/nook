#pragma once
#include <stdint.h>
#include <stddef.h>

typedef struct NFIndex NFIndex;
typedef struct NFQuery NFQuery;
typedef struct NFCursor NFCursor;
typedef struct {
    uint32_t id, tier;
    double score;
} NFHit;
typedef struct {
    const char *path, *name;
    int64_t size;
    double modified, added, opened;
    uint32_t uses;
    uint8_t kind, hidden;
} NFRecord;
// kind: file/document 0, folder 1, app 2, image 3, pdf 4, code 5, video 6, audio 7, archive 8
NFIndex *nf_create(void);
void nf_destroy(NFIndex *index);
size_t nf_count(const NFIndex *index);
size_t nf_slots(const NFIndex *index);
size_t nf_memory(const NFIndex *index);
size_t nf_skipped(const NFIndex *index);
uint64_t nf_generation(const NFIndex *index);
void nf_put(NFIndex *index, const NFRecord *record);
int nf_record(const NFIndex *index, uint32_t id, NFRecord *out);
void nf_remove(NFIndex *index, const char *path, int subtree);
void nf_merge(NFIndex *index, const NFIndex *other);
void nf_use(NFIndex *index, const char *path, double now);
// Read-only scan. Exclusions are newline-delimited absolute paths. Never follows symlinks.
void nf_cancel(NFIndex *index);
void nf_scan(NFIndex *index, const char *root, const char *exclusions, int hidden, int library, int dependencies, int packages);
int nf_save(const NFIndex *index, const char *path, uint64_t event, uint64_t fingerprint);
NFIndex *nf_load(const char *path, uint64_t fingerprint, uint64_t *event);
NFQuery *nf_query_create(const char *scope, uint32_t kind_mask, double now);
// OR groups of AND atoms. Types: name 0, glob 1, path 2, ext 3, kind 4, file/folder 5,
// size > 6 / < 7, modified >= 8 / < 9, added >= 10 / < 11. Negation: type | 16.
void nf_query_add(NFQuery *query, int group, int type, const char *value, double number);
void nf_query_destroy(NFQuery *query);
NFCursor *nf_cursor_create(void);
void nf_cursor_destroy(NFCursor *cursor);
size_t nf_search(const NFIndex *index, const NFQuery *query, NFCursor *cursor, NFHit *hits, size_t limit, size_t *total);
