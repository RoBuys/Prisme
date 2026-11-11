// Minimal decoder API over Microsoft's Xpress9 library (used by Power BI .pbix data models).
#ifndef PRISME_CXPRESS9_H
#define PRISME_CXPRESS9_H

#include <stdint.h>

typedef struct PrismeXpress9 PrismeXpress9;

/// Creates a decoder session (NULL on failure).
PrismeXpress9 *prisme_xpress9_create(void);

/// Decompresses one block; returns the number of bytes written to `out`, or -1 on error.
int prisme_xpress9_decompress(PrismeXpress9 *ctx, const uint8_t *in, int inSize, uint8_t *out, int outSize);

void prisme_xpress9_destroy(PrismeXpress9 *ctx);

#endif
