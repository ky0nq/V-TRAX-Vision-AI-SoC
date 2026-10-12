/*
 * golden_top_cnn_cntl.c - golden reference for top_cnn_cntl (cnn_cntl + pe_cntl)
 *
 * Generates the control-event trace the controller is supposed to produce,
 * from the network shape alone. It is not a copy of the RTL; it just walks
 *
 *     layer -> pos_group (tile) -> oc_group -> chunk -> beat
 *
 * pos_group is the outer loop, oc_group the inner one. A tile's pos is a patch
 * ordinal (Z order inside 2x2 blocks, spec v1.2 / team drawing 2026-09-21).
 * On the RTL side tb_top_cnn_cntl_trace.v writes the same line format, and
 * --check here diffs the two files line by line.
 *
 * Transaction level, not cycle level. Clock counts move with datapath latency
 * and stalls (the SMALL TB inserts random stalls), but event order, count and
 * payload must not. Events that can land on the same clk (FRAME_CONSUME /
 * OWNER 1 / first PRD, TSTART / PECMD) are printed by the RTL tracer in the
 * same order as here.
 *
 * pe_cntl's MAC control is modelled per step: the 5-stage valid_pipe /
 * last_pipe is shifted for real, so the per-PE mac_valid count, mac_last count
 * and the MAC index of mac_last come out exact.
 *
 * Events, one per line:
 *   START                               start_valid && start_ready
 *   IMG_LD                              cnn_cntl.o_ld_start (image always goes to region A = 0)
 *   FRAME_CONSUME                       o_frame_consume
 *   PLSTART / PLDONE                    o_param_load_start / i_param_load_done
 *   OWNER 1|0                           o_ram_owner changed
 *   PRD addr=                           Param RAM read request fired
 *   PWR addr= data=                     param_buf write, data = 32-bit bias (address pairing is checked too)
 *   LCFG L= ...                         o_layer_cfg_valid + the descriptor ports that still exist
 *                                       (2026-09-22: o_out_w / o_out_h / o_in_zp / o_conv_h were dropped
 *                                        from cnn_cntl, so the line carries outc=, conv_w=, conv_h=, pool_c=;
 *                                        o_conv_h was put back the same day)
 *   WLOAD L= base= og= kb= len= ram=    wload fired, ram = base + og*K + kb
 *   TCFG L= tile= pos= rm= cm= ocb= ... o_tile_cfg_valid + tile config
 *   TSTART PG|FC                        o_pg_tile_start / o_fc_tile_start
 *   PECMD K= rm= cm=                    cnn_cntl -> pe_cntl tile command fired
 *   RSTART len=                         pe_cntl.o_chunk_start + o_chunk_word_count (once per chunk)
 *   CREQ kb= len=                       pe_cntl -> cnn_cntl chunk request fired
 *   TILE inject= step= clr= creq= mv= ml= last_at=
 *                                       tile totals when pe_cntl is back in P_IDLE
 *   LEND L=                             left C_LAYER_END
 *   DONE writer_mode=                   o_busy dropped
 *
 * Build (any C89+ compiler; MSYS2 ucrt64 gcc on Windows):
 *   gcc -O2 -Wall -o golden_top_cnn_cntl golden_top_cnn_cntl.c
 *
 * Run:
 *   golden_top_cnn_cntl --full                   write golden_trace_full.txt + summary
 *   golden_top_cnn_cntl --small                  write golden_trace_small.txt
 *   golden_top_cnn_cntl --small --check rtl_trace_small.txt
 *                                                diff against an RTL trace; keeps going
 *                                                for as many inferences as the trace holds
 *   --runs N   inferences to generate (default 1)
 *   -o FILE    output file
 *
 *   --full  = Candidate ID 32 (64x64x3, fc1 out 32)  = tb_top_cnn_cntl_full   (WBUF_WORDS 256)
 *   --small = TB with SMALL=1 (16x16x3, fc1 out 6)   = tb_top_cnn_cntl        (WBUF_WORDS 64, so fc1 K=256 is still 4 chunks)
 *
 * Getting the RTL trace (xsim 2020.2, from the project root):
 *   xvlog -i cnn_accelerator.srcs/sources_1/new \
 *         cnn_accelerator.srcs/sources_1/new/top_cnn_cntl.v \
 *         cnn_accelerator.srcs/sim_1/new/tb_top_cnn_cntl.v \
 *         cnn_accelerator.srcs/sim_1/new/tb_top_cnn_cntl_trace.v
 *   xelab -debug off tb_top_cnn_cntl_trace -s X        (or tb_top_cnn_cntl_trace_full)
 *   xsim X -R                                          -> rtl_trace_small.txt / rtl_trace_full.txt in the run dir
 *   golden_top_cnn_cntl --small --check rtl_trace_small.txt
 *
 * Exit code: 0 pass, 1 mismatch / empty trace, 2 bad args or file error.
 *
 * Controller changes on 2026-09-22 that this model already covers or does not need:
 *   - pe_cntl lost o_reader_issue_en / i_reader_idle / i_weight_feeder_empty and
 *     o_result_clear; cnn_cntl lost o_conv_h / o_out_w / o_out_h / o_in_zp. None of
 *     them was a trace event, only the LCFG payload shrank (see above).
 *   - out_path.o_result_space_ready now gates pe_cntl.o_tile_ready (tile level, via
 *     space_seen) instead of every step. That only delays events, it never reorders
 *     them, so a transaction-level model needs no change.
 *   - The wrapper's o_pos_base / o_mem_base / o_param_base / o_param_wr_addr are now
 *     14 / 32 / 6 / 6 bits wide (receiver widths). Values are unchanged; check_widths()
 *     still uses the cnn_cntl internal widths.
 *   - 2026-09-23 wgt_buf double buffer (two halves of WBUF_WORDS, 256 in the real design):
 *     chunk n -> half n%2, pe_cntl requests chunk n+1 at RSTART n (event order unchanged),
 *     and single-chunk layers put oc_group g in half g%2 with one tag per half, so a
 *     2-group Conv loads its weights only twice per layer (WLOAD count changed).
 */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* same widths as cnn_defs.vh, used by check_widths() */
#define ACT_AW     14   /* input_buf address     */
#define K_W        13   /* K_total 1..4096       */
#define POS_W      12   /* output position index */
#define W_AW       16   /* weight word address   */
#define PARAM_AW    7   /* param record 0..127   */
#define OCG_W       4   /* oc_group              */
#define OCB_W       5   /* out_ch_base           */
#define CH_W        6   /* channel count         */
#define DIM_W       7   /* W / H                 */

#define NUM_LAYERS  4
static int g_wbuf = 256; /* wgt_buf HALF depth = max chunk length: 256 (FULL) / 64 (SMALL keeps fc1 multi-chunk). set from config */
#define PE_N        9   /* 3 x 3 PE              */
#define PIPE_N      5   /* valid_pipe / last_pipe depth = diagonal d = r + c (0..4) */

/* ---------------------------------------------------------------------------
 * network description
 * -------------------------------------------------------------------------*/
typedef struct {
    const char *name;
    int is_fc;
    int in_w, in_h, in_c;
    int out_w, out_h, out_c;
    int stride, pad_en;
    int k_total;            /* Conv : 3*3*in_c        FC : in_w*in_h*in_c */
    int out_pix;            /* Conv : out_w*out_h     FC : 1              */
    int relu, pool_en;
    int w_base;             /* sum of ceil(out_c/3)*K over earlier layers  */
    int param_base;         /* sum of out_c over earlier layers            */
} layer_t;

typedef struct {
    const char *label;
    int img_w, img_h;
    int fc1_out;
    int region_a, region_b;     /* start of the two input_buf regions, swapped every layer */
    int wbuf;                   /* wgt_buf half depth = max chunk length (top_cnn_cntl WBUF_WORDS) */
} config_t;

static const config_t CFG_FULL  = { "FULL",  64, 64, 32, 0, 8192, 256 };
static const config_t CFG_SMALL = { "SMALL", 16, 16,  6, 0, 2048,  64 };

static int ceil_div(int a, int b) { return (a + b - 1) / b; }
static int imin(int a, int b)     { return (a < b) ? a : b; }

static const char *b3(int m)
{
    static const char *t[8] = { "000", "001", "010", "011", "100", "101", "110", "111" };
    return t[m & 7];
}

static layer_t make_conv(const char *name, int in_w, int in_h, int in_c, int out_c,
                         int relu, int pool_en)
{
    layer_t l;
    memset(&l, 0, sizeof l);
    l.name = name;  l.is_fc = 0;
    l.in_w = in_w;  l.in_h = in_h;  l.in_c = in_c;
    l.stride = 1;   l.pad_en = 1;
    l.out_w = (in_w + 2 * l.pad_en - 3) / l.stride + 1;
    l.out_h = (in_h + 2 * l.pad_en - 3) / l.stride + 1;
    l.out_c = out_c;
    l.k_total = 3 * 3 * in_c;
    l.out_pix = l.out_w * l.out_h;
    l.relu = relu;  l.pool_en = pool_en;
    return l;
}

static layer_t make_fc(const char *name, int in_w, int in_h, int in_c, int out_c, int relu)
{
    layer_t l;
    memset(&l, 0, sizeof l);
    l.name = name;  l.is_fc = 1;
    l.in_w = in_w;  l.in_h = in_h;  l.in_c = in_c;
    l.stride = 1;   l.pad_en = 0;
    l.out_w = 1;    l.out_h = 1;    l.out_c = out_c;
    l.k_total = in_w * in_h * in_c;         /* flattened input count */
    l.out_pix = 1;
    l.relu = relu;  l.pool_en = 0;
    return l;
}

/* Conv0 -> MaxPool 2x2 -> Conv1 -> flatten -> fc1 -> fc2 */
static void build_network(layer_t L[NUM_LAYERS], const config_t *c)
{
    int l, w = 0, p = 0;

    L[0] = make_conv("Conv0", c->img_w, c->img_h, 3, 6, 1, 1);
    L[1] = make_conv("Conv1", L[0].out_w / 2, L[0].out_h / 2, L[0].out_c, 4, 1, 0);
    L[2] = make_fc("fc1", L[1].out_w, L[1].out_h, L[1].out_c, c->fc1_out, 1);
    L[3] = make_fc("fc2", 1, 1, L[2].out_c, 1, 0);

    for (l = 0; l < NUM_LAYERS; l++) {
        L[l].w_base     = w;
        L[l].param_base = p;
        w += ceil_div(L[l].out_c, 3) * L[l].k_total;    /* one oc_group = K words       */
        p += L[l].out_c;                                /* one record per output channel */
    }
}

/* does the config fit the RTL register widths? if not, the RTL truncates silently */
static int check_widths(const layer_t *L, const config_t *c)
{
    int l, bad = 0, w_total = 0, p_total = 0;
    int region_words = c->region_b - c->region_a;

#define NEED(cond, ...) do { if (!(cond)) { printf("  [WIDTH] " __VA_ARGS__); printf("\n"); bad++; } } while (0)
    for (l = 0; l < NUM_LAYERS; l++) {
        const layer_t *y = &L[l];
        int n_pg = ceil_div(y->out_pix, 3), n_og = ceil_div(y->out_c, 3);
        int in_words  = y->in_w * y->in_h * ceil_div(y->in_c, 3);
        int out_words = (y->pool_en ? (y->out_w / 2) * (y->out_h / 2) : y->out_pix)
                        * ceil_div(y->out_c, 3);

        NEED(y->k_total >= 1 && y->k_total < (1 << K_W), "%s K=%d does not fit K_W=%d", y->name, y->k_total, K_W);
        NEED(y->out_pix < (1 << K_W),            "%s out_pix=%d does not fit K_W", y->name, y->out_pix);
        NEED(3 * (n_pg - 1) < (1 << POS_W),      "%s max pos_base %d does not fit POS_W=%d", y->name, 3 * (n_pg - 1), POS_W);
        NEED(n_og - 1 < (1 << OCG_W),            "%s max oc_group %d does not fit OCG_W=%d", y->name, n_og - 1, OCG_W);
        NEED(3 * (n_og - 1) < (1 << OCB_W),      "%s max out_ch_base %d does not fit OCB_W=%d", y->name, 3 * (n_og - 1), OCB_W);
        NEED(y->in_c < (1 << CH_W) && y->out_c < (1 << CH_W), "%s channel count does not fit CH_W=%d", y->name, CH_W);
        NEED(y->in_w < (1 << DIM_W) && y->in_h < (1 << DIM_W) &&
             y->out_w < (1 << DIM_W) && y->out_h < (1 << DIM_W), "%s W/H does not fit DIM_W=%d", y->name, DIM_W);
        NEED(in_words <= region_words,  "%s input %d words exceeds region %d words", y->name, in_words, region_words);
        if (l != NUM_LAYERS - 1)
            NEED(out_words <= region_words, "%s output %d words exceeds region %d words", y->name, out_words, region_words);

        w_total = y->w_base + n_og * y->k_total;
        p_total = y->param_base + y->out_c;
    }
    NEED(w_total <= (1 << W_AW),     "weight total %d words exceeds W_AW=%d", w_total, W_AW);
    NEED(p_total <= (1 << PARAM_AW), "param total %d records exceeds param_buf %d", p_total, 1 << PARAM_AW);
    NEED(c->region_b + region_words <= (1 << ACT_AW), "end of region B exceeds ACT_AW=%d", ACT_AW);
#undef NEED
    return bad;
}

/* ---------------------------------------------------------------------------
 * trace output / compare
 * -------------------------------------------------------------------------*/
#define LINE_MAX_LEN 512
#define MAX_REPORT    10

static FILE *g_out = NULL;          /* golden trace file, or NULL             */
static FILE *g_rtl = NULL;          /* RTL trace to compare against, or NULL  */
static long  g_lines = 0;
static long  g_mismatch = 0;
static char  g_ctx[LINE_MAX_LEN] = "";      /* last LCFG / TCFG, printed with a mismatch so you know where you are */

/* print one trace line; with --check, compare it to the next RTL line */
static void emit(const char *fmt, ...)
{
    char exp[LINE_MAX_LEN], got[LINE_MAX_LEN];
    va_list ap;

    va_start(ap, fmt);
    vsnprintf(exp, sizeof exp, fmt, ap);
    va_end(ap);
    g_lines++;

    if (!strncmp(exp, "LCFG", 4) || !strncmp(exp, "TCFG", 4))
        snprintf(g_ctx, sizeof g_ctx, "%s", exp);

    if (g_out) fprintf(g_out, "%s\n", exp);
    if (!g_rtl) return;

    if (!fgets(got, sizeof got, g_rtl)) {
        if (g_mismatch < MAX_REPORT)
            printf("  [MISMATCH] line %ld : RTL trace ended early\n      golden : %s\n", g_lines, exp);
        g_mismatch++;
        return;
    }
    got[strcspn(got, "\r\n")] = '\0';
    if (strcmp(exp, got) != 0) {
        if (g_mismatch < MAX_REPORT) {
            printf("  [MISMATCH] line %ld\n      golden : %s\n      rtl    : %s\n", g_lines, exp, got);
            if (g_ctx[0] && strcmp(g_ctx, exp) != 0)
                printf("      (last config : %s)\n", g_ctx);
        }
        g_mismatch++;
    }
}

/* ---------------------------------------------------------------------------
 * stats
 * -------------------------------------------------------------------------*/
typedef struct {
    long tiles, wloads, creqs, beats, macs;
} stat_t;

static stat_t g_stat[NUM_LAYERS];
static long   g_param_reads;

/* ---------------------------------------------------------------------------
 * Param RAM contents: same pattern as the RAM model in tb_top_cnn_cntl
 *   pdata(a) = {12{1'b0, a[6:0]}} ^ 96'h0123_4567_89AB_CDEF_0011_2233
 * cnn_cntl has to write each value back at the address it was read from.
 * pl_idx has already moved on by then, so without the pl_addr_q latch every
 * record lands one slot off.
 * -------------------------------------------------------------------------*/
/* requant M / S, same for every layer. tb_top_cnn_cntl uses top_cnn_cntl's parameter defaults (M = 2^30, S = 30). */
#define QUANT_M_DEFAULT 0x40000000u
#define QUANT_S_DEFAULT 30

static void param_ram_hex(int addr, char hex[25])
{
    static const unsigned char k[12] = { 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB,
                                         0xCD, 0xEF, 0x00, 0x11, 0x22, 0x33 };
    int i;
    for (i = 0; i < 12; i++)
        sprintf(hex + 2 * i, "%02x", (unsigned)((addr & 0x7F) ^ k[i]));
}

/* ---------------------------------------------------------------------------
 * cnn_cntl weight load service (first chunk and mid-tile chunks share it)
 * -------------------------------------------------------------------------*/
typedef struct {
    const layer_t *layer;
    int layer_idx;
    int oc_group;
    /* tag of what each wgt_buf half holds right now (2026-09-23 double buffer: half 0 / 1) */
    int tag_valid[2], tag_layer[2], tag_oc[2];
} cnn_ctx_t;

static cnn_ctx_t g_cnn;

static void cnn_issue_wload(int k_base, int len)
{
    const layer_t *y = g_cnn.layer;
    /* RAM address wgt_ld_unit actually reads = weight_base + oc_group*K + k_base */
    int ram = y->w_base + g_cnn.oc_group * y->k_total + k_base;

    emit("WLOAD L=%d base=%d og=%d kb=%d len=%d ram=%d",
         g_cnn.layer_idx, y->w_base, g_cnn.oc_group, k_base, len, ram);
    g_stat[g_cnn.layer_idx].wloads++;
}

/* handle a chunk request from pe_cntl (wsvc inside C_PE_WAIT).
 * Double buffer (2026-09-23): chunk n of a multi-chunk tile goes to half n % 2, and pe_cntl asks for
 * chunk n+1 as soon as it starts reading chunk n, so the load overlaps the feed. The event order
 * (RSTART n, CREQ n+1, WLOAD n+1, ... RSTART n+1) is the same as before, only the timing moved. */
static void cnn_chunk_service(int k_base, int len)
{
    int half = (k_base / g_wbuf) & 1;
    emit("CREQ kb=%d len=%d", k_base, len);
    g_stat[g_cnn.layer_idx].creqs++;
    cnn_issue_wload(k_base, len);
    g_cnn.tag_valid[half] = 0;  /* this half now holds a later chunk */
}

/* ---------------------------------------------------------------------------
 * pe_cntl: one tile
 *
 *   one step = one clk with step_en = 1 in the RTL
 *     - in that step mac_valid[n] = valid_pipe[r+c] && row_mask[r] && col_mask[c]
 *     - then the pipe shifts by one (1 in on inject, 0 in on drain)
 *   no steps across a chunk boundary: pipe and accumulators stay frozen
 * -------------------------------------------------------------------------*/
static void pe_cntl_tile(int k_total, int row_mask, int col_mask)
{
    unsigned valid_pipe = 0, last_pipe = 0;
    int mv[PE_N], ml[PE_N], last_at[PE_N];
    int n_inject = 0, n_step = 0, n_clr = 0, n_creq = 0;
    int k_base = 0, cur_len = imin(k_total, g_wbuf);
    int k_cnt, n, exit_after;
    long macs = 0;

    for (n = 0; n < PE_N; n++) { mv[n] = 0; ml[n] = 0; last_at[n] = -1; }

#define COUNT_STEP() do {                                                     \
        for (n = 0; n < PE_N; n++) {                                          \
            int r = n / 3, c = n % 3, d = r + c;                              \
            int en = ((row_mask >> r) & 1) && ((col_mask >> c) & 1);          \
            if (en && ((valid_pipe >> d) & 1)) mv[n]++;                       \
            if (en && ((last_pipe  >> d) & 1)) { ml[n]++; last_at[n] = mv[n]; } \
        }                                                                     \
        n_step++;                                                             \
    } while (0)

    n_clr++;                                        /* P_CLEAR: the three clears only happen here */
    emit("RSTART len=%d", cur_len);                 /* P_PREFILL */

    for (;;) {
        /* P_FEED: inject this chunk beat by beat */
        for (k_cnt = 0; k_cnt < cur_len; k_cnt++) {
            int beat_chunk_last  = (k_cnt == cur_len - 1);
            int beat_global_last = beat_chunk_last && (k_base + cur_len == k_total);

            COUNT_STEP();
            n_inject++;
            valid_pipe = ((valid_pipe << 1) | 1u) & ((1u << PIPE_N) - 1);
            /* mac_last only on the last beat of the whole K, not of the chunk */
            last_pipe  = ((last_pipe  << 1) | (unsigned)beat_global_last) & ((1u << PIPE_N) - 1);
        }
        k_base += cur_len;
        if (k_base == k_total) break;

        /* next chunk. In the RTL (2026-09-23 double buffer) pe_cntl raises the request in P_PREFILL of
         * the chunk just started and cnn_cntl loads it into the other half while the beats above are
         * fed; the beats emit no events, so CREQ / WLOAD land here in the trace, after RSTART n and
         * before RSTART n+1, exactly as before. P_CHUNK_WAIT then lasts 1 clk (not modelled: no event). */
        {
            int next_len = imin(k_total - k_base, g_wbuf);
            cnn_chunk_service(k_base, next_len);
            n_creq++;
            cur_len = next_len;
        }
        emit("RSTART len=%d", cur_len);             /* P_PREFILL: reader restarts from address 0 */
    }

    /* P_DRAIN: push the last beat through to PE8 (d=4), always 5 steps */
    do {
        exit_after = ((valid_pipe & 0x0Fu) == 0);
        COUNT_STEP();
        valid_pipe = (valid_pipe << 1) & ((1u << PIPE_N) - 1);
        last_pipe  = (last_pipe  << 1) & ((1u << PIPE_N) - 1);
    } while (!exit_after);
#undef COUNT_STEP

    /* P_DONE -> P_IDLE */
    emit("TILE inject=%d step=%d clr=%d creq=%d "
         "mv=%d,%d,%d,%d,%d,%d,%d,%d,%d ml=%d,%d,%d,%d,%d,%d,%d,%d,%d "
         "last_at=%d,%d,%d,%d,%d,%d,%d,%d,%d",
         n_inject, n_step, n_clr, n_creq,
         mv[0], mv[1], mv[2], mv[3], mv[4], mv[5], mv[6], mv[7], mv[8],
         ml[0], ml[1], ml[2], ml[3], ml[4], ml[5], ml[6], ml[7], ml[8],
         last_at[0], last_at[1], last_at[2], last_at[3], last_at[4],
         last_at[5], last_at[6], last_at[7], last_at[8]);

    for (n = 0; n < PE_N; n++) macs += mv[n];
    g_stat[g_cnn.layer_idx].beats += n_inject;
    g_stat[g_cnn.layer_idx].macs  += macs;
}

/* ---------------------------------------------------------------------------
 * cnn_cntl: one inference
 * -------------------------------------------------------------------------*/
static int lane_mask(int total, int base)
{
    int remain = total - base;
    if (remain <= 0) return 0;
    if (remain >= 3) return 7;      /* 111 */
    if (remain == 2) return 3;      /* 011 */
    return 1;                       /* 001 */
}

static void run_inference(const layer_t *L, const config_t *c)
{
    int l, og, pg, i, tile = 0, region_sel = 0;
    int param_total = L[NUM_LAYERS - 1].param_base + L[NUM_LAYERS - 1].out_c;
    char hex[25];

    /* C_IDLE -> C_START: the image goes to region A, where L0 reads from */
    emit("START");
    emit("IMG_LD");
    emit("FRAME_CONSUME");

    /* C_PARAM_LOAD: once per inference, records 0..TOTAL-1 at their own addresses */
    emit("PLSTART");                /* o_param_load_start: resets param_buf's load counter */
    emit("OWNER 1");
    for (i = 0; i < param_total; i++) {
        param_ram_hex(i, hex);
        emit("PRD addr=%d", i);
        emit("PWR addr=%d data=%s", i, hex + 16);   /* only the low 32 bits (bias) go to param_buf */
        g_param_reads++;
    }
    emit("PLDONE");                 /* 1clk after param_buf stored the last bias */
    emit("OWNER 0");                /* stays at weight (0) for the whole tile loop */

    g_cnn.tag_valid[0] = 0;         /* cleared in C_IDLE, so the first tile of a second inference loads again */
    g_cnn.tag_valid[1] = 0;

    for (l = 0; l < NUM_LAYERS; l++) {
        const layer_t *y = &L[l];
        int n_og  = ceil_div(y->out_c, 3);
        int n_pg  = ceil_div(y->out_pix, 3);
        int src   = region_sel ? c->region_b : c->region_a;   /* read the region the previous layer wrote */
        int dst   = region_sel ? c->region_a : c->region_b;
        int final = (l == NUM_LAYERS - 1);

        g_cnn.layer = y;
        g_cnn.layer_idx = l;

        /* C_SET: layer_cfg and output_cfg on the same clk */
        emit("LCFG L=%d ocfg=1 src=%d dst=%d in=%dx%dx%d outc=%d stride=%d pad=%d "
             "K=%d fc=%d pool=%d conv_w=%d conv_h=%d pool_c=%d final=%d relu=%d pbase=%d wbase=%d qm=%08x qs=%d",
             l, src, dst, y->in_w, y->in_h, y->in_c, y->out_c,
             y->stride, y->pad_en, y->k_total, y->is_fc, y->pool_en,
             y->out_w, y->out_h, y->out_c,              /* o_pool_in_w / o_pool_in_h = pre-pool size, o_pool_c = out_c */
             final, y->relu, y->param_base, y->w_base, QUANT_M_DEFAULT, QUANT_S_DEFAULT);

        /* tile order: pos_group outer, oc_group inner
         *   spec out_path.i_patch_base: "hold across channel groups, +3 on the
         *   next position tile". pos_base is a patch ordinal, not a raster
         *   position (Z order inside 2x2 blocks; W=64: patch 0..8 -> pos
         *   0,1,64,65,2,3,66,67,4). Turning it into coordinates is the job of
         *   act_patch_gen / output_fifo; the controller only adds 3. Running
         *   the channel groups back to back at one position lets act_patch_gen
         *   replay the same patch without re-reading the input. */
        for (pg = 0; pg < n_pg; pg++) {
            for (og = 0; og < n_og; og++) {
                int pos_base    = pg * 3;
                int out_ch_base = og * 3;
                int row_mask    = lane_mask(y->out_pix, pos_base);
                int col_mask    = lane_mask(y->out_c,   out_ch_base);
                int tile_last   = (pg == n_pg - 1) && (og == n_og - 1);
                int skip;

                g_cnn.oc_group = og;

                /* C_W_LOAD: the tile's first chunk goes to half `fh` = oc_group parity when K fits one
                 *   chunk (so both groups of a 2-group Conv stay resident and only the first two tiles
                 *   of the layer load), else half 0. Reuse when that half holds (layer, oc_group). */
                {
                    int fh = (y->k_total > g_wbuf) ? 0 : (og & 1);
                    skip = g_cnn.tag_valid[fh] && (g_cnn.tag_layer[fh] == l) && (g_cnn.tag_oc[fh] == og) &&
                           (y->k_total <= g_wbuf);
                    if (!skip) {
                        cnn_issue_wload(0, imin(y->k_total, g_wbuf));
                        g_cnn.tag_valid[fh] = 1;
                        g_cnn.tag_layer[fh] = l;
                        g_cnn.tag_oc[fh]    = og;
                    }
                }

                /* C_TILE_CFG */
                emit("TCFG L=%d tile=%d pos=%d rm=%s cm=%s ocb=%d last=%d relu=%d pb=%d K=%d",
                     l, tile, pos_base, b3(row_mask), b3(col_mask), out_ch_base,
                     tile_last, y->relu, y->param_base, y->k_total);

                /* C_PE_TILE */
                emit("TSTART %s", y->is_fc ? "FC" : "PG");
                emit("PECMD K=%d rm=%s cm=%s", y->k_total, b3(row_mask), b3(col_mask));

                /* C_PE_WAIT: pe_cntl runs the tile */
                pe_cntl_tile(y->k_total, row_mask, col_mask);

                g_stat[l].tiles++;
                tile++;
            }
        }

        /* C_LAYER_END: once the store is done, swap read / write regions (flip region_sel) */
        emit("LEND L=%d", l);
        region_sel ^= 1;
    }

    emit("DONE writer_mode=0");
}

/* ---------------------------------------------------------------------------
 * summary
 * -------------------------------------------------------------------------*/
static void print_summary(const layer_t *L, const config_t *c, int runs)
{
    int l;
    stat_t t;
    char shape[64];

    memset(&t, 0, sizeof t);
    printf("\n  config %s : image %dx%dx3, fc1 out %d, region A/B = %d/%d, %d inference(s), per-inference numbers\n\n",
           c->label, c->img_w, c->img_h, c->fc1_out, c->region_a, c->region_b, runs);
    printf("  %-6s %-24s %5s %6s %5s %6s %6s %6s %6s %8s %9s\n",
           "layer", "shape", "K", "pos_g", "oc_g", "tiles", "chunk", "wload", "creq", "beats", "MAC");
    for (l = 0; l < NUM_LAYERS; l++) {
        const layer_t *y = &L[l];
        snprintf(shape, sizeof shape, "%dx%dx%d -> %dx%dx%d%s",
                 y->in_w, y->in_h, y->in_c, y->out_w, y->out_h, y->out_c, y->pool_en ? " +pool" : "");
        printf("  %-6s %-24s %5d %6d %5d %6ld %6d %6ld %6ld %8ld %9ld\n",
               y->name, shape, y->k_total, ceil_div(y->out_pix, 3), ceil_div(y->out_c, 3),
               g_stat[l].tiles / runs, ceil_div(y->k_total, g_wbuf),
               g_stat[l].wloads / runs, g_stat[l].creqs / runs,
               g_stat[l].beats / runs, g_stat[l].macs / runs);
        t.tiles += g_stat[l].tiles;   t.wloads += g_stat[l].wloads;  t.creqs += g_stat[l].creqs;
        t.beats += g_stat[l].beats;   t.macs   += g_stat[l].macs;
    }
    printf("  %-6s %-24s %5s %6s %5s %6ld %6s %6ld %6ld %8ld %9ld\n",
           "total", "", "", "", "", t.tiles / runs, "", t.wloads / runs, t.creqs / runs,
           t.beats / runs, t.macs / runs);
    printf("\n  param records %ld,  weight words %d,  trace %ld lines (%ld per inference)\n",
           g_param_reads / runs,
           L[NUM_LAYERS - 1].w_base + ceil_div(L[NUM_LAYERS - 1].out_c, 3) * L[NUM_LAYERS - 1].k_total,
           g_lines, g_lines / runs);
}

/* ---------------------------------------------------------------------------
 * main
 * -------------------------------------------------------------------------*/
static void usage(const char *argv0)
{
    printf("usage : %s [--full | --small] [--runs N] [-o FILE] [--check RTL_TRACE]\n", argv0);
    printf("   --full   Candidate ID 32 (default)      --small  TB with SMALL=1\n");
    printf("   --runs   inferences to generate (default 1). with --check, runs until the RTL trace ends\n");
    printf("   -o       golden trace file. default golden_trace_<full|small>.txt (not written with --check)\n");
}

int main(int argc, char **argv)
{
    config_t cfg = CFG_FULL;
    layer_t  L[NUM_LAYERS];
    const char *out_path = NULL, *check_path = NULL;
    char default_out[64];
    int runs = 1, done_runs = 0, i, bad;

    for (i = 1; i < argc; i++) {
        if      (!strcmp(argv[i], "--full"))  cfg = CFG_FULL;
        else if (!strcmp(argv[i], "--small")) cfg = CFG_SMALL;
        else if (!strcmp(argv[i], "--runs")  && i + 1 < argc) runs = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-o")      && i + 1 < argc) out_path = argv[++i];
        else if (!strcmp(argv[i], "--check") && i + 1 < argc) check_path = argv[++i];
        else { usage(argv[0]); return 2; }
    }
    if (runs < 1) runs = 1;

    g_wbuf = cfg.wbuf;
    build_network(L, &cfg);
    bad = check_widths(L, &cfg);
    if (bad) printf("  %d config value(s) exceed the RTL widths, results may differ from the RTL\n", bad);

    if (check_path) {
        g_rtl = fopen(check_path, "r");
        if (!g_rtl) { printf("  cannot open RTL trace : %s\n", check_path); return 2; }
    }
    else if (!out_path) {
        snprintf(default_out, sizeof default_out, "golden_trace_%s.txt",
                 (cfg.img_w == CFG_SMALL.img_w) ? "small" : "full");
        out_path = default_out;
    }
    if (out_path) {
        g_out = fopen(out_path, "w");
        if (!g_out) { printf("  cannot open output file : %s\n", out_path); return 2; }
    }

    if (g_rtl) {
        for (;;) {
            int ch = fgetc(g_rtl);
            if (ch == EOF) break;
            ungetc(ch, g_rtl);
            run_inference(L, &cfg);
            done_runs++;
        }
    }
    else {
        for (done_runs = 0; done_runs < runs; done_runs++)
            run_inference(L, &cfg);
    }

    if (done_runs > 0) print_summary(L, &cfg, done_runs);
    if (g_out) { fclose(g_out); printf("  golden trace -> %s\n", out_path); }

    if (g_rtl) {
        fclose(g_rtl);
        printf("\n  compared against : %s  (%d inference(s), %ld lines)\n", check_path, done_runs, g_lines);
        if (done_runs == 0) { printf("  RTL trace is empty\nFAIL\n"); return 1; }
        if (g_mismatch) {
            printf("  %ld mismatched line(s)", g_mismatch);
            if (g_mismatch > MAX_REPORT) printf(" (first %d shown; one missing line shifts everything after it)", MAX_REPORT);
            printf("\nFAIL\n");
            return 1;
        }
        printf("  all lines match\nPASS\n");
    }
    return 0;
}
