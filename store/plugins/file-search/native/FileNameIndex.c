// Name finder (fold/NEON/sift_find) adapted from oil-find.
// Copyright (c) 2026 Lin Zhihuang. MIT; see THIRD_PARTY_NOTICES.md.
// Remaining index, scanning, persistence and ranking implementation: Nook contributors.
#include "FileNameIndex.h"
#include <CoreFoundation/CoreFoundation.h>
#include <sys/stat.h>
#include <sys/attr.h>
#include <dirent.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <math.h>
#include <stdatomic.h>
#if defined(__aarch64__)
#include <arm_neon.h>
#endif
static inline uint8_t fold(uint8_t x) { return (uint8_t)(x | (((uint8_t)(x - 'A') < 26) ? 0x20 : 0)); }
static inline int eq(uint8_t a, uint8_t b, int cs) { return cs ? a == b : fold(a) == b; }

#if defined(__aarch64__)
static inline uint8x16_t folded(uint8x16_t x, int cs) {
    if (cs) return x;
    uint8x16_t upper = vcltq_u8(vsubq_u8(x, vdupq_n_u8('A')), vdupq_n_u8(26));
    return vorrq_u8(x, vandq_u8(upper, vdupq_n_u8(0x20)));
}
static inline uint64_t mask16(uint8x16_t x) {
    uint8x8_t y = vshrn_n_u16(vreinterpretq_u16_u8(x), 4);
    return vget_lane_u64(vreinterpret_u64_u8(y), 0);
}
#endif
long sift_find(const uint8_t *hay, size_t len, size_t from, const uint8_t *needle, size_t nlen, int cs) {
    if (from > len) return -1;
    if (!nlen) return (long)from;
    if (nlen > len - from) return -1;
    size_t last = len - nlen, i = from;
#if defined(__aarch64__)
    uint8x16_t first = vdupq_n_u8(needle[0]), tail = vdupq_n_u8(needle[nlen-1]);
    while (i <= last && last - i >= 15) {
        uint8x16_t x = folded(vld1q_u8(hay + i), cs);
        uint8x16_t y = nlen == 1 ? x : folded(vld1q_u8(hay + i + nlen - 1), cs);
        uint64_t mask = mask16(vandq_u8(vceqq_u8(x, first), vceqq_u8(y, tail)));
        while (mask) {
            unsigned bit = (unsigned)__builtin_ctzll(mask);
            size_t p = i + bit / 4;
            size_t j = 1;
            for (; j + 1 < nlen && eq(hay[p+j], needle[j], cs); j++);
            if (j + 1 >= nlen) return (long)p;
            mask &= ~((uint64_t)15 << (bit & ~3u));
        }
        i += 16;
    }
#endif
    for (; i <= last; i++) {
        size_t j = 0;
        for (; j < nlen && eq(hay[i+j], needle[j], cs); j++);
        if (j == nlen) return (long)i;
    }
    return -1;
}

typedef struct {
    uint32_t path, name, folded, len;
    uint64_t mask;
    int64_t size;
    double modified, added, opened;
    uint32_t uses;
    uint8_t kind, hidden, live, pad;
    uint32_t extension;
} Entry;
struct NFIndex {
    _Atomic int cancelled;
    Entry *entries;
    char *blob, *names, *common_root;
    uint32_t *table;
    size_t count, capacity, bytes, blob_capacity, table_capacity, live, skipped;
    size_t name_bytes, name_capacity;
    uint64_t generation, identity;
};
typedef struct { char *text; size_t len; uint64_t mask; double number; int group, type, extensions; uint32_t hashes[32]; } Atom;
struct NFQuery { Atom atoms[64]; int count, groups; char *scope; uint32_t kinds; double now; };
struct NFCursor { uint32_t *ids; size_t count, capacity; uint64_t generation, identity; char *previous, *scope; uint32_t kinds; };
static _Atomic uint64_t next_identity=1;

static uint64_t hash(const char *s) {
    uint64_t h=1469598103934665603ULL;
    for(;*s;s++) h=(h^(uint8_t)*s)*1099511628211ULL;
    return h;
}
static int inside(const char *path,const char *root) {
    size_t n=strlen(root);
    return !n || (!strncmp(path,root,n) && (!path[n] || path[n]=='/' || (n==1 && root[0]=='/')));
}
static unsigned maskbit(uint8_t c) {
    c=fold(c);
    if(c>='a' && c<='z') return c-'a';
    if(c>='0' && c<='9') return 26+c-'0';
    return 36+c%28;
}
static uint64_t charmask(const char *s) {
    uint64_t m=0;
    for(;*s;s++) m|=1ULL<<maskbit((uint8_t)*s);
    return m;
}
static char *normalized(const char *s) {
    int ascii=1;
    for(const uint8_t *p=(const uint8_t *)s;*p;p++) if(*p>=128) { ascii=0; break; }
    if(ascii) { char *v=strdup(s); for(char *p=v;*p;p++) *p=(char)fold((uint8_t)*p); return v; }
    CFStringRef input=CFStringCreateWithCString(NULL,s,kCFStringEncodingUTF8);
    if(!input) return strdup(s);
    CFMutableStringRef v=CFStringCreateMutableCopy(NULL,0,input);
    CFStringFold(v,kCFCompareCaseInsensitive|kCFCompareDiacriticInsensitive,NULL);
    CFIndex cap=CFStringGetMaximumSizeForEncoding(CFStringGetLength(v),kCFStringEncodingUTF8)+1;
    char *out=calloc((size_t)cap,1);
    if(!CFStringGetCString(v,out,cap,kCFStringEncodingUTF8)) { free(out); out=strdup(s); }
    CFRelease(v); CFRelease(input); return out;
}
NFIndex *nf_create(void) { NFIndex *s=calloc(1,sizeof(NFIndex)); s->identity=atomic_fetch_add(&next_identity,1); return s; }
void nf_destroy(NFIndex *s) { if(s) { free(s->entries); free(s->blob); free(s->names); free(s->common_root); free(s->table); free(s); } }
size_t nf_count(const NFIndex *s) { return s?s->live:0; }
size_t nf_slots(const NFIndex *s) { return s?s->count:0; }
size_t nf_skipped(const NFIndex *s) { return s?s->skipped:0; }
size_t nf_memory(const NFIndex *s) { return s?sizeof(*s)+s->capacity*sizeof(Entry)+s->blob_capacity+s->name_capacity+s->table_capacity*4:0; }
uint64_t nf_generation(const NFIndex *s) { return s?s->generation:0; }
static void rehash(NFIndex *s,size_t cap) {
    free(s->table); s->table=calloc(cap,4); s->table_capacity=cap;
    for(size_t i=0;i<s->count;i++) {
        size_t p=hash(s->blob+s->entries[i].path)&(cap-1);
        while(s->table[p]) p=(p+1)&(cap-1);
        s->table[p]=(uint32_t)i+1;
    }
}
static uint32_t find(const NFIndex *s,const char *path) {
    if(!s->table_capacity) return UINT32_MAX;
    size_t p=hash(path)&(s->table_capacity-1);
    while(s->table[p]) {
        uint32_t id=s->table[p]-1;
        if(!strcmp(s->blob+s->entries[id].path,path)) return id;
        p=(p+1)&(s->table_capacity-1);
    }
    return UINT32_MAX;
}
static uint32_t append(char **blob,size_t *bytes,size_t *capacity,const char *text) {
    size_t n=strlen(text)+1;
    if(*bytes+n>UINT32_MAX) abort(); // A 4 GiB string table cannot be represented.
    if(*bytes+n>*capacity) {
        *capacity=*capacity?*capacity*2:65536;
        if(*capacity<*bytes+n) *capacity=*bytes+n;
        *blob=realloc(*blob,*capacity);
    }
    uint32_t offset=(uint32_t)*bytes;
    memcpy(*blob+offset,text,n); *bytes+=n; return offset;
}
static void common_root(NFIndex *s,const char *path) {
    if(!s->common_root) { s->common_root=strdup(path); return; }
    while(!inside(path,s->common_root)) {
        char *slash=strrchr(s->common_root,'/');
        if(!slash || slash==s->common_root) { s->common_root[0]='/'; s->common_root[1]=0; break; }
        *slash=0;
    }
}
void nf_put(NFIndex *s,const NFRecord *r) {
    uint32_t id=find(s,r->path);
    if(id==UINT32_MAX) {
        if(s->count==s->capacity) { s->capacity=s->capacity?s->capacity*2:1024; s->entries=realloc(s->entries,s->capacity*sizeof(Entry)); }
        id=(uint32_t)s->count++;
        Entry e={0}; e.path=append(&s->blob,&s->bytes,&s->blob_capacity,r->path);
        const char *name=strrchr(r->path,'/'); name=name?name+1:r->path;
        e.name=e.path+(uint32_t)(name-r->path);
        e.pad=1; for(const unsigned char *p=(const unsigned char *)name;*p;p++) if(*p>=128) { e.pad=0; break; }
        char *text=normalized(name); e.folded=append(&s->names,&s->name_bytes,&s->name_capacity,text); e.len=(uint32_t)strlen(text); e.mask=charmask(text); free(text);
        const char *ext=strrchr(s->names+e.folded,'.'); e.extension=ext?(uint32_t)hash(ext+1):0;
        common_root(s,r->path);
        s->entries[id]=e;
        if(s->count*2>=s->table_capacity) rehash(s,s->table_capacity?s->table_capacity*2:2048);
        else { size_t p=hash(r->path)&(s->table_capacity-1); while(s->table[p]) p=(p+1)&(s->table_capacity-1); s->table[p]=id+1; }
    }
    Entry *e=&s->entries[id];
    if(!e->live) s->live++;
    e->live=1; e->size=r->size; e->modified=r->modified; e->added=r->added;
    e->opened=fmax(e->opened,r->opened); e->uses=e->uses>r->uses?e->uses:r->uses;
    e->kind=r->kind; e->hidden=r->hidden; s->generation++;
}
int nf_record(const NFIndex *s,uint32_t id,NFRecord *r) {
    if(!s || id>=s->count || !s->entries[id].live) return 0;
    const Entry *e=&s->entries[id];
    *r=(NFRecord){s->blob+e->path,s->blob+e->name,e->size,e->modified,e->added,e->opened,e->uses,e->kind,e->hidden}; return 1;
}
void nf_remove(NFIndex *s,const char *path,int subtree) {
    if(!subtree) {
        uint32_t id=find(s,path);
        if(id!=UINT32_MAX && s->entries[id].live) { s->entries[id].live=0; s->live--; s->generation++; }
    } else for(size_t i=0;i<s->count;i++) if(s->entries[i].live && inside(s->blob+s->entries[i].path,path)) {
        s->entries[i].live=0; s->live--; s->generation++;
    }
}
void nf_merge(NFIndex *s,const NFIndex *other) {
    NFRecord r;
    for(size_t i=0;i<other->count;i++) if(nf_record(other,(uint32_t)i,&r)) nf_put(s,&r);
}
void nf_use(NFIndex *s,const char *path,double now) {
    uint32_t id=find(s,path);
    if(id!=UINT32_MAX) { Entry *e=&s->entries[id]; e->opened=now; if(e->uses<1000000) e->uses++; s->generation++; }
}
static int extension_in(const char *ext,const char *list) {
    size_t n=strlen(ext);
    if(!n) return 0;
    for(const char *p=list;*p;) { const char *end=strchr(p,';'); size_t len=end?(size_t)(end-p):strlen(p); if(len==n && !strncasecmp(p,ext,n)) return 1; if(!end) break; p=end+1; }
    return 0;
}
static uint8_t classify(const char *name,int dir) {
    const char *ext=strrchr(name,'.'); ext=ext?ext+1:"";
    if(dir) return !strcasecmp(ext,"app")?2:1;
    if(extension_in(ext,"png;jpg;jpeg;gif;heic;heif;tiff;tif;webp;svg;avif;bmp;ico;raw;dng;psd")) return 3;
    if(!strcasecmp(ext,"pdf")) return 4;
    if(extension_in(ext,"swift;m;mm;h;c;cc;cpp;hpp;cs;go;rs;py;pyi;rb;php;java;kt;kts;js;mjs;cjs;ts;tsx;jsx;html;htm;css;scss;sass;less;json;yaml;yml;toml;xml;sh;zsh;bash;fish;sql;vue;svelte;lua;pl;r;dart")) return 5;
    if(extension_in(ext,"mov;mp4;m4v;avi;mkv;webm;mpeg;mpg;3gp")) return 6;
    if(extension_in(ext,"mp3;m4a;wav;flac;aiff;aif;ogg;opus;aac")) return 7;
    if(extension_in(ext,"zip;tar;gz;bz2;xz;7z;rar;dmg;iso;pkg;zst")) return 8;
    return 0;
}
static int package(const char *name) {
    const char *ext=strrchr(name,'.');
    return ext && extension_in(ext+1,"app;bundle;framework;plugin;appex;photoslibrary;photolibrary;xcassets;xcodeproj;xcworkspace;playground;pages;numbers;key;rtfd;sparsebundle;band;logicx;garageband");
}
static int excluded(const char *path,const char *list) {
    for(const char *p=list;*p;) { const char *end=strchr(p,'\n'); size_t n=end?(size_t)(end-p):strlen(p);
        if(n && !strncmp(path,p,n) && (!path[n] || path[n]=='/')) return 1;
        if(!end) break; p=end+1;
    } return 0;
}
typedef struct { const char *excluded,*root; int hidden,library,dependencies,packages; } Config;
static void scan(NFIndex *s,const char *path,const Config *c,int depth,int inherited_hidden,int parent_fd,const char *leaf,dev_t root_device) {
    if(depth>256 || excluded(path,c->excluded)) return;
    const char *name=strrchr(path,'/'); name=name?name+1:path;
    struct stat st;
    if(fstatat(parent_fd,leaf,&st,AT_SYMLINK_NOFOLLOW)!=0) { s->skipped++; return; }
    // Do not cross a mount inserted while a walk is in flight. Mount-table
    // exclusions are applied before stat; this is a second, race-safe boundary.
    if(depth && st.st_dev!=root_device) return;
    if(!depth) root_device=st.st_dev;
    int hidden=inherited_hidden || name[0]=='.' || (st.st_flags&UF_HIDDEN)!=0;
    if(hidden && !c->hidden) return;
    int dir=S_ISDIR(st.st_mode);
    if(dir && extension_in(name,".Trash;.Trashes;.Spotlight-V100;.fseventsd;.DocumentRevisions-V100;.TemporaryItems")) return;
    if(dir && !c->dependencies && extension_in(name,"node_modules;.git;DerivedData;build;.build;dist;.next;.nuxt;Pods;venv;.venv;site-packages;__pycache__;.cache;Caches;.npm;.pnpm-store;.yarn;.gradle;.cargo;.rustup;.swiftpm")) return;
    if(dir && !c->library && !strcmp(name,"Library") && depth==1) return;
    if(!S_ISREG(st.st_mode) && !dir && !S_ISLNK(st.st_mode)) return;
    double added=(double)st.st_birthtimespec.tv_sec+(double)st.st_birthtimespec.tv_nsec/1e9;
    struct attrlist attrs={0}; attrs.bitmapcount=ATTR_BIT_MAP_COUNT; attrs.commonattr=ATTR_CMN_ADDEDTIME;
    struct __attribute__((packed)) { uint32_t length; struct timespec date; } buffer;
    if(getattrlistat(parent_fd,leaf,&attrs,&buffer,sizeof(buffer),FSOPT_NOFOLLOW)==0 && buffer.date.tv_sec>0)
        added=(double)buffer.date.tv_sec+(double)buffer.date.tv_nsec/1e9;
    NFRecord r={path,name,st.st_size,(double)st.st_mtimespec.tv_sec+(double)st.st_mtimespec.tv_nsec/1e9,added,0,0,classify(name,dir),(uint8_t)(hidden!=0)};
    nf_put(s,&r);
    if(!dir || (!c->packages && package(name))) return;
    int fd=openat(parent_fd,leaf,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(fd<0) { s->skipped++; return; }
    DIR *d=fdopendir(fd);
    if(!d) { close(fd); s->skipped++; return; }
    struct dirent *entry;
    while(!atomic_load(&s->cancelled) && (entry=readdir(d))) {
        if(!strcmp(entry->d_name,".") || !strcmp(entry->d_name,"..")) continue;
        char child[4096]; int n=snprintf(child,sizeof(child),"%s/%s",path,entry->d_name);
        if(n>0 && (size_t)n<sizeof(child)) scan(s,child,c,depth+1,hidden,dirfd(d),entry->d_name,root_device);
    }
    closedir(d);
}
void nf_cancel(NFIndex *s) { if(s) atomic_store(&s->cancelled,1); }
void nf_scan(NFIndex *s,const char *root,const char *exclusions,int hidden,int library,int dependencies,int packages) {
    if(atomic_load(&s->cancelled)) return;
    Config c={exclusions,root,hidden,library,dependencies,packages}; scan(s,root,&c,0,0,AT_FDCWD,root,0);
}

NFQuery *nf_query_create(const char *scope,uint32_t kinds,double now) {
    NFQuery *q=calloc(1,sizeof(*q)); q->scope=strdup(scope); q->kinds=kinds; q->now=now; q->groups=1; return q;
}
void nf_query_add(NFQuery *q,int group,int type,const char *value,double number) {
    if(q->count>=64) return;
    Atom *a=&q->atoms[q->count++]; a->text=(type&15)==2?strdup(value):normalized(value); a->len=strlen(a->text); a->mask=charmask(a->text); a->number=number; a->group=group; a->type=type;
    // The common *.ext query is an exact extension test, not a per-name glob walk.
    const char *extensions=NULL;
    if((type&15)==3) extensions=a->text;
    if((type&15)==1 && !strncmp(a->text,"*.",2) && !strpbrk(a->text+2,"*?")) { extensions=a->text+2; a->type=3|(type&16); }
    if(extensions) {
        char *copy=strdup(extensions),*state=NULL,*part=strtok_r(copy,";",&state);
        while(part && a->extensions<32) { a->hashes[a->extensions++]=(uint32_t)hash(part); part=strtok_r(NULL,";",&state); }
        free(copy);
    }
    if((a->type&15)==1) { a->mask=0; for(const char *p=a->text;*p;p++) if(*p!='*' && *p!='?') a->mask|=1ULL<<maskbit((uint8_t)*p); }
    if(group+1>q->groups) q->groups=group+1;
}
void nf_query_destroy(NFQuery *q) { if(q) { for(int i=0;i<q->count;i++) free(q->atoms[i].text); free(q->scope); free(q); } }
NFCursor *nf_cursor_create(void) { return calloc(1,sizeof(NFCursor)); }
void nf_cursor_destroy(NFCursor *c) { if(c) { free(c->ids); free(c->previous); free(c->scope); free(c); } }
static int glob(const char *s,const char *p) {
    const char *star=NULL,*retry=NULL;
    while(*s) {
        if(*p=='?') { s++; while(((uint8_t)*s&0xc0)==0x80) s++; p++; }
        else if(*p==*s) { s++; p++; }
        else if(*p=='*') { star=p++; retry=s; }
        else if(star) { p=star+1; retry++; while(((uint8_t)*retry&0xc0)==0x80) retry++; s=retry; }
        else return 0;
    }
    while(*p=='*') p++;
    return !*p;
}
static int quality(const Entry *e,const char *name,const char *original,const Atom *a) {
    if(!a->len) return 1;
    if((e->mask&a->mask)!=a->mask || a->len>e->len) return 0;
    long pos=sift_find((const uint8_t *)name,e->len,0,(const uint8_t *)a->text,a->len,1);
    if(pos==0) return e->len==a->len || (name[a->len]=='.' && !strchr(name+a->len+1,'.'))?5:4;
    if(pos>0) {
        do {
            char prev=name[pos-1];
            if(!((prev>='a' && prev<='z') || (prev>='0' && prev<='9') || (uint8_t)prev>=128)) return 3;
            if(original && original[pos-1]>='a' && original[pos-1]<='z' && original[pos]>='A' && original[pos]<='Z') return 3;
            if((prev>='0' && prev<='9' && name[pos]>='a' && name[pos]<='z') || (name[pos]>='0' && name[pos]<='9' && prev>='a' && prev<='z')) return 3;
            pos=sift_find((const uint8_t *)name,e->len,(size_t)pos+1,(const uint8_t *)a->text,a->len,1);
        } while(pos>=0);
        return 2;
    }
    const char *p=a->text;
    for(const char *n=name;*n && *p;n++) if(*p==*n) p++;
    return !*p?1:0;
}
static int atom(const NFIndex *s,const Entry *e,const Atom *a) {
    const char *name=s->names+e->folded; int match=0;
    switch(a->type&15) {
        case 0: match=quality(e,name,e->pad?s->blob+e->name:NULL,a); break;
        case 1: match=(e->mask&a->mask)==a->mask && glob(name,a->text)?4:0; break;
        case 2: match=inside(s->blob+e->path,a->text); break;
        case 3: for(int i=0;i<a->extensions;i++) if(e->extension==a->hashes[i]) {
            const char *ext=strrchr(name,'.'),*list=!strncmp(a->text,"*.",2)?a->text+2:a->text;
            match=ext && extension_in(ext+1,list); break;
        } break;
        case 4: match=(e->kind<9 && ((uint32_t)a->number&(1u<<e->kind)))!=0; break;
        case 5: match=a->number==1?e->kind==1:e->kind!=1; break;
        case 6: match=(double)e->size>a->number; break;
        case 7: match=(double)e->size<a->number; break;
        case 8: match=e->modified>=a->number; break;
        case 9: match=e->modified<a->number; break;
        case 10: match=e->added>=a->number; break;
        case 11: match=e->added<a->number; break;
    }
    return a->type&16?!match:match;
}
static int match(const NFIndex *s,const Entry *e,const NFQuery *q) {
    int best=0;
    for(int group=0;group<q->groups;group++) {
        int tier=5,ok=1;
        for(int j=0;j<q->count;j++) {
            const Atom *a=&q->atoms[j]; if(a->group!=group) continue;
            int value=atom(s,e,a); if(!value) { ok=0; break; }
            if(a->type==0 || a->type==1) if(value<tier) tier=value;
        }
        if(ok && tier>best) best=tier;
    }
    return best;
}
static int better(NFHit a,NFHit b) { return a.tier>b.tier || (a.tier==b.tier && (a.score>b.score || (a.score==b.score && a.id<b.id))); }
static void heap(NFHit *out,size_t n,size_t p) {
    for(;;) {
        size_t left=p*2+1; if(left>=n) break;
        size_t child=left;
        if(left+1<n && better(out[left],out[left+1])) child=left+1;
        if(!better(out[p],out[child])) break;
        NFHit tmp=out[p]; out[p]=out[child]; out[child]=tmp; p=child;
    }
}
static int hit_compare(const void *a,const void *b) { NFHit x=*(const NFHit *)a,y=*(const NFHit *)b; return better(x,y)?-1:better(y,x)?1:0; }
size_t nf_search(const NFIndex *s,const NFQuery *q,NFCursor *c,NFHit *out,size_t limit,size_t *total) {
    if(!s || !limit) { *total=0; return 0; }
    int simple=q->count==1 && q->atoms[0].type==0;
    int narrow=simple && c && c->previous && c->identity==s->identity && c->generation==s->generation && c->kinds==q->kinds && !strcmp(c->scope,q->scope) && !strncmp(q->atoms[0].text,c->previous,strlen(c->previous));
    size_t scanned=narrow?c->count:s->count, hits=0, count=0;
    int scoped=*q->scope && (!s->common_root || !inside(s->common_root,q->scope));
    if(simple && c && c->capacity<scanned) { c->capacity=scanned; c->ids=realloc(c->ids,scanned*4); }
    for(size_t i=0;i<scanned;i++) {
        uint32_t id=narrow?c->ids[i]:(uint32_t)i; const Entry *e=&s->entries[id];
        if(!e->live || !(q->kinds&(1u<<e->kind)) || (scoped && !inside(s->blob+e->path,q->scope))) continue;
        if(!q->count && q->kinds==511 && e->kind==1) continue; // Recent defaults to files; Folder remains an explicit filter.
        // Keep the overwhelmingly common one-name query's rejection in the scan
        // loop. Adding richer word-boundary policy must not introduce one million
        // out-of-line matcher calls for names missing a required character.
        int tier;
        if(simple) {
            const Atom *a=&q->atoms[0];
            if((e->mask&a->mask)!=a->mask || a->len>e->len) continue;
            tier=quality(e,s->names+e->folded,e->pad?s->blob+e->name:NULL,a);
        } else tier=match(s,e,q);
        if(!tier) continue;
        if(simple && c) c->ids[hits]=id;
        hits++;
        double recent=fmax(e->added,e->modified);
        if(q->count && e->uses) {
            double days=fmax(0,q->now-e->opened)/86400;
            recent=fmax(recent,e->opened)+fmin(7*86400,log2(e->uses+1)*86400)/(1+days/7);
        }
        NFHit h={id,q->count?(uint32_t)tier:0,recent};
        if(count<limit) {
            size_t p=count++; out[p]=h;
            while(p) { size_t parent=(p-1)/2; if(!better(out[parent],out[p])) break; NFHit t=out[parent];out[parent]=out[p];out[p]=t;p=parent; }
        } else if(better(h,out[0])) { out[0]=h; heap(out,count,0); }
    }
    if(c) {
        free(c->previous); free(c->scope); c->previous=simple?strdup(q->atoms[0].text):NULL;
        c->scope=strdup(q->scope); c->kinds=q->kinds; c->count=hits; c->generation=s->generation; c->identity=s->identity;
    }
    qsort(out,count,sizeof(NFHit),hit_compare); *total=hits; return count;
}

typedef struct { uint64_t magic,version,count,bytes,event,fingerprint,checksum,skipped,names; } Header;
static uint64_t checksum(const void *bytes,size_t n,uint64_t value) {
    const unsigned char *p=bytes; for(size_t i=0;i<n;i++) value=(value^p[i])*1099511628211ULL; return value;
}
int nf_save(const NFIndex *s,const char *path,uint64_t event,uint64_t fingerprint) {
    char temp[4096]; if(snprintf(temp,sizeof(temp),"%s.tmp.%d",path,getpid())>=(int)sizeof(temp)) return 0;
    int fd=open(temp,O_WRONLY|O_CREAT|O_TRUNC|O_CLOEXEC|O_NOFOLLOW,0600); if(fd<0) return 0;
    FILE *f=fdopen(fd,"wb"); if(!f) { close(fd); return 0; }
    uint64_t sum=checksum(s->entries,s->count*sizeof(Entry),1469598103934665603ULL); sum=checksum(s->blob,s->bytes,sum);
    sum=checksum(s->names,s->name_bytes,sum);
    Header h={0x584449464b4f4f4eULL,4,s->count,s->bytes,event,fingerprint,sum,s->skipped,s->name_bytes};
    int ok=fwrite(&h,sizeof(h),1,f)==1 && fwrite(s->entries,sizeof(Entry),s->count,f)==s->count && fwrite(s->blob,1,s->bytes,f)==s->bytes && fwrite(s->names,1,s->name_bytes,f)==s->name_bytes;
    if(fflush(f) || fsync(fd)) ok=0;
    if(fclose(f)) ok=0;
    if(ok) ok=rename(temp,path)==0;
    if(!ok) unlink(temp); // Only our own cache temporary file.
    return ok;
}
NFIndex *nf_load(const char *path,uint64_t fingerprint,uint64_t *event) {
    FILE *f=fopen(path,"rb"); if(!f) return NULL;
    Header h; struct stat st;
    int ok=fstat(fileno(f),&st)==0 && fread(&h,sizeof(h),1,f)==1 && h.magic==0x584449464b4f4f4eULL && h.version==4 && h.fingerprint==fingerprint && h.count<=20000000 && h.bytes<=UINT32_MAX && h.names<=UINT32_MAX && (uint64_t)st.st_size==sizeof(h)+h.count*sizeof(Entry)+h.bytes+h.names;
    if(!ok) { fclose(f); return NULL; }
    NFIndex *s=nf_create(); s->count=s->capacity=(size_t)h.count; s->bytes=s->blob_capacity=(size_t)h.bytes;
    s->skipped=(size_t)h.skipped;
    s->name_bytes=s->name_capacity=(size_t)h.names;
    s->entries=malloc(s->count*sizeof(Entry)); s->blob=malloc(s->bytes); s->names=malloc(s->name_bytes);
    ok=fread(s->entries,sizeof(Entry),s->count,f)==s->count && fread(s->blob,1,s->bytes,f)==s->bytes && fread(s->names,1,s->name_bytes,f)==s->name_bytes; fclose(f);
    uint64_t sum=checksum(s->entries,s->count*sizeof(Entry),1469598103934665603ULL); sum=checksum(s->blob,s->bytes,sum);
    sum=checksum(s->names,s->name_bytes,sum);
    ok=ok && sum==h.checksum;
    for(size_t i=0;ok && i<s->count;i++) {
        Entry *e=&s->entries[i];
        ok=e->path<s->bytes && e->name>=e->path && e->name<s->bytes && e->folded<s->name_bytes && e->len<s->name_bytes-e->folded && e->kind<9 && e->live<=1;
        if(ok) ok=memchr(s->blob+e->path,0,s->bytes-e->path)!=NULL && s->names[e->folded+e->len]==0;
        if(ok) common_root(s,s->blob+e->path);
        if(e->live) s->live++;
    }
    if(!ok) { nf_destroy(s); return NULL; }
    size_t cap=2048; while(cap<s->count*2) cap*=2; rehash(s,cap); s->generation=1; *event=h.event; return s;
}
