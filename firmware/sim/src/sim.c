/*
 * sim — drive the REAL Habitat UI (ui_habitat.c), cable layer (cable_client.c) and boot/refresh
 * (app_main.c) on a host, from a script, and render the real scenes with the real rasteriser to PNG.
 *
 *   sim [script]        (stdin when omitted)
 *
 * What runs where (the device's tasks, single-threaded here):
 *   - "render task": render_iteration() below mirrors display_habitat.c render_task(): habitat_tick(),
 *     habitat_scene_take(), habitat_scene_receipt()/presented(), and the panel's idle-off with
 *     habitat_idle_off_ms(300000). The panel's power state machine is in sim_device.c.
 *   - "habitat_actions" (ui_habitat.c worker()): run synchronously after every step; it drains its queue.
 *   - "proj_refresh" (app_main.c refresh_task()): its loop body after every step (sim_app.c).
 *   - "habitat_touch" (touch_habitat.c task()): touch_sample() mirrors its trusted-sample path,
 *     including the wake-and-swallow of a contact that lands on a dark panel. Samples every 4 ms while
 *     down, like the real poll.
 *   - "ptt" (ptt.c): `boot tap` / `boot hold` mirror its press/hold/release logic at its 100 ms poll.
 *   - "cable reader": `in {json}` goes through cable_client.c's on_frame() (guard + cJSON + dispatch).
 *     session_tick() runs after every time step (it drops the session after 15 s of silence; use
 *     `autoping 1` to have the driver send the daemon's 10 s ping for you).
 *
 * Commands (one per line, '#' starts a comment):
 *   time +MS | time MS         advance the fake clock by MS, running ticks/renders on the way
 *   in {json}                  inbound cable JSON frame
 *   hello                      make the dial send its hello (session task)
 *   touch down X Y | touch move X Y | touch up [X Y]
 *   tap X Y [MS]               down, held MS (default 60, sampled every 4 ms), up
 *   swipe X1 Y1 X2 Y2 MS       down, linear moves every 4 ms, up
 *   boot tap | boot hold       the small button (ptt.c)
 *   pwr                        the PWR key tap: screen toggle
 *   connected 1|0              ui_set_connected() directly (normally welcome / session down do it)
 *   autoping 1|0               send {"t":"ping"} every 10 s of sim time (pong/hello lines hidden)
 *   shot FILE.png [hits]       rasterise the last scene built; `hits` outlines the hit rects
 *   view | hits | state        print the view / the hit rects of the last scene / UI + pb state
 *   mark                       start a new window for `expect out`
 *   expect view NAME           check the view (prints PASS/FAIL; any FAIL makes the exit status 1)
 *   expect out TEXT            check an outbound frame containing TEXT was sent since the last mark
 *   expect noout TEXT          ...and that none was
 *   expect bad N               the cable layer has rejected N frames so far (JSON guard, parse, bad `t`)
 *   touchmap none | mirror | offset DX DY   distort every touch sample (to test controller hypotheses)
 *   log N                      0 none .. 4 debug (ESP_LOG*)
 *   petpack FILE ENGINE        upload a custom pet pack (pet.offer + 0x05 frames) and map it to ENGINE
 *   include FILE               run another script's lines here (paths are relative to the working directory)
 *   echo TEXT
 */
#include "sim.h"
#include "runtime.h"
#include "illustrated.h"
#include "ui_screens.h"
#include "ui/display.h"
#include "cable_client.h"
void cable_client_counters(uint32_t *bad, uint32_t *unknown);
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

// ── the render task ───────────────────────────────────────────────────────────────────────────────────
static ht_scene_t scenes[2];
static int front;
static bool painted, any_scene;
static uint32_t wake_ms = 1000;
static unsigned frames;

static void render_iteration(void)
{
    sim_display.render_requested = false;
    display_lock();
    habitat_tick();
    bool fresh = habitat_scene_take(&scenes[front ^ 1]);
    // A scene holds HT_RUNS runs and drops what doesn't fit, silently on the device: a full one fails the test.
    if (fresh && scenes[front ^ 1].count >= HT_RUNS) printf("FAIL scene full (%d runs): the rest of this screen was not drawn\n", scenes[front ^ 1].count);
    uint32_t receipt = habitat_scene_receipt();
    wake_ms = habitat_next_wake_ms();
    uint32_t idle_off_ms = habitat_idle_off_ms(300000);
    display_unlock();
    bool on = !display_is_asleep();
    bool force = on && sim_display.force_frame;
    if (on) sim_display.force_frame = false;
    if (on && (fresh || force)) {
        if (!fresh) scenes[front ^ 1] = scenes[front];
        ht_illustrated_prepare(&scenes[front ^ 1]);
        front ^= 1;
        painted = any_scene = true;
        frames++;
        if (receipt) habitat_scene_presented(receipt);
    }
    if (!on && fresh) {
        front ^= 1;
        painted = false;
        any_scene = true;
    }
    if (on && display_idle_ms() > idle_off_ms) {
        display_lock();
        if (display_idle_ms() > habitat_idle_off_ms(300000)) {
            display_sleep();
            sim_display.idle_slept = true;
            printf("DISPLAY (idle timer: off after %u ms)\n", (unsigned)display_idle_ms());
        }
        display_unlock();
    }
}

// Let every task catch up on what the last event did: actions, the roster, and the frame.
static void settle(void)
{
    for (int round = 0; round < 8; round++) {
        sim_task_run("habitat_actions");
        sim_app_refresh_once();
        render_iteration();
        if (!sim_display.render_requested) break;
    }
}

static bool autoping;
static uint32_t next_ping;
static void ping_if_due(void)
{
    if (!autoping) return;
    if ((int32_t)(sim_now_ms() - next_ping) < 0) return;
    next_ping = sim_now_ms() + 10000;
    static const char ping[] = "{\"t\":\"ping\"}";
    sim_cable_inbound(ping, sizeof ping - 1);
}

// Advance the clock, waking the render task as often as it asked to be woken (capped at 1 s as it is).
static void advance(uint32_t ms)
{
    while (ms) {
        uint32_t step = wake_ms ? wake_ms : 1;
        if (step > 1000) step = 1000;
        if (step > ms) step = ms;
        sim_advance_us((int64_t)step * 1000);
        ms -= step;
        ping_if_due();
        sim_cable_tick();
        settle();
    }
}

// ── the touch task (touch_habitat.c, trusted samples) ───────────────────────────────────────────────────
static struct { bool prev, swallow; int x, y; } touch;
static int last_tap_x = -1, last_tap_y = -1;
// `touchmap`: a hypothetical controller mapping applied to every sample before the firmware sees it
// (what a mis-detected board, a missing 180-degree mirror or an offset panel would deliver). Default none.
static struct { bool mirror; int dx, dy; } touchmap;
static void touch_sample(bool down, int x, int y)
{
    if (down) {
        if (touchmap.mirror) { x = HT_WIDTH - 1 - x; y = HT_HEIGHT - 1 - y; }
        x += touchmap.dx; y += touchmap.dy;
        x = x < 0 ? 0 : x >= HT_WIDTH ? HT_WIDTH - 1 : x;
        y = y < 0 ? 0 : y >= HT_HEIGHT ? HT_HEIGHT - 1 : y;
        if (!touch.prev && (touchmap.mirror || touchmap.dx || touchmap.dy))
            printf("TOUCH (touchmap) the firmware sees %d,%d\n", x, y);
        touch.x = x; touch.y = y; last_tap_x = x; last_tap_y = y;
    }
    else { x = touch.x; y = touch.y; }   // a release reports the last good coordinate
    uint32_t now = sim_now_ms();
    if (down && !touch.prev) {
        if (display_is_asleep()) {
            display_lock();
            habitat_touch_cancel();
            display_wake();
            display_unlock();
            touch.swallow = true;
            printf("TOUCH down %d,%d on a dark panel: woke it, contact swallowed (touch_habitat.c)\n", x, y);
        } else
            habitat_input_stamp((int64_t)now * 1000);
    }
    if (down) display_bump_activity();
    if (!touch.swallow && (down || touch.prev)) {
        display_lock();
        if (display_is_asleep()) {
            habitat_touch_cancel();
            touch.swallow = true;
        } else
            habitat_touch(down, x, y, now);
        display_unlock();
    }
    if (!down) touch.swallow = false;
    touch.prev = down;
    settle();
}
static void hold_for(int ms, int x, int y)
{
    for (int t = 4; t <= ms; t += 4) { advance(4); touch_sample(true, x, y); }
}

// ── the small button and PWR (ptt.c) ─────────────────────────────────────────────────────────────────
static void screen_toggle(const char *why)
{
    display_lock();
    if (display_is_asleep()) { printf("PTT %s -> screen ON\n", why); display_wake(); }
    else { printf("PTT %s -> screen OFF\n", why); display_sleep(); }
    display_unlock();
    settle();
}
static void boot_button(bool hold)
{
    if (display_is_asleep()) { display_lock(); display_wake(); display_unlock(); }
    settle();
    if (!hold) {
        advance(100);
        printf("PTT BOOT tap -> clock\n");
        ui_boot_tapped();
    } else {
        advance(800);
        if (ui_boot_held()) printf("PTT BOOT hold -> stop turn?\n");
        else screen_toggle("BOOT hold");
        advance(100);
    }
    settle();
}

// ── PNG ─────────────────────────────────────────────────────────────────────────────────────────────
static void be32(unsigned char *p, uint32_t v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; }
static void chunk(FILE *f, const char *type, const unsigned char *data, uint32_t len)
{
    unsigned char hdr[8];
    be32(hdr, len); memcpy(hdr + 4, type, 4);
    fwrite(hdr, 1, 8, f);
    if (len) fwrite(data, 1, len, f);
    uint32_t crc = crc32(0, (const unsigned char *)type, 4);
    if (len) crc = crc32(crc, data, len);
    unsigned char c[4]; be32(c, crc); fwrite(c, 1, 4, f);
}
static bool write_png(const char *path, const unsigned char *rgb, int w, int h)
{
    size_t raw_len = (size_t)(w * 3 + 1) * h;
    unsigned char *raw = malloc(raw_len);
    for (int y = 0; y < h; y++) {
        raw[y * (w * 3 + 1)] = 0;
        memcpy(raw + y * (w * 3 + 1) + 1, rgb + (size_t)y * w * 3, (size_t)w * 3);
    }
    uLongf z_len = compressBound(raw_len);
    unsigned char *z = malloc(z_len);
    if (compress2(z, &z_len, raw, raw_len, 9) != Z_OK) { free(raw); free(z); return false; }
    FILE *f = fopen(path, "wb");
    if (!f) { free(raw); free(z); return false; }
    static const unsigned char sig[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'};
    fwrite(sig, 1, 8, f);
    unsigned char ihdr[13];
    be32(ihdr, w); be32(ihdr + 4, h); ihdr[8] = 8; ihdr[9] = 2; ihdr[10] = ihdr[11] = ihdr[12] = 0;
    chunk(f, "IHDR", ihdr, 13);
    chunk(f, "IDAT", z, (uint32_t)z_len);
    chunk(f, "IEND", NULL, 0);
    fclose(f);
    free(raw); free(z);
    return true;
}
static void put(unsigned char *rgb, int x, int y, unsigned c)
{
    if (x < 0 || y < 0 || x >= HT_WIDTH || y >= HT_HEIGHT) return;
    unsigned char *p = rgb + ((size_t)y * HT_WIDTH + x) * 3;
    p[0] = c >> 16; p[1] = c >> 8; p[2] = c;
}
static void shot(const char *path, bool hits)
{
    if (!any_scene) { printf("SHOT %s: no scene has been built yet\n", path); return; }
    static uint16_t px[HT_WIDTH * HT_HEIGHT];
    static unsigned char rgb[HT_WIDTH * HT_HEIGHT * 3];
    ht_raster(&scenes[front], (ht_rect_t){0, 0, HT_WIDTH, HT_HEIGHT}, px);
    for (int y = 0; y < HT_HEIGHT; y++)
        for (int x = 0; x < HT_WIDTH; x++) {
            uint16_t v = px[y * HT_WIDTH + x];
            v = (uint16_t)((v << 8) | (v >> 8));   // the rasteriser writes panel byte order (terminal.c panel16)
            unsigned r = (v >> 11) & 31, g = (v >> 5) & 63, b = v & 31;
            unsigned c = ((r * 255 + 15) / 31) << 16 | ((g * 255 + 31) / 63) << 8 | ((b * 255 + 15) / 31);
            int dx = 2 * x + 1 - HT_WIDTH, dy = 2 * y + 1 - HT_HEIGHT;   // the round glass, r = 233
            if (dx * dx + dy * dy > HT_WIDTH * HT_WIDTH) c = 0x202020;
            put(rgb, x, y, c);
        }
    if (hits) {
        for (int i = 0; i < sim_ui_hit_count(); i++) {
            int x, y, w, h; const char *a; bool en;
            sim_ui_hit(i, &x, &y, &w, &h, &a, &en);
            unsigned c = en ? 0xff00ff : 0x808000;
            for (int k = x; k < x + w; k++) { put(rgb, k, y, c); put(rgb, k, y + h - 1, c); }
            for (int k = y; k < y + h; k++) { put(rgb, x, k, c); put(rgb, x + w - 1, k, c); }
        }
        if (last_tap_x >= 0)
            for (int k = -8; k <= 8; k++) { put(rgb, last_tap_x + k, last_tap_y, 0x00ffff); put(rgb, last_tap_x, last_tap_y + k, 0x00ffff); }
    }
    if (write_png(path, rgb, HT_WIDTH, HT_HEIGHT))
        printf("SHOT %s view=%s%s%s\n", path, sim_ui_view_name(), display_is_asleep() ? " (panel is OFF: this is the scene it holds)" : "",
               hits ? " +hits" : "");
    else printf("SHOT %s: write failed\n", path);
}

// ── the script ────────────────────────────────────────────────────────────────────────────────────────
static int failures;
static void verdict(bool ok, const char *what)
{
    printf("%s %s\n", ok ? "PASS" : "FAIL", what);
    if (!ok) failures++;
}
static char *skip(char *p) { while (*p && isspace((unsigned char)*p)) p++; return p; }

static void run_line(char *line);
static void run_line(char *line)
{
    char *p = skip(line);
    size_t n = strlen(p);
    while (n && isspace((unsigned char)p[n - 1])) p[--n] = 0;
    if (!*p || *p == '#') return;
    printf("> %s\n", p);
    char cmd[32] = "";
    int used = 0;
    sscanf(p, "%31s %n", cmd, &used);
    char *rest = p + used;
    int a, b, c, d, e;
    if (!strcmp(cmd, "time")) {
        long ms = strtol(*rest == '+' ? rest + 1 : rest, NULL, 10);
        if (ms > 0) advance((uint32_t)ms);
    } else if (!strcmp(cmd, "in")) {
        sim_cable_inbound(rest, strlen(rest));
        settle();
    } else if (!strcmp(cmd, "hello")) {
        bool q = sim_quiet_keepalive; sim_quiet_keepalive = false;
        sim_cable_hello();
        sim_quiet_keepalive = q;
    } else if (!strcmp(cmd, "touch")) {
        char what[8] = "";
        int got = sscanf(rest, "%7s %d %d", what, &a, &b);
        if (!strcmp(what, "down") && got == 3) touch_sample(true, a, b);
        else if (!strcmp(what, "move") && got == 3) { advance(4); touch_sample(true, a, b); }
        else if (!strcmp(what, "up")) { if (got == 3) { touch.x = a; touch.y = b; } advance(4); touch_sample(false, 0, 0); }
        else printf("? touch down|move|up X Y\n");
    } else if (!strcmp(cmd, "tap")) {
        int got = sscanf(rest, "%d %d %d", &a, &b, &c);
        if (got < 2) { printf("? tap X Y [MS]\n"); return; }
        touch_sample(true, a, b);
        hold_for(got == 3 ? c : 60, a, b);
        advance(4);
        touch_sample(false, a, b);
    } else if (!strcmp(cmd, "swipe")) {
        if (sscanf(rest, "%d %d %d %d %d", &a, &b, &c, &d, &e) != 5) { printf("? swipe X1 Y1 X2 Y2 MS\n"); return; }
        touch_sample(true, a, b);
        for (int t = 4; t <= e; t += 4) { advance(4); touch_sample(true, a + (c - a) * t / e, b + (d - b) * t / e); }
        advance(4);
        touch_sample(false, c, d);
    } else if (!strcmp(cmd, "boot")) {
        boot_button(strstr(rest, "hold") != NULL);
    } else if (!strcmp(cmd, "pwr")) {
        screen_toggle("PWR tap");
    } else if (!strcmp(cmd, "connected")) {
        ui_set_connected(atoi(rest) != 0);
        settle();
    } else if (!strcmp(cmd, "autoping")) {
        autoping = atoi(rest) != 0;
        sim_quiet_keepalive = autoping;
        next_ping = sim_now_ms() + 10000;
    } else if (!strcmp(cmd, "shot")) {
        char path[256] = "", opt[16] = "";
        sscanf(rest, "%255s %15s", path, opt);
        shot(path, !strcmp(opt, "hits"));
    } else if (!strcmp(cmd, "view")) {
        printf("VIEW %s\n", sim_ui_view_name());
    } else if (!strcmp(cmd, "hits")) {
        sim_ui_dump_hits();
    } else if (!strcmp(cmd, "state")) {
        sim_ui_dump_state();
        printf("STATE display asleep=%d idle_slept=%d idle_ms=%u now_ms=%u frames=%u\n", sim_display.asleep,
               sim_display.idle_slept, (unsigned)display_idle_ms(), (unsigned)sim_now_ms(), frames);
    } else if (!strcmp(cmd, "mark")) {
        sim_out_mark();
    } else if (!strcmp(cmd, "expect")) {
        char what[8] = "";
        int k = 0;
        sscanf(rest, "%7s %n", what, &k);
        char *arg = rest + k, msg[300];
        if (!strcmp(what, "view")) {
            snprintf(msg, sizeof msg, "view is %s (expected %s)", sim_ui_view_name(), arg);
            verdict(!strcmp(sim_ui_view_name(), arg), msg);
        } else if (!strcmp(what, "out")) {
            snprintf(msg, sizeof msg, "sent a frame containing %s", arg);
            verdict(sim_out_since_mark_contains(arg), msg);
        } else if (!strcmp(what, "bad")) {
            uint32_t bad = 0, unknown = 0;
            cable_client_counters(&bad, &unknown);
            snprintf(msg, sizeof msg, "frames rejected by the cable layer: %u (expected %s)", (unsigned)bad, arg);
            verdict(bad == (uint32_t)atoi(arg), msg);
        } else if (!strcmp(what, "noout")) {
            snprintf(msg, sizeof msg, "sent no frame containing %s", arg);
            verdict(!sim_out_since_mark_contains(arg), msg);
        } else printf("? expect view|out|noout ...\n");
    } else if (!strcmp(cmd, "touchmap")) {
        char how[16] = "";
        int got = sscanf(rest, "%15s %d %d", how, &a, &b);
        if (!strcmp(how, "mirror")) touchmap.mirror = true;
        else if (!strcmp(how, "offset") && got == 3) { touchmap.dx = a; touchmap.dy = b; }
        else if (!strcmp(how, "none")) { touchmap.mirror = false; touchmap.dx = touchmap.dy = 0; }
        else printf("? touchmap none|mirror|offset DX DY\n");
    } else if (!strcmp(cmd, "log")) {
        sim_log_level = atoi(rest);
    } else if (!strcmp(cmd, "petpack")) {
        // A custom pet through the real path: pet.offer, the pack as type-0x05 frames, then pet.map {engine: id}.
        char path[256] = "", id[17] = "", engine[16] = "";
        if (sscanf(rest, "%255s %15s", path, engine) != 2) { printf("? petpack FILE ENGINE\n"); return; }
        FILE *pf = fopen(path, "rb");
        if (!pf) { printf("? petpack: cannot open %s\n", path); failures++; return; }
        static uint8_t pack[1 << 20];
        size_t len = fread(pack, 1, sizeof pack, pf);
        fclose(pf);
        for (int i = 0; len > 22 && i < 8; i++) snprintf(id + i * 2, 3, "%02x", pack[6 + i]);   // the pack's own id
        uint32_t crc = len > 22 ? (uint32_t)(pack[18] | pack[19] << 8 | pack[20] << 16 | (uint32_t)pack[21] << 24) : 0;
        char json[256];
        int n = snprintf(json, sizeof json, "{\"t\":\"pet.offer\",\"id\":\"%s\",\"size\":%zu,\"crc\":%u}", id, len, (unsigned)crc);
        sim_cable_inbound(json, (size_t)n);
        for (size_t at = 0; at < len; at += 8192) sim_cable_frame(0x05, pack + at, len - at < 8192 ? len - at : 8192);
        n = snprintf(json, sizeof json, "{\"t\":\"pet.map\",\"all\":null,\"engines\":{\"%s\":\"%s\"}}", engine, id);
        sim_cable_inbound(json, (size_t)n);
        settle();
    } else if (!strcmp(cmd, "include")) {
        FILE *inc = fopen(rest, "r");
        if (!inc) { printf("? include: cannot open %s\n", rest); failures++; return; }
        char sub[16384];
        while (fgets(sub, sizeof sub, inc)) run_line(sub);
        fclose(inc);
    } else if (!strcmp(cmd, "echo")) {
        printf("%s\n", rest);
    } else {
        printf("? unknown command '%s'\n", cmd);
    }
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    FILE *in = stdin;
    if (argc > 1 && !(in = fopen(argv[1], "r"))) { perror(argv[1]); return 2; }
    printf("SIM boot (app_main.c)\n");
    sim_app_boot();
    settle();
    printf("SIM ready: view=%s\n", sim_ui_view_name());
    char line[16384];
    while (fgets(line, sizeof line, in)) run_line(line);
    printf("SIM end: view=%s, %d failure(s)\n", sim_ui_view_name(), failures);
    return failures ? 1 : 0;
}
