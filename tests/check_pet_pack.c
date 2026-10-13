// Feeds a custom-character pack (HPET) through the puck firmware's own parser, exactly as the cable would: offer,
// 8 KB slices, finish. Then maps it to the "claude" engine and looks it up, which is what the face does.
//
//   cc -std=c11 -I <openharness>/devices/harness-device/firmware/main tests/check_pet_pack.c \
//      <fw>/main/ui/habitat/terminal.c <fw>/main/ui/habitat/fonts.c -lm -o check_pet_pack
//   ./check_pet_pack pack.hpet [more.hpet ...]
//
// pet_store.c is MIT-licensed upstream code (github.com/autonomous-ai/openharness) and is compiled from a pinned
// checkout in CI, never copied into this repo. Exit 0 = every pack would be accepted by the puck.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pet_store.c"

static int check(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) { printf("FAIL %s: can't open\n", path); return 1; }
    static uint8_t buf[PET_STORE_MAX_BYTES + 1];
    size_t n = fread(buf, 1, sizeof buf, f);
    fclose(f);
    if (n < 22 || n > PET_STORE_MAX_BYTES) { printf("FAIL %s: %zu bytes\n", path, n); return 1; }

    static const char hex[] = "0123456789abcdef";
    char id[17];
    for (int i = 0; i < 8; i++) { id[2 * i] = hex[buf[6 + i] >> 4]; id[2 * i + 1] = hex[buf[6 + i] & 15]; }
    id[16] = 0;
    uint32_t crc = (uint32_t)(buf[18] | buf[19] << 8 | buf[20] << 16 | (uint32_t)buf[21] << 24);
    if (!pet_store_offer(id, (uint32_t)n, crc)) { printf("FAIL %s: offer refused (id %s, %zu bytes)\n", path, id, n); return 1; }
    for (size_t at = 0; at < n; at += 8192) {
        size_t k = n - at < 8192 ? n - at : 8192;
        if (!pet_store_slice(buf + at, k)) { printf("FAIL %s: slice at %zu refused\n", path, at); return 1; }
    }
    int r = pet_store_finish();
    if (r != 0) {
        const char *why = r == PET_ERR_CRC ? "crc" : r == PET_ERR_VERSION ? "version" : r == PET_ERR_SHAPE ? "shape" : "?";
        printf("FAIL %s: the puck would answer pet.error {reason:\"%s\"}\n", path, why);
        return 1;
    }
    const char *engines[] = {"claude"}, *ids[] = {id};
    pet_store_map(NULL, engines, ids, 1);
    pet_store_release_frame();
    const ht_pet_t *pet = pet_store_lookup("claude");
    if (!pet) { printf("FAIL %s: stored but not found for engine claude\n", path); return 1; }
    printf("ok   %s: id %s, version %u, %zu bytes, small pet %ux%u, working scene %s, relaxing scene %s\n",
           path, id, buf[4], n, pet->w, pet->h, pet->working_scene ? "yes" : "no", pet->relaxing_scene ? "yes" : "no");
    pet_store_drop(id);
    pet_store_release_frame();
    return 0;
}

int main(int argc, char **argv)
{
    if (argc < 2) { fprintf(stderr, "usage: %s pack.hpet ...\n", argv[0]); return 2; }
    int bad = 0;
    for (int i = 1; i < argc; i++) bad += check(argv[i]);
    return bad ? 1 : 0;
}
