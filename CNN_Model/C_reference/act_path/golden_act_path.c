
/*
 * golden_act_path.c
 *
 * Functional golden reference for:
 *
 *   RAM -> act_ld_unit -> input_buf
 *       -> act_patch_gen / fc_gen -> MUX -> act_feeder -> act_skew
 *
 * This model is transaction/step-level, not cycle-exact.
 * It checks data order, padding, 24-bit packing, patch order,
 * row mask behavior, FC addressing, and skew distribution.
 *
 * Build:
 *   gcc -std=c11 -O2 -Wall -Wextra -o golden_act_path golden_act_path.c
 *
 * Run:
 *   ./golden_act_path
 *   ./golden_act_path -b golden_act_path
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define IBUF_WORDS 16384
#define MAX_K      4096

typedef struct {
    uint32_t mem[IBUF_WORDS];
} input_buf_t;

typedef struct {
    uint32_t mem[2][32];
    int valid[2];
    int tag[2];
    int capture_count;

    int src_base;
    int in_w;
    int in_h;
    int in_c;
    int pad_en;
    int words_per_pixel;
    int wpr;
} patch_gen_t;

typedef struct {
    uint8_t row2_d1;
    uint8_t row3_d1;
    uint8_t row3_d2;
} act_skew_t;

static FILE *g_out;
static int g_error_count;

static uint32_t pack3(uint8_t lane1, uint8_t lane2, uint8_t lane3)
{
    return ((uint32_t)lane3 << 16) |
           ((uint32_t)lane2 << 8)  |
           (uint32_t)lane1;
}

static uint8_t lane8(uint32_t word, int lane)
{
    return (uint8_t)((word >> (8 * lane)) & 0xFFu);
}

static void print_word(FILE *f, uint32_t word)
{
    fprintf(f, "0x%06X", (unsigned)(word & 0xFFFFFFu));
}

/* ------------------------------------------------------------------------- */
/* act_skew                                                                  */
/* Row1: no delay, Row2: 1 step, Row3: 2 steps                              */
/* ------------------------------------------------------------------------- */
static uint32_t act_skew_step(act_skew_t *s, uint32_t feed_word, int feed_valid)
{
    uint8_t row1 = feed_valid ? lane8(feed_word, 0) : 0;
    uint8_t row2 = feed_valid ? lane8(feed_word, 1) : 0;
    uint8_t row3 = feed_valid ? lane8(feed_word, 2) : 0;

    uint32_t out = pack3(row1, s->row2_d1, s->row3_d2);

    /* Equivalent to the RTL registers after the current PE step. */
    s->row3_d2 = s->row3_d1;
    s->row3_d1 = row3;
    s->row2_d1 = row2;

    return out;
}

static void act_skew_clear(act_skew_t *s)
{
    memset(s, 0, sizeof(*s));
}

/* ------------------------------------------------------------------------- */
/* input_buf helpers                                                         */
/* ------------------------------------------------------------------------- */
static uint8_t ibuf_read_channel(
    const input_buf_t *ibuf,
    int src_base,
    int in_w,
    int in_h,
    int in_c,
    int x,
    int y,
    int ch)
{
    int words_per_pixel;
    int pixel;
    int addr;
    int group;
    int byte_lane;

    if (x < 0 || x >= in_w || y < 0 || y >= in_h)
        return 0;

    if (ch < 0 || ch >= in_c)
        return 0;

    /* RTL currently supports the intended Cin=3 / Cin=6 packing. */
    words_per_pixel = (in_c > 3) ? 2 : 1;
    pixel = y * in_w + x;
    group = ch / 3;
    byte_lane = ch % 3;
    addr = src_base + pixel * words_per_pixel + group;

    return lane8(ibuf->mem[addr], byte_lane);
}

/* ------------------------------------------------------------------------- */
/* 4x4 window cache model                                                    */
/* ------------------------------------------------------------------------- */
static void patch_gen_init(
    patch_gen_t *pg,
    int src_base,
    int in_w,
    int in_h,
    int in_c,
    int pad_en)
{
    memset(pg, 0, sizeof(*pg));
    pg->src_base = src_base;
    pg->in_w = in_w;
    pg->in_h = in_h;
    pg->in_c = in_c;
    pg->pad_en = pad_en;
    pg->words_per_pixel = (in_c > 3) ? 2 : 1;

    /* Same as RTL: out_w = in_w when pad=1, otherwise in_w-2. */
    {
        int out_w = pad_en ? in_w : (in_w - 2);
        pg->wpr = out_w / 2;
        if (pg->wpr == 0)
            pg->wpr = 1;
    }
}

static void capture_window(
    patch_gen_t *pg,
    const input_buf_t *ibuf,
    int win,
    int verbose)
{
    int bank = win & 1;
    int win_x = win % pg->wpr;
    int win_y = win / pg->wpr;
    int org_x = 2 * win_x - (pg->pad_en ? 1 : 0);
    int org_y = 2 * win_y - (pg->pad_en ? 1 : 0);
    int cy, cx, grp;

    if (pg->valid[bank] && pg->tag[bank] == win) {
        if (verbose)
            fprintf(g_out, "  REUSE   window=%d bank%d\n", win, bank);
        return;
    }

    if (verbose)
        fprintf(g_out, "  CAPTURE window=%d bank%d org=(%d,%d)\n",
                win, bank, org_x, org_y);

    for (cy = 0; cy < 4; cy++) {
        for (cx = 0; cx < 4; cx++) {
            int x = org_x + cx;
            int y = org_y + cy;
            int pix = cy * 4 + cx;

            for (grp = 0; grp < pg->words_per_pixel; grp++) {
                uint32_t word = 0;
                int ch0 = grp * 3;
                int c;

                for (c = 0; c < 3; c++) {
                    int ch = ch0 + c;
                    uint8_t v = ibuf_read_channel(
                        ibuf,
                        pg->src_base,
                        pg->in_w,
                        pg->in_h,
                        pg->in_c,
                        x, y, ch);
                    word |= ((uint32_t)v << (8 * c));
                }

                pg->mem[bank][pix * pg->words_per_pixel + grp] = word;
            }
        }
    }

    pg->tag[bank] = win;
    pg->valid[bank] = 1;
    pg->capture_count++;
}

static uint8_t patch_value(
    const patch_gen_t *pg,
    int patch,
    int ky,
    int kx,
    int ch)
{
    int bank = (patch >> 2) & 1;
    int quadrant = patch & 3;
    int qoff = ((quadrant & 2) ? 4 : 0) +
               ((quadrant & 1) ? 1 : 0);
    int pix = qoff + ky * 4 + kx;
    int grp = ch / 3;
    int byte_lane = ch % 3;
    uint32_t word = pg->mem[bank][pix * pg->words_per_pixel + grp];

    return lane8(word, byte_lane);
}

static uint8_t direct_patch_value(
    const input_buf_t *ibuf,
    int in_w,
    int in_h,
    int in_c,
    int pad_en,
    int patch,
    int ky,
    int kx,
    int ch)
{
    int out_w = pad_en ? in_w : (in_w - 2);
    int wpr = out_w / 2;
    int win = patch >> 2;
    int q = patch & 3;
    int win_x = win % wpr;
    int win_y = win / wpr;

    int out_x = 2 * win_x + (q & 1);
    int out_y = 2 * win_y + ((q >> 1) & 1);

    int x = out_x + kx - (pad_en ? 1 : 0);
    int y = out_y + ky - (pad_en ? 1 : 0);

    return ibuf_read_channel(
        ibuf, 0, in_w, in_h, in_c, x, y, ch);
}

static void print_first_window_channels(
    const patch_gen_t *pg,
    int bank)
{
    int ch, y, x;

    fprintf(g_out, "\n[FIRST 4x4 WINDOW]\n");
    fprintf(g_out, "Out-of-range pixels use zero in every channel group.\n");

    for (ch = 0; ch < pg->in_c; ch++) {
        fprintf(g_out, "\n  Channel %d\n", ch);
        fprintf(g_out, "  +-----+-----+-----+-----+\n");
        for (y = 0; y < 4; y++) {
            fprintf(g_out, "  ");
            for (x = 0; x < 4; x++) {
                int pix = y * 4 + x;
                int word = pix * pg->words_per_pixel + ch / 3;
                uint8_t v = lane8(pg->mem[bank][word], ch % 3);
                fprintf(g_out, "| %3u ", (unsigned)v);
            }
            fprintf(g_out, "|\n  +-----+-----+-----+-----+\n");
        }
    }
}

/* ------------------------------------------------------------------------- */
/* CONV demo                                                                 */
/* ------------------------------------------------------------------------- */
/* Display the exact values already compared in the Conv verification loop.
 * Patch/lane/channel IDs are zero-based. This is C-model verification, not RTL.
 * Reporting does not increment g_error_count again for the same mismatch. */
static void print_patch_check(
    int patch, int lane, int ch, int in_c,
    const uint8_t *actual, const uint8_t *expected)
{
    int ky, kx;
    int mismatch = 0;

    fprintf(g_out, "\nPATCH=%d LANE=%d CHANNEL=%d (zero-based)\n",
            patch, lane, ch);
    fprintf(g_out, "Cell: actual/expected; * = mismatch\n");
    fprintf(g_out, "+---------+---------+---------+\n");
    for (ky = 0; ky < 3; ky++) {
        for (kx = 0; kx < 3; kx++) {
            int k = (ky * 3 + kx) * in_c + ch;
            unsigned got = actual[k];
            unsigned exp = expected[k];
            int bad = got != exp;
            mismatch += bad;
            fprintf(g_out, "|%3u/%3u%c ", got, exp, bad ? '*' : ' ');
        }
        fprintf(g_out, "|\n+---------+---------+---------+\n");
    }
    fprintf(g_out, "Checked=9  Mismatch=%d  %s\n",
            mismatch, mismatch == 0 ? "PASS" : "FAIL");
}

static void run_conv_demo(int in_c, int pad_en)
{
    input_buf_t ibuf;
    patch_gen_t pg;
    const int in_w = 4;
    const int in_h = 4;
    const int k_total = 9 * in_c;
    const int out_w = pad_en ? in_w : in_w - 2;
    const int out_h = pad_en ? in_h : in_h - 2;
    const int out_pix = out_w * out_h;
    const int words_per_pixel = in_c / 3;
    const int ram_base = 100;
    int y, x;
    int tile;
    int emitted_patches = 0;
    int checked_values = 0;
    int errors_before = g_error_count;

    memset(&ibuf, 0, sizeof(ibuf));

    fprintf(g_out, "============================================================\n");
    fprintf(g_out, "ACT PATH GOLDEN : CONV PATH\n");
    fprintf(g_out, "============================================================\n");
    fprintf(g_out, "Config : input=%dx%dx%d, kernel=3x3, stride=1, pad=%d, K=%d\n",
            in_h, in_w, in_c, pad_en, k_total);
    fprintf(g_out, "Packing: byte0/1/2 = C0/C1/C2; Cin=6 adds a second word for C3/C4/C5.\n");
    fprintf(g_out, "Patch order inside each 2x2 block: TL -> TR -> BL -> BR\n");
    fprintf(g_out, "Input values start from 1 so real data is not confused with padding 0.\n\n");

    fprintf(g_out, "[RAM -> INPUT_BUF]\n");
    for (y = 0; y < in_h; y++) {
        for (x = 0; x < in_w; x++) {
            int p = y * in_w + x;
            int grp;
            for (grp = 0; grp < words_per_pixel; grp++) {
                int ch = grp * 3;
                int addr = p * words_per_pixel + grp;
                uint8_t c0 = (uint8_t)(1 + p + 20 * ch);
                uint8_t c1 = (uint8_t)(1 + p + 20 * (ch + 1));
                uint8_t c2 = (uint8_t)(1 + p + 20 * (ch + 2));
                uint32_t word = pack3(c0, c1, c2);

                ibuf.mem[addr] = word;

                fprintf(g_out,
                        "  LOAD RAM[%3d] -> IBUF[%2d] pixel(%d,%d) "
                        "{C%d=%2u,C%d=%2u,C%d=%2u} ",
                        ram_base + addr, addr, y, x,
                        ch, (unsigned)c0, ch + 1, (unsigned)c1, ch + 2, (unsigned)c2);
                print_word(g_out, word);
                fprintf(g_out, "\n");
            }
        }
    }

    patch_gen_init(&pg, 0, in_w, in_h, in_c, pad_en);

    /* Build a copy of the first window only for display, then invalidate it
     * so the following trace starts from the same empty-cache state as RTL. */
    capture_window(&pg, &ibuf, 0, 0);
    print_first_window_channels(&pg, 0);
    pg.valid[0] = 0;
    pg.valid[1] = 0;
    pg.capture_count = 0;

    fprintf(g_out, "\n[PATCH / FEEDER / SKEW TRACE]\n");
    fprintf(g_out, "FEED rows = {Row1,Row2,Row3}; packed word = {Row3,Row2,Row1}\n");
    fprintf(g_out, "SKEW      = {Row1(now), Row2(-1), Row3(-2)}\n");

    for (tile = 0; tile < (out_pix + 2) / 3; tile++) {
        int base_patch = tile * 3;
        int remain = out_pix - base_patch;
        int row_mask = (remain >= 3) ? 7 : (remain == 2 ? 3 : 1);
        int lane;
        int k;
        act_skew_t skew;
        uint8_t history[MAX_K + 2][3] = {{0}};
        uint8_t actual[3][MAX_K] = {{0}};
        uint8_t expected[3][MAX_K] = {{0}};

        fprintf(g_out,
                "\n=== TILE %d base_patch=%d row_mask=%03d ===\n",
                tile, base_patch,
                (row_mask == 7) ? 111 : (row_mask == 3 ? 11 : 1));

        /* Same S_SELECT behavior: active lanes ensure their window is cached. */
        for (lane = 0; lane < 3; lane++) {
            if ((row_mask >> lane) & 1) {
                int patch = base_patch + lane;
                int win = patch >> 2;
                capture_window(&pg, &ibuf, win, 1);
            }
        }

        act_skew_clear(&skew);

        for (k = 0; k < k_total; k++) {
            int ch = k % in_c;
            int spatial = k / in_c;
            int kx = spatial % 3;
            int ky = spatial / 3;
            uint8_t row[3] = {0, 0, 0};
            uint32_t feed_word;
            uint32_t skew_word;

            for (lane = 0; lane < 3; lane++) {
                if ((row_mask >> lane) & 1) {
                    int patch = base_patch + lane;
                    uint8_t got = patch_value(&pg, patch, ky, kx, ch);
                    uint8_t exp = direct_patch_value(
                        &ibuf, in_w, in_h, in_c, pad_en,
                        patch, ky, kx, ch);

                    row[lane] = got;
                    actual[lane][k] = got;
                    expected[lane][k] = exp;
                    checked_values++;

                    if (got != exp) {
                        fprintf(g_out,
                                "  [ERROR] patch=%d k=%d got=%u exp=%u\n",
                                patch, k, (unsigned)got, (unsigned)exp);
                        g_error_count++;
                    }
                }
            }

            feed_word = pack3(row[0], row[1], row[2]);
            skew_word = act_skew_step(&skew, feed_word, 1);
            memcpy(history[k], row, sizeof row);
            if (skew_word != pack3(row[0], k >= 1 ? history[k-1][1] : 0,
                                  k >= 2 ? history[k-2][2] : 0)) {
                fprintf(g_out, "[ERROR] CONV skew mismatch tile=%d k=%d\n", tile, k);
                g_error_count++;
            }

            fprintf(g_out,
                    "k=%2d ky=%d kx=%d ch=%d "
                    "FEED={%3u,%3u,%3u} ",
                    k, ky, kx, ch,
                    (unsigned)row[0],
                    (unsigned)row[1],
                    (unsigned)row[2]);

            print_word(g_out, feed_word);

            fprintf(g_out,
                    " | SKEW={%3u,%3u,%3u} ",
                    (unsigned)lane8(skew_word, 0),
                    (unsigned)lane8(skew_word, 1),
                    (unsigned)lane8(skew_word, 2));

            print_word(g_out, skew_word);
            fprintf(g_out, "\n");
        }

        fprintf(g_out, "\n[PATCH CHECK GRIDS: C model vs direct-coordinate reference]\n");
        for (lane = 0; lane < 3; lane++) {
            int ch;
            if (!((row_mask >> lane) & 1))
                continue;
            for (ch = 0; ch < in_c; ch++) {
                print_patch_check(base_patch + lane, lane, ch, in_c,
                                  actual[lane], expected[lane]);
            }
        }

        /* Skew-only drain: Row2 needs 1 step, Row3 needs 2 steps. */
        for (lane = 0; lane < 2; lane++) {
            uint32_t skew_word = act_skew_step(&skew, 0, 0);
            int step = k_total + lane;
            uint32_t expected = pack3(0, history[step-1][1], history[step-2][2]);
            if (skew_word != expected) {
                fprintf(g_out, "[ERROR] CONV drain mismatch tile=%d drain=%d\n", tile, lane + 1);
                g_error_count++;
            }
            fprintf(g_out,
                    "DRAIN%d                          "
                    "SKEW={%3u,%3u,%3u} ",
                    lane + 1,
                    (unsigned)lane8(skew_word, 0),
                    (unsigned)lane8(skew_word, 1),
                    (unsigned)lane8(skew_word, 2));
            print_word(g_out, skew_word);
            fprintf(g_out, "\n");
        }

        emitted_patches += (row_mask == 7) ? 3 : (row_mask == 3 ? 2 : 1);
    }

    if (emitted_patches != out_pix) {
        fprintf(g_out,
                "[ERROR] emitted patch count=%d expected=%d\n",
                emitted_patches, out_pix);
        g_error_count++;
    }

    if (pg.capture_count != out_pix / 4 || checked_values != out_pix * k_total) {
        fprintf(g_out, "[ERROR] CONV capture/value count mismatch\n");
        g_error_count++;
    }
    fprintf(g_out,
            "\nCONV SUMMARY: Cin=%d pad=%d output patches=%d, captured windows=%d expected=%d, "
            "K/patch=%d, checked values=%d, %s\n\n",
            in_c, pad_en, emitted_patches, pg.capture_count, out_pix / 4,
            k_total, checked_values, g_error_count == errors_before ? "PASS" : "FAIL");
}

/* ------------------------------------------------------------------------- */
/* FC helper                                                                 */
/* ------------------------------------------------------------------------- */
static uint8_t fc_value(
    const input_buf_t *ibuf,
    int src_base,
    int input_count,
    int k)
{
    int word_offset;
    int byte_lane;

    if (input_count == 4096) {
        int pixel = k / 4;
        int ch = k % 4;

        word_offset = pixel * 2 + ((ch == 3) ? 1 : 0);
        byte_lane = (ch == 3) ? 0 : ch;
    } else {
        word_offset = k / 3;
        byte_lane = k % 3;
    }

    return lane8(ibuf->mem[src_base + word_offset], byte_lane);
}

static void run_fc_demo(void)
{
    input_buf_t ibuf;
    act_skew_t skew;
    int k;

    memset(&ibuf, 0, sizeof(ibuf));

    fprintf(g_out, "============================================================\n");
    fprintf(g_out, "ACT PATH GOLDEN : FC PATH\n");
    fprintf(g_out, "============================================================\n");

    /*
     * Generic FC path: 8 scalar inputs packed three per 24-bit word.
     * fc_gen outputs only lane0 and o_keep=001.
     */
    ibuf.mem[0] = pack3(60, 61, 62);
    ibuf.mem[1] = pack3(63, 64, 65);
    ibuf.mem[2] = pack3(66, 67, 0);

    fprintf(g_out, "\n[GENERIC FC, input_count=8]\n");
    fprintf(g_out, "IBUF[0]={60,61,62}, IBUF[1]={63,64,65}, IBUF[2]={66,67,0}\n");
    fprintf(g_out, "fc_gen sends only Row1, keep=001.\n");

    act_skew_clear(&skew);

    for (k = 0; k < 8; k++) {
        uint8_t v = fc_value(&ibuf, 0, 8, k);
        uint32_t feed_word = pack3(v, 0, 0);
        uint32_t skew_word = act_skew_step(&skew, feed_word, 1);

        if (v != 60 + k || feed_word != (uint32_t)(60 + k) || skew_word != feed_word) {
            fprintf(g_out, "[ERROR] generic FC mismatch k=%d\n", k);
            g_error_count++;
        }

        fprintf(g_out,
                "k=%d FC=%3u FEED={%3u,  0,  0} keep=001 ",
                k, (unsigned)v, (unsigned)v);
        print_word(g_out, feed_word);
        fprintf(g_out, " | SKEW={%3u,%3u,%3u} ",
                (unsigned)lane8(skew_word, 0),
                (unsigned)lane8(skew_word, 1),
                (unsigned)lane8(skew_word, 2));
        print_word(g_out, skew_word);
        fprintf(g_out, "\n");
    }

    /*
     * FC0 special packing sample.
     * input_count==4096 means four channels per pixel stored as:
     *   word 0: C0,C1,C2
     *   word 1: C3 in byte0
     */
    memset(&ibuf, 0, sizeof(ibuf));

    for (k = 0; k < 3; k++) {
        int base = 1 + k * 4;
        ibuf.mem[k * 2 + 0] =
            pack3((uint8_t)(base + 0),
                  (uint8_t)(base + 1),
                  (uint8_t)(base + 2));
        ibuf.mem[k * 2 + 1] =
            pack3((uint8_t)(base + 3), 0, 0);
    }

    fprintf(g_out, "\n[FC0 PACKING SAMPLE, input_count=4096]\n");
    fprintf(g_out, "Three pixels are shown; each pixel has C0,C1,C2,C3.\n");

    for (k = 0; k < 12; k++) {
        int pixel = k / 4;
        int ch = k % 4;
        int word_offset = pixel * 2 + ((ch == 3) ? 1 : 0);
        int byte_lane = (ch == 3) ? 0 : ch;
        uint8_t v = fc_value(&ibuf, 0, 4096, k);

        fprintf(g_out,
                "k=%2d pixel=%d ch=%d -> word=%d byte=%d -> %u\n",
                k, pixel, ch, word_offset, byte_lane, (unsigned)v);

        if (v != (uint8_t)(k + 1)) {
            fprintf(g_out,
                    "  [ERROR] FC0 value mismatch: got=%u exp=%d\n",
                    (unsigned)v, k + 1);
            g_error_count++;
        }
    }

    fprintf(g_out, "\n");
}

/* Full FC0 test: expected scalar vector is separate from packed memory. */
static void run_fc0_full(void)
{
    input_buf_t ibuf;
    act_skew_t skew;
    uint8_t expected[MAX_K];
    uint32_t rng = 0x19A45E31u;
    const int src_base = 137;
    int errors_before = g_error_count;
    int pixel, ch, k;

    memset(&ibuf, 0, sizeof ibuf);
    for (k = 0; k < MAX_K; k++) {
        rng ^= rng << 13;
        rng ^= rng >> 17;
        rng ^= rng << 5;
        expected[k] = (uint8_t)rng;
    }
    for (pixel = 0; pixel < MAX_K / 4; pixel++) {
        const uint8_t *v = &expected[pixel * 4];
        ibuf.mem[src_base + pixel * 2] = pack3(v[0], v[1], v[2]);
        /* Nonzero unused bytes catch accidentally reading a padding lane. */
        ibuf.mem[src_base + pixel * 2 + 1] = pack3(v[3], 0xA5, 0x5A);
    }

    fprintf(g_out, "\n[FC0 FULL, input_count=4096]\n");
    fprintf(g_out, "32x32x4; src_base=%d; deterministic raw 8-bit patterns; all 4096 values checked.\n", src_base);
    fprintf(g_out, "Values are unsigned byte displays (0..255), including negative INT8 bit patterns.\n");
    act_skew_clear(&skew);
    k = 0;
    for (pixel = 0; pixel < MAX_K / 4; pixel++) {
        for (ch = 0; ch < 4; ch++, k++) {
            uint8_t got = fc_value(&ibuf, src_base, MAX_K, k);
            uint32_t feed = pack3(got, 0, 0);
            uint32_t skew_word = act_skew_step(&skew, feed, 1);
            if (got != expected[k] || skew_word != (uint32_t)expected[k]) {
                fprintf(g_out, "[ERROR] FC0 full mismatch k=%d got=%u expected=%u\n",
                        k, (unsigned)got, (unsigned)expected[k]);
                g_error_count++;
            }
            fprintf(g_out, "k=%4d pixel=%4d ch=%d value=%3u expected=%3u FEED=0x%06X SKEW=0x%06X keep=001\n",
                    k, pixel, ch, (unsigned)got, (unsigned)expected[k],
                    (unsigned)feed, (unsigned)skew_word);
        }
    }
    fprintf(g_out, "FC0 FULL SUMMARY: checked=%d expected=4096, %s\n\n",
            k, g_error_count == errors_before ? "PASS" : "FAIL");
}


/* ------------------------------------------------------------------------- */
/* GitHub Markdown report                                                    */
/* ------------------------------------------------------------------------- */
static void md_close_code(FILE *md, int *code_open)
{
    if (*code_open) {
        fprintf(md, "```\n\n");
        *code_open = 0;
    }
}

static void md_close_tile(FILE *md, int *code_open, int *tile_open)
{
    md_close_code(md, code_open);
    if (*tile_open) {
        fprintf(md, "</details>\n\n");
        *tile_open = 0;
    }
}

static const char *md_section_title(const char *line)
{
    if (!strcmp(line, "[RAM -> INPUT_BUF]"))
        return "RAM → Input Buffer";
    if (!strcmp(line, "[FIRST 4x4 WINDOW]"))
        return "First 4×4 Window";
    if (!strcmp(line, "[PATCH / FEEDER / SKEW TRACE]"))
        return "Patch / Feeder / Skew Trace";
    if (!strcmp(line, "[GENERIC FC, input_count=8]"))
        return "Generic FC";
    if (!strcmp(line, "[FC0 PACKING SAMPLE, input_count=4096]"))
        return "FC0 Packing Sample";
    if (!strcmp(line, "[FC0 FULL, input_count=4096]"))
        return "FC0 Full 4096-Value Check";
    return NULL;
}

static int write_markdown_report(const char *txt_path, const char *md_path)
{
    FILE *in;
    FILE *md;
    char line[1024];
    int code_open = 0;
    int tile_open = 0;

    in = fopen(txt_path, "r");
    if (!in) return 0;

    md = fopen(md_path, "w");
    if (!md) {
        fclose(in);
        return 0;
    }

    fprintf(md, "# ACT PATH Golden Reference\n\n");
    fprintf(md, "> Generated by `golden_act_path.c`  \n");
    fprintf(md, "> Functional / step-level reference for padding, patch order, packing, FC mapping, and skew distribution.\n\n");

    fprintf(md, "Coverage: Conv Cin=3/6 x padding=0/1, generic FC, FC0 packing sample, and all 4096 FC0 values.\n\n");
    fprintf(md, "PASS checks the C model; RTL clock timing, memory latency, and stalls are not simulated.\n\n");
    fprintf(md, "## Data Path\n\n");
    fprintf(md, "```text\n");
    fprintf(md, "RAM -> act_ld_unit -> input_buf -> act_patch_gen / fc_gen -> MUX -> act_feeder -> act_skew -> PE\n");
    fprintf(md, "```\n\n");

    fprintf(md, "## Patch Movement Example\n\n");
    fprintf(md, "For `padding = 1`, the 4×4 window moves by **2 pixels**.\n\n");
    fprintf(md, "```text\n");
    fprintf(md, "Padded row : 0  A  B  C  D  E  F ...\n\n");
    fprintf(md, "Window 0   : [0  A  B  C]\n");
    fprintf(md, "Patch 1    : [0  A  B]\n");
    fprintf(md, "Patch 2    :    [A  B  C]\n\n");
    fprintf(md, "Window 1   :       [B  C  D  E]\n");
    fprintf(md, "Patch 1    :       [B  C  D]\n");
    fprintf(md, "Patch 2    :          [C  D  E]\n");
    fprintf(md, "```\n\n");

    while (fgets(line, sizeof line, in)) {
        size_t n = strcspn(line, "\r\n");
        const char *title;
        line[n] = '\0';

        if (!strcmp(line, "============================================================"))
            continue;

        if (!strcmp(line, "ACT PATH GOLDEN : CONV PATH")) {
            md_close_tile(md, &code_open, &tile_open);
            fprintf(md, "## CONV Path\n\n");
            continue;
        }

        if (!strcmp(line, "ACT PATH GOLDEN : FC PATH")) {
            md_close_tile(md, &code_open, &tile_open);
            fprintf(md, "## FC Path\n\n");
            continue;
        }

        if (!strncmp(line, "[RESULT]", 8)) {
            md_close_tile(md, &code_open, &tile_open);
            fprintf(md, "## Result\n\n");
            if (strstr(line, "PASS"))
                fprintf(md, "**PASS**\n\n");
            else
                fprintf(md, "**%s**\n\n", line + 9);
            continue;
        }

        title = md_section_title(line);
        if (title) {
            md_close_tile(md, &code_open, &tile_open);
            fprintf(md, "### %s\n\n", title);
            fprintf(md, "```text\n");
            code_open = 1;
            continue;
        }

        if (!strncmp(line, "=== TILE ", 9)) {
            char tile_title[sizeof line];
            size_t len;

            md_close_tile(md, &code_open, &tile_open);

            snprintf(tile_title, sizeof tile_title, "%s", line + 4);
            len = strlen(tile_title);
            if (len >= 4 && !strcmp(tile_title + len - 4, " ==="))
                tile_title[len - 4] = '\0';

            fprintf(md, "<details>\n");
            fprintf(md, "<summary><b>%s</b></summary>\n\n", tile_title);
            fprintf(md, "```text\n");
            code_open = 1;
            tile_open = 1;
            continue;
        }

        if (!code_open) {
            fprintf(md, "```text\n");
            code_open = 1;
        }

        fprintf(md, "%s\n", line);
    }

    md_close_tile(md, &code_open, &tile_open);

    fclose(md);
    fclose(in);
    return 1;
}

/* ------------------------------------------------------------------------- */
int main(int argc, char **argv)
{
    const char *base = "golden_act_path";
    char txt_path[512];
    char md_path[512];
    int i;

    for (i = 1; i < argc; i++) {
        if ((!strcmp(argv[i], "-b") || !strcmp(argv[i], "--base")) &&
            i + 1 < argc) {
            base = argv[++i];
        } else {
            printf("usage: %s [-b BASENAME]\n", argv[0]);
            return 2;
        }
    }

    snprintf(txt_path, sizeof txt_path, "%s.txt", base);
    snprintf(md_path, sizeof md_path, "%s.md", base);

    g_out = fopen(txt_path, "w");
    if (!g_out) {
        printf("cannot open output file: %s\n", txt_path);
        return 2;
    }

    g_error_count = 0;

    run_conv_demo(3, 1);
    run_conv_demo(6, 1);
    run_conv_demo(3, 0);
    run_conv_demo(6, 0);
    run_fc_demo();
    run_fc0_full();

    fprintf(g_out, "============================================================\n");
    if (g_error_count == 0)
        fprintf(g_out, "[RESULT] PASS\n");
    else
        fprintf(g_out, "[RESULT] FAIL : %d mismatch(es)\n", g_error_count);
    fprintf(g_out, "============================================================\n");

    fclose(g_out);

    if (!write_markdown_report(txt_path, md_path)) {
        printf("cannot create markdown report: %s\n", md_path);
        return 2;
    }

    printf("raw trace       -> %s\n", txt_path);
    printf("markdown report -> %s\n", md_path);
    printf("%s\n", g_error_count == 0 ? "PASS" : "FAIL");

    return g_error_count == 0 ? 0 : 1;
}
