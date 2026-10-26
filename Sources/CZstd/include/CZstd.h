#include <stddef.h>
typedef struct CTZDecoder CTZDecoder;
CTZDecoder *ctz_create(void);
void ctz_destroy(CTZDecoder *decoder);
/* 0=more, 1=frame complete, -1=invalid, -2=resource/unsupported */
int ctz_step(CTZDecoder *decoder, const void *input, size_t size, size_t *consumed, void *output, size_t capacity, size_t *written);
