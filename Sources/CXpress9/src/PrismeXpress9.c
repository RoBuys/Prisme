// Thin decoder wrapper for Prisme, modeled on Xpress9Wrapper.c from xpress9-python (MIT, Igor Cotruta).
#include "CXpress9.h"
#include "xpress9.h"
#include <stdlib.h>

struct PrismeXpress9 {
    XPRESS9_DECODER decoder;
};

static void *XPRESS9_CALL prisme_alloc(void *context, int size) { (void)context; return malloc((size_t)size); }
static void XPRESS9_CALL prisme_free(void *context, void *address) { (void)context; free(address); }

PrismeXpress9 *prisme_xpress9_create(void) {
    XPRESS9_STATUS status = {0};
    PrismeXpress9 *ctx = (PrismeXpress9 *)calloc(1, sizeof(PrismeXpress9));
    if (!ctx) return NULL;
    ctx->decoder = Xpress9DecoderCreate(&status, NULL, prisme_alloc, XPRESS9_WINDOW_SIZE_LOG2_MAX, 0);
    if (ctx->decoder == NULL || status.m_uStatus != Xpress9Status_OK) { free(ctx); return NULL; }
    Xpress9DecoderStartSession(&status, ctx->decoder, 1);
    if (status.m_uStatus != Xpress9Status_OK) { prisme_xpress9_destroy(ctx); return NULL; }
    return ctx;
}

int prisme_xpress9_decompress(PrismeXpress9 *ctx, const uint8_t *in, int inSize, uint8_t *out, int outSize) {
    if (!ctx || !ctx->decoder || inSize <= 0 || outSize <= 0) return -1;
    XPRESS9_STATUS status = {0};
    Xpress9DecoderAttach(&status, ctx->decoder, in, (unsigned)inSize);
    if (status.m_uStatus != Xpress9Status_OK) return -1;
    int written = 0;
    unsigned remaining;
    do {
        unsigned w = 0, needed = 0;
        remaining = Xpress9DecoderFetchDecompressedData(&status, ctx->decoder, out + written,
                                                       (unsigned)(outSize - written), &w, &needed);
        if (status.m_uStatus != Xpress9Status_OK) { written = -1; break; }
        if (w == 0) break;
        written += (int)w;
    } while (remaining != 0 && written < outSize);
    XPRESS9_STATUS detachStatus = {0};
    Xpress9DecoderDetach(&detachStatus, ctx->decoder, in, (unsigned)inSize);
    return written;
}

void prisme_xpress9_destroy(PrismeXpress9 *ctx) {
    if (!ctx) return;
    if (ctx->decoder) {
        XPRESS9_STATUS status = {0};
        Xpress9DecoderDestroy(&status, ctx->decoder, NULL, prisme_free);
    }
    free(ctx);
}
