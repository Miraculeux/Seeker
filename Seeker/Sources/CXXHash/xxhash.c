/*
 * Compilation unit for xxHash. The single-header xxhash.h provides both
 * the API declarations and the implementation when XXH_IMPLEMENTATION is
 * defined. We define it here in exactly one .c file so the symbols are
 * emitted once.
 */
#define XXH_IMPLEMENTATION
#define XXH_STATIC_LINKING_ONLY
#include "xxhash.h"
