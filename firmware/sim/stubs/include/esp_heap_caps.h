#pragma once
#include <stdlib.h>
#define MALLOC_CAP_SPIRAM 1
#define MALLOC_CAP_INTERNAL 2
#define MALLOC_CAP_DMA 4
#define heap_caps_malloc(n, caps) malloc(n)
#define heap_caps_calloc(c, n, caps) calloc(c, n)
#define heap_caps_free(p) free(p)
static inline unsigned heap_caps_get_free_size(unsigned caps) { (void)caps; return 1u << 20; }
static inline unsigned heap_caps_get_largest_free_block(unsigned caps) { (void)caps; return 1u << 19; }
static inline unsigned heap_caps_get_minimum_free_size(unsigned caps) { (void)caps; return 1u << 20; }
