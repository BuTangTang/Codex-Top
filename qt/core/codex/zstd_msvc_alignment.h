#pragma once
#include <stddef.h>

// MSVC 的 C 运行库没有定义 max_align_t。堆分配在 64 位 Windows 上按 16 字节、
// 32 位 Windows 上按 8 字节对齐。让原生解码器的计数前缀恰占一个完整对齐单元。
#ifdef _WIN64
#define CODEXTOP_HEAP_ALIGNMENT 16
#else
#define CODEXTOP_HEAP_ALIGNMENT 8
#endif
typedef struct __declspec(align(CODEXTOP_HEAP_ALIGNMENT)) {
    unsigned char bytes[CODEXTOP_HEAP_ALIGNMENT];
} CodexTopHeapAlignment;
_Static_assert(sizeof(CodexTopHeapAlignment) == CODEXTOP_HEAP_ALIGNMENT, "allocation prefix must preserve alignment");
#define max_align_t CodexTopHeapAlignment
