/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * hpjbig.c - open replacement for hp_encode_bits_to_jbig() from HP's
 * proprietary HPLIP "lj" plugin, built on JBIG-KIT.
 *
 * Interface (hpjbig_wrapper.h): Copyright (c) 1996 - 2007, HP Co. (BSD).
 * JBIG encoder: JBIG-KIT, Copyright 1995-2014 Markus Kuhn (GPL-2.0-or-later).
 *
 * hpcups (prnt/hpcups/ModeJbig.cpp) passes one band as a packed 1-bit
 * bitmap and expects a JBIG BIE back: the 20-byte BIH followed by the
 * stripe data. JBIG parameters match foo2zjs for the HP Pro (ZjStream)
 * class of printers: single layer, L0=128, MX=0, MY=0.
 */

#include <string.h>
#include "jbig.h"
#include "hpjbig_wrapper.h"

#define HPJBIG_ORDER   (JBG_ILEAVE | JBG_SMID)
#define HPJBIG_OPTIONS (JBG_DELAY_AT | JBG_LRLTWO | JBG_TPDON | JBG_TPBON | JBG_DPON)
#define HPJBIG_L0      128
#define HPJBIG_MX      0
#define HPJBIG_MY      0

typedef struct
{
    HPLJZjcBuff   *out;
    unsigned long  capacity;
    int            overflow;
} hpjbig_sink;

static void hpjbig_write(unsigned char *start, size_t len, void *file)
{
    hpjbig_sink *sink = (hpjbig_sink *) file;

    if (sink->overflow || sink->out->dwTotalSize + len > sink->capacity)
    {
        sink->overflow = 1;
        return;
    }
    memcpy(sink->out->pszCompressedData + sink->out->dwTotalSize, start, len);
    sink->out->dwTotalSize += len;
}

int hp_encode_bits_to_jbig(int iWidth, int iHeight, unsigned char **pBuff,
                           HPLJZjcBuff *pOutBuff, HPLJZjsJbgEncSt *pJbgEncSt)
{
    struct jbg_enc_state se;
    hpjbig_sink          sink;

    /* hpcups sizes the output buffer to the raw band, minus room it later
       uses to append *pJbgEncSt right after the compressed data. */
    sink.out      = pOutBuff;
    sink.capacity = (unsigned long) ((iWidth + 7) / 8) * iHeight - sizeof(*pJbgEncSt);
    sink.overflow = 0;

    jbg_enc_init(&se, iWidth, iHeight, 1, pBuff, hpjbig_write, &sink);
    jbg_enc_options(&se, HPJBIG_ORDER, HPJBIG_OPTIONS, HPJBIG_L0, HPJBIG_MX, HPJBIG_MY);
    jbg_enc_out(&se);
    jbg_enc_free(&se);

    memset(pJbgEncSt, 0, sizeof(*pJbgEncSt));
    pJbgEncSt->xd      = iWidth;
    pJbgEncSt->yd      = iHeight;
    pJbgEncSt->l0      = HPJBIG_L0;
    pJbgEncSt->mx      = HPJBIG_MX;
    pJbgEncSt->my      = HPJBIG_MY;
    pJbgEncSt->order   = HPJBIG_ORDER;
    pJbgEncSt->planes  = 1;
    pJbgEncSt->options = HPJBIG_OPTIONS;

    if (sink.overflow)
    {
        pOutBuff->dwTotalSize = 0;
        return -1;
    }
    return 0;
}
