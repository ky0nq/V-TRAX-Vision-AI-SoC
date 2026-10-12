/*
 * golden_wgt_path.c
 *
 * Golden reference for the current V-TRAX weight path:
 *
 *   RAM -> wgt_ld_unit -> wgt_buf -> wgt_patch_gen
 *       -> wgt_feeder -> wgt_skew -> PE columns
 *
 * This model is transaction/step accurate for data order, lane packing,
 * column masking, and wgt_skew distribution. It intentionally does not model
 * every ready/valid clock bubble. The default case assumes no stalls:
 *   i_buf_free   = 1
 *   i_step_en    = 1
 *   i_feed_valid = 1 while beats are injected
 *   downstream ready = 1
 *
 * Weight word packing follows RTL:
 *   [ 7: 0] = Col1
 *   [15: 8] = Col2
 *   [23:16] = Col3
 *
 * wgt_skew distribution follows RTL:
 *   Col1 : 0-step delay
 *   Col2 : 1-step delay
 *   Col3 : 2-step delay
 *
 * Build:
 *   gcc -O2 -Wall -Wextra -o golden_wgt_path golden_wgt_path.c
 *
 * Run:
 *   ./golden_wgt_path
 *   ./golden_wgt_path --words 8 --mask 7 --out-base golden_wgt_path
 * No --words/--mask options: run lengths 0/1/2/6/64 x all eight masks.
 * PASS covers the C data model, not RTL ready/valid or done timing.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <limits.h>

#define MAX_WORDS 64
#define DEFAULT_WORDS 6
#define DEFAULT_MASK 7
#define DEFAULT_BASE 100
#define RAM_WORDS (MAX_WORDS + DEFAULT_BASE + 64)

/* Oracle uses original scalar inputs, independently of pack24, lane helpers,
 * apply_col_mask, the loaded buffer, and the produced stream. */
static uint32_t expected_word(const uint8_t *source, int words,
                              int step, unsigned mask, int skew)
{
    uint32_t result = 0;
    uint32_t place = 1;
    int col;
    for (col = 0; col < 3; col++) {
        int index = step - (skew ? col : 0);
        if ((mask & (1u << col)) && index >= 0 && index < words)
            result += source[index * 3 + col] * place;
        place *= 256u;
    }
    return result;
}

static uint32_t pack24(uint8_t col1, uint8_t col2, uint8_t col3)
{
    return ((uint32_t)col3 << 16) |
           ((uint32_t)col2 << 8)  |
           (uint32_t)col1;
}

static uint8_t lane1(uint32_t w) { return (uint8_t)(w & 0xFFu); }
static uint8_t lane2(uint32_t w) { return (uint8_t)((w >> 8) & 0xFFu); }
static uint8_t lane3(uint32_t w) { return (uint8_t)((w >> 16) & 0xFFu); }

static uint32_t apply_col_mask(uint32_t w, unsigned mask)
{
    uint8_t c1 = (mask & 0x1u) ? lane1(w) : 0u;
    uint8_t c2 = (mask & 0x2u) ? lane2(w) : 0u;
    uint8_t c3 = (mask & 0x4u) ? lane3(w) : 0u;
    return pack24(c1, c2, c3);
}

static void print_mask(FILE *f, unsigned mask)
{
    fprintf(f, "%u%u%u",
            (mask >> 2) & 1u,
            (mask >> 1) & 1u,
            mask & 1u);
}

static int run_golden(FILE *out, int words, unsigned col_mask, unsigned mem_base)
{
    uint32_t ram[RAM_WORDS];
    uint32_t wgt_buf[MAX_WORDS];
    uint32_t stream[MAX_WORDS];
    uint8_t source[MAX_WORDS * 3] = {0};
    int skew_steps = words ? words + 2 : 0;
    int k;
    int fail = 0;

    /* wgt_skew internal registers */
    uint8_t data_d1_col2 = 0;
    uint8_t data_d1_col3 = 0;
    uint8_t data_d2_col3 = 0;

    memset(ram, 0, sizeof(ram));
    memset(wgt_buf, 0, sizeof(wgt_buf));
    memset(stream, 0, sizeof(stream));

    fprintf(out, "=== V-TRAX WGT PATH GOLDEN ===\n");
    fprintf(out, "words=%d mem_base=%u col_mask=", words, mem_base);
    print_mask(out, col_mask);
    fprintf(out, "\n\n");

    if (words == 0) {
        fprintf(out, "Empty chunk: empty data\n");
        fprintf(out, "No RAM reads, buffer writes, output beats, or skew steps.\n");
        fprintf(out, "Done pulse timing is not modeled.\n");
        fprintf(out, "\nCASE SUMMARY: load=0 beat=0 skew=0 mismatches=0\n");
        fprintf(out, "\n[RESULT] PASS\n");
        return 0;
    }

    /* ------------------------------------------------------------------
     * Test input
     *   k0 = {Col3=21, Col2=11, Col1=1}
     *   k1 = {Col3=22, Col2=12, Col1=2}
     *   ...
     * ----------------------------------------------------------------*/
    fprintf(out, "[INPUT RAM]\n");
    for (k = 0; k < words; k++) {
        uint8_t c1 = (uint8_t)(1 + k);
        uint8_t c2 = (uint8_t)(11 + k);
        uint8_t c3 = (uint8_t)(21 + k);
        source[k * 3] = c1;
        source[k * 3 + 1] = c2;
        source[k * 3 + 2] = c3;
        uint32_t w = pack24(c1, c2, c3);
        ram[mem_base + (unsigned)k] = w;

        fprintf(out,
                "RAM[%3u] = 0x%06X  {Col1=%3u, Col2=%3u, Col3=%3u}\n",
                mem_base + (unsigned)k,
                (unsigned)w,
                (unsigned)c1, (unsigned)c2, (unsigned)c3);
    }

    /* ------------------------------------------------------------------
     * wgt_ld_unit + wgt_buf
     * RTL meaning: RAM[mem_base + k] is copied to wgt_buf[k].
     * ----------------------------------------------------------------*/
    fprintf(out, "\n[RAM -> WGT_BUF]\n");
    for (k = 0; k < words; k++) {
        uint32_t exp = expected_word(source, words, k, 7u, 0);
        wgt_buf[k] = ram[mem_base + (unsigned)k];
        fprintf(out,
                "LOAD k=%2d  RAM[%3u] -> BUF[%2d]  actual=0x%06X expected=0x%06X %s\n",
                k, mem_base + (unsigned)k, k, (unsigned)wgt_buf[k],
                (unsigned)exp, wgt_buf[k] == exp ? "PASS" : "FAIL");

        if (wgt_buf[k] != exp)
            fail++;
    }

    /* ------------------------------------------------------------------
     * wgt_patch_gen + wgt_feeder
     * No-stall case: sequential wgt_buf read, same beat order at feeder.
     * ----------------------------------------------------------------*/
    fprintf(out, "\n[WGT_PATCH_GEN -> FEEDER]\n");
    for (k = 0; k < words; k++) {
        uint32_t exp = expected_word(source, words, k, col_mask, 0);
        uint32_t masked = apply_col_mask(wgt_buf[k], col_mask);
        stream[k] = masked;

        fprintf(out,
                "BEAT k=%2d  BUF[%2d]=0x%06X  OUT=0x%06X  keep=",
                k, k, (unsigned)wgt_buf[k], (unsigned)masked);
        print_mask(out, col_mask);
        fprintf(out,
                "  {Col1=%3u, Col2=%3u, Col3=%3u} expected=0x%06X %s\n",
                (unsigned)lane1(masked),
                (unsigned)lane2(masked),
                (unsigned)lane3(masked), (unsigned)exp,
                stream[k] == exp ? "PASS" : "FAIL");

        if (stream[k] != exp)
            fail++;
    }

    /* ------------------------------------------------------------------
     * wgt_skew
     * PE samples the combinational o_data BEFORE the sequential delay
     * registers advance at the step edge.
     *
     * Sample at step s:
     *   Col1 = current feeder Col1
     *   Col2 = previous step's feeder Col2
     *   Col3 = two steps ago feeder Col3
     * ----------------------------------------------------------------*/
    fprintf(out, "\n[WGT_SKEW -> PE COLUMNS]\n");
    fprintf(out, "| Step | Feeder {C1,C2,C3} | PE actual {C1,C2,C3} | Actual | Expected | Check |\n");
    fprintf(out, "|---:|:---:|:---:|:---:|:---:|:---:|\n");

    for (k = 0; k < skew_steps; k++) {
        uint32_t feed_word = (k < words) ? stream[k] : 0u;
        int feed_valid = (k < words);
        uint8_t in_c1 = feed_valid ? lane1(feed_word) : 0u;
        uint8_t in_c2 = feed_valid ? lane2(feed_word) : 0u;
        uint8_t in_c3 = feed_valid ? lane3(feed_word) : 0u;

        /* This is the value seen by PE inputs at the current step. */
        uint8_t pe_c1 = in_c1;
        uint8_t pe_c2 = data_d1_col2;
        uint8_t pe_c3 = data_d2_col3;
        uint32_t skew_word = pack24(pe_c1, pe_c2, pe_c3);

        /* Independent expected formula for self-check. */
        uint32_t exp_word = expected_word(source, words, k, col_mask, 1);

        fprintf(out,
                "| %d | {%u,%u,%u} | {%u,%u,%u} | 0x%06X | 0x%06X | %s |\n",
                k,
                (unsigned)in_c1, (unsigned)in_c2, (unsigned)in_c3,
                (unsigned)pe_c1, (unsigned)pe_c2, (unsigned)pe_c3,
                (unsigned)skew_word, (unsigned)exp_word,
                (skew_word == exp_word) ? "PASS" : "FAIL");

        if (skew_word != exp_word)
            fail++;

        /* Sequential part of wgt_skew at the step edge. */
        {
            uint8_t old_d1_col3 = data_d1_col3;
            data_d1_col2 = in_c2;
            data_d1_col3 = in_c3;
            data_d2_col3 = old_d1_col3;
        }
    }

    fprintf(out, "\n[SKEW RULE]\n");
    fprintf(out, "Col1(k) -> PE Col1 at step k\n");
    fprintf(out, "Col2(k) -> PE Col2 at step k+1\n");
    fprintf(out, "Col3(k) -> PE Col3 at step k+2\n");

    fprintf(out, "\nCASE SUMMARY: load=%d beat=%d skew=%d mismatches=%d\n",
            words, words, skew_steps, fail);
    fprintf(out, "\n[RESULT] %s\n", fail ? "FAIL" : "PASS");
    return fail ? 1 : 0;
}


/* ------------------------------------------------------------------------- */
/* GitHub Markdown report                                                    */
/* ------------------------------------------------------------------------- */
static void md_code_end(FILE *md, int *open)
{
    if (*open) {
        fprintf(md, "```\n\n");
        *open = 0;
    }
}

static int write_markdown_report(const char *txt_path, const char *md_path)
{
    FILE *in;
    FILE *md;
    char line[1024];
    int code_open = 0;
    int in_skew = 0;

    in = fopen(txt_path, "r");
    if (!in)
        return 0;

    md = fopen(md_path, "w");
    if (!md) {
        fclose(in);
        return 0;
    }

    fprintf(md, "# WGT PATH Golden Reference\n\n");
    fprintf(md, "> Generated by `golden_wgt_path.c`  \n");
    fprintf(md, "> Functional / step-level reference for weight loading, lane packing, column masking, feeder order, and skew distribution.\n\n");

    fprintf(md, "Actual = C data model; expected = original scalar inputs with an independent address/mask/delay formula.\n\n");
    fprintf(md, "RTL buffer occupancy, ready/valid stalls, step_en stops, and done pulse timing are not simulated. Step is a PE advance, not a clock number.\n\n");
    fprintf(md, "## Data Path\n\n");
    fprintf(md, "```text\n");
    fprintf(md, "RAM -> wgt_ld_unit -> wgt_buf -> wgt_patch_gen -> wgt_feeder -> wgt_skew -> PE\n");
    fprintf(md, "```\n\n");

    fprintf(md, "## Weight Packing\n\n");
    fprintf(md, "```text\n");
    fprintf(md, "24-bit word\n");
    fprintf(md, "[23:16] = Col3\n");
    fprintf(md, "[15:8]  = Col2\n");
    fprintf(md, "[ 7:0]  = Col1\n");
    fprintf(md, "```\n\n");

    fprintf(md, "## Skew Concept\n\n");
    fprintf(md, "```text\n");
    fprintf(md, "Col1 : 0-step delay\n");
    fprintf(md, "Col2 : 1-step delay\n");
    fprintf(md, "Col3 : 2-step delay\n\n");
    fprintf(md, "```\n\n");

    while (fgets(line, sizeof line, in)) {
        size_t n = strcspn(line, "\r\n");
        line[n] = '\0';

        if (!strcmp(line, "=== V-TRAX WGT PATH GOLDEN ==="))
            continue;

        if (!strncmp(line, "words=", 6)) {
            md_code_end(md, &code_open);
            fprintf(md, "## Configuration\n\n");
            fprintf(md, "```text\n%s\n```\n\n", line);
            continue;
        }

        if (!strcmp(line, "[INPUT RAM]")) {
            md_code_end(md, &code_open);
            fprintf(md, "## Input RAM\n\n```text\n");
            code_open = 1;
            continue;
        }

        if (!strcmp(line, "[RAM -> WGT_BUF]")) {
            md_code_end(md, &code_open);
            fprintf(md, "## RAM → Weight Buffer\n\n```text\n");
            code_open = 1;
            continue;
        }

        if (!strcmp(line, "[WGT_PATCH_GEN -> FEEDER]")) {
            md_code_end(md, &code_open);
            fprintf(md, "## Weight Patch Generator → Feeder\n\n```text\n");
            code_open = 1;
            continue;
        }

        if (!strcmp(line, "[WGT_SKEW -> PE COLUMNS]")) {
            md_code_end(md, &code_open);
            fprintf(md, "## Weight Skew → PE Columns\n\n");
            in_skew = 1;
            continue;
        }

        if (!strcmp(line, "[SKEW RULE]")) {
            md_code_end(md, &code_open);
            in_skew = 0;
            fprintf(md, "\n## Skew Rule\n\n```text\n");
            code_open = 1;
            continue;
        }

        if (!strncmp(line, "[SUITE RESULT]", 14)) {
            md_code_end(md, &code_open);
            in_skew = 0;
            fprintf(md, "## Suite Result\n\n**%s**\n\n", line + 15);
            continue;
        }
        if (!strncmp(line, "[RESULT]", 8)) {
            md_code_end(md, &code_open);
            in_skew = 0;
            fprintf(md, "## Result\n\n");
            if (strstr(line, "PASS"))
                fprintf(md, "**PASS**\n\n");
            else
                fprintf(md, "**FAIL**\n\n");
            continue;
        }

        if (line[0] == '\0') {
            if (code_open)
                fprintf(md, "\n");
            continue;
        }

        if (in_skew) {
            /* Copy the actual/expected/check table verbatim, including FAIL. */
            fprintf(md, "%s\n", line);
            continue;
        }

        if (!code_open) {
            fprintf(md, "```text\n");
            code_open = 1;
        }

        fprintf(md, "%s\n", line);
    }

    md_code_end(md, &code_open);

    fclose(md);
    fclose(in);
    return 1;
}

static void usage(const char *argv0)
{
    printf("usage: %s [--words 0..64] [--mask 0..7] [--base N] [--out-base NAME]\n", argv0);
    printf("Default: lengths 0/1/2/6/64 x masks 0..7; --words or --mask selects one case.\n");
}

static int parse_unsigned(const char *text, unsigned *value)
{
    char *end;
    unsigned long parsed;
    if (!text[0] || text[0] == '-') return 0;
    errno = 0;
    parsed = strtoul(text, &end, 0);
    if (errno || end == text || *end || parsed > UINT_MAX) return 0;
    *value = (unsigned)parsed;
    return 1;
}

int main(int argc, char **argv)
{
    int words = DEFAULT_WORDS;
    unsigned mask = DEFAULT_MASK;
    unsigned base = DEFAULT_BASE;
    const char *out_base = "golden_wgt_path";
    char txt_path[512];
    char md_path[512];
    FILE *out;
    int i;
    int rc = 0;
    int suite = 1;
    int cases = 0;
    int failed_cases = 0;

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--words") && i + 1 < argc) {
            unsigned parsed;
            if (!parse_unsigned(argv[++i], &parsed) || parsed > MAX_WORDS) {
                usage(argv[0]); return 2;
            }
            words = (int)parsed;
            suite = 0;
        } else if (!strcmp(argv[i], "--mask") && i + 1 < argc) {
            if (!parse_unsigned(argv[++i], &mask)) { usage(argv[0]); return 2; }
            suite = 0;
        } else if (!strcmp(argv[i], "--base") && i + 1 < argc) {
            if (!parse_unsigned(argv[++i], &base)) { usage(argv[0]); return 2; }
        } else if (!strcmp(argv[i], "--out-base") && i + 1 < argc) {
            out_base = argv[++i];
        } else {
            usage(argv[0]);
            return 2;
        }
    }

    /* Check before adding, including the largest case in the default suite. */
    if (words < 0 || words > MAX_WORDS || mask > 7u ||
        base > RAM_WORDS || (unsigned)(suite ? MAX_WORDS : words) > RAM_WORDS - base) {
        usage(argv[0]);
        return 2;
    }

    snprintf(txt_path, sizeof txt_path, "%s.txt", out_base);
    snprintf(md_path, sizeof md_path, "%s.md", out_base);

    out = fopen(txt_path, "w");
    if (!out) {
        perror("fopen");
        return 2;
    }

    if (suite) {
        static const int lengths[] = {0, 1, 2, 6, 64};
        unsigned length_idx, test_mask;
        for (length_idx = 0; length_idx < sizeof lengths / sizeof lengths[0]; length_idx++) {
            for (test_mask = 0; test_mask < 8; test_mask++) {
                failed_cases += run_golden(out, lengths[length_idx], test_mask, base);
                cases++;
            }
        }
    } else {
        failed_cases = run_golden(out, words, mask, base);
        cases = 1;
    }
    rc = failed_cases ? 1 : 0;
    fprintf(out, "\n[SUITE RESULT] %s cases=%d failed=%d\n",
            rc ? "FAIL" : "PASS", cases, failed_cases);
    fclose(out);

    if (!write_markdown_report(txt_path, md_path)) {
        printf("cannot create markdown report: %s\n", md_path);
        return 2;
    }

    printf("raw trace       -> %s\n", txt_path);
    printf("markdown report -> %s\n", md_path);
    printf("%s\n", rc == 0 ? "PASS" : "FAIL");

    return rc;
}
