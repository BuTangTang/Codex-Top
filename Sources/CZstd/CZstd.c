#include "CZstd.h"
#define ZSTD_STATIC_LINKING_ONLY
#include "vendor/lib/zstd.h"
#include "vendor/lib/zstd_errors.h"
#include <stdlib.h>
#include <stdint.h>
struct CTZDecoder { ZSTD_DStream *stream; size_t allocated; };
typedef union { max_align_t alignment; size_t size; } Allocation;
/* 为解码器所有分配保留独立上限，拒绝异常帧触发的大分配。 */
static void *bounded_alloc(void *opaque, size_t size) {
    CTZDecoder *d = opaque;
    if (size > 16*1024*1024 - d->allocated || size > SIZE_MAX-sizeof(Allocation)) return NULL;
    Allocation *p = malloc(sizeof(Allocation)+size);
    if (!p) return NULL;
    p->size=size; d->allocated+=size; return p+1;
}
/* 释放时回收预算，流上下文由调用方串行持有。 */
static void bounded_free(void *opaque, void *ptr) {
    if (!ptr) return;
    Allocation *p=(Allocation *)ptr-1;
    ((CTZDecoder *)opaque)->allocated-=p->size; free(p);
}
/* 初始化流式解码，并限制最大窗口为 8 MiB。 */
CTZDecoder *ctz_create(void) {
    CTZDecoder *d=calloc(1,sizeof(*d)); if (!d) return NULL;
    ZSTD_customMem memory={bounded_alloc,bounded_free,d};
    d->stream=ZSTD_createDStream_advanced(memory);
    if (!d->stream) { free(d); return NULL; }
    if (ZSTD_isError(ZSTD_DCtx_setParameter(d->stream,ZSTD_d_windowLogMax,23))) { ctz_destroy(d); return NULL; }
    return d;
}
/* 销毁上下文，不保留解压后的历史记录。 */
void ctz_destroy(CTZDecoder *d) { if (d) { ZSTD_freeDStream(d->stream); free(d); } }
/* 单次最多填满调用方有界输出缓冲，返回明确的错误分类。 */
int ctz_step(CTZDecoder *d,const void *input,size_t size,size_t *consumed,void *output,size_t capacity,size_t *written) {
    ZSTD_inBuffer in={input,size,0}; ZSTD_outBuffer out={output,capacity,0};
    size_t result=ZSTD_decompressStream(d->stream,&out,&in);
    *consumed=in.pos; *written=out.pos;
    if (ZSTD_isError(result)) {
        ZSTD_ErrorCode e=ZSTD_getErrorCode(result);
        return (e==ZSTD_error_frameParameter_windowTooLarge || e==ZSTD_error_memory_allocation || e==ZSTD_error_dictionary_wrong || e==ZSTD_error_dictionary_corrupted) ? -2 : -1;
    }
    return result==0 ? 1 : 0;
}
