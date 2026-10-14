/*
 * SIM: the board-side functions the UI and the cable layer call, stubbed. Every stub here is either
 * (a) a faithful model of the original (display_* follows display_habitat.c's state machine exactly:
 *     asleep / idle_slept / force_frame / last_activity / power callback), or
 * (b) a recorder that prints what the hardware would have done ("OUT …" for cable frames, "AUDIO …",
 *     "BEEP", "NVS …"), or
 * (c) inert (fw_update, last_words, telemetry).
 * Nothing here makes a UI decision.
 */
#include "sim.h"
#include "esp_timer.h"
#include "esp_log.h"
#include "cable_link.h"
#include "cable_frame.h"
#include "audio_client.h"
#include "audio_capture.h"
#include "config_store.h"
#include "device_mac.h"
#include "fw_update.h"
#include "last_words.h"
#include "ram_telemetry.h"
#include "board/board.h"
#include "ptt.h"
#include "ui/display.h"
#include "runtime.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

// ── display (model of display_habitat.c's power half) ────────────────────────────────────────────────
sim_display_t sim_display;
void display_init(void) { sim_display.last_activity = sim_now_ms(); }
void display_init_ota(void) { display_init(); }
void display_lock_at(const char *who) { (void)who; }
void display_unlock(void) {}
bool display_is_asleep(void) { return sim_display.asleep; }
void display_set_power_cb(void (*cb)(bool)) { sim_display.power_cb = cb; }
void display_bump_activity(void) { sim_display.last_activity = sim_now_ms(); }
uint32_t display_idle_ms(void) { return sim_now_ms() - sim_display.last_activity; }
bool display_idle_slept(void) { return sim_display.idle_slept && sim_display.asleep; }
void display_sleep(void)
{
    if (sim_display.asleep) return;
    sim_display.asleep = true;
    sim_display.idle_slept = false;
    printf("DISPLAY sleep\n");
    if (sim_display.power_cb) sim_display.power_cb(false);
    habitat_render_notify();
}
void display_wake(void)
{
    if (!sim_display.asleep) return;
    sim_display.asleep = false;
    display_bump_activity();
    sim_display.force_frame = true;
    printf("DISPLAY wake\n");
    if (sim_display.power_cb) sim_display.power_cb(true);
    habitat_render_notify();
}
void display_set_brightness(uint8_t value) { printf("DISPLAY brightness %u/255\n", value); }
void habitat_render_notify(void) { sim_display.render_requested = true; }
void habitat_input_stamp(int64_t us) { (void)us; }

// ── the cable link: frames out are printed; frames in come from the driver through the stored callback ─
sim_frame_cb sim_link_frame;
sim_tick_cb sim_link_tick;
void *sim_link_ctx;
bool sim_quiet_keepalive;
#define OUT_LOG_MAX 256
static char *out_log[OUT_LOG_MAX];
static int out_count, out_mark;
bool cable_link_start(cable_frame_cb cb, cable_tick_cb tick, void *ctx)
{
    sim_link_frame = cb; sim_link_tick = tick; sim_link_ctx = ctx;
    return true;
}
bool cable_link_send(uint8_t type, const uint8_t *payload, size_t len)
{
    if (type != CABLE_TYPE_JSON) { printf("OUT [type 0x%02x, %zu bytes]\n", type, len); return true; }
    char *text = malloc(len + 1);
    memcpy(text, payload, len); text[len] = 0;
    bool keepalive = strstr(text, "\"t\":\"pong\"") || strstr(text, "\"t\":\"hello\"");
    if (!(sim_quiet_keepalive && keepalive)) {
        // The message name first, so a log reads like the AGENTS.md table: "OUT pb.menu.open {...}".
        const char *t = strstr(text, "\"t\":\"");
        char name[48] = "?";
        if (t) { t += 5; size_t n = strcspn(t, "\""); if (n >= sizeof name) n = sizeof name - 1; memcpy(name, t, n); name[n] = 0; }
        printf("OUT %s %s\n", name, text);
    }
    if (out_count == OUT_LOG_MAX) { free(out_log[0]); memmove(out_log, out_log + 1, sizeof(char *) * (OUT_LOG_MAX - 1)); out_count--; if (out_mark) out_mark--; }
    out_log[out_count++] = text;
    return true;
}
void sim_out_mark(void) { out_mark = out_count; }
bool sim_out_since_mark_contains(const char *needle)
{
    for (int i = out_mark; i < out_count; i++) if (strstr(out_log[i], needle)) return true;
    return false;
}
void sim_out_print_since_mark(void) { for (int i = out_mark; i < out_count; i++) printf("  sent: %s\n", out_log[i]); }
void cable_link_set_log_framing(bool on) { (void)on; }
bool cable_link_host_present(void) { return true; }
void cable_link_counters(uint32_t *c, uint32_t *d) { if (c) *c = 0; if (d) *d = 0; }
uint32_t cable_link_dropped_logs(void) { return 0; }
void cable_link_reset_decoder(void) {}

// ── voice (STUBBED: no microphone, no PCM, no voice.begin/voice.end frames) ─────────────────────────────
bool sim_audio_active, sim_audio_recording;
static char upload_id[32] = "";
static unsigned uploads;
static void audio_begin(const char *what, const char *a, const char *b)
{
    snprintf(upload_id, sizeof upload_id, "sim-upload-%u", ++uploads);
    sim_audio_active = sim_audio_recording = true;
    printf("AUDIO %s %s %s (stub: recording, uploadId %s; nothing is sent)\n", what, a ? a : "", b ? b : "", upload_id);
}
void audio_client_init(void) {}
void audio_client_start_cable(const char *agent_id, voice_cmd_t cmd)
{ audio_begin("start_cable", agent_id ? agent_id : "(overview)", cmd == VOICE_CMD_GOAL ? "goal" : cmd == VOICE_CMD_LOOP ? "loop" : ""); }
void audio_client_start_form(const char *id, unsigned revision) { (void)revision; audio_begin("start_form", id, NULL); }
void audio_client_copy_form(char *out, size_t cap, unsigned *revision) { if (cap) *out = 0; if (revision) *revision = 0; }
void audio_client_start_selection(const char *agent_id, const char *sel, unsigned revision) { (void)revision; audio_begin("start_selection", agent_id, sel); }
void audio_client_start_carry(const char *agent_id, const char *carry_id) { audio_begin("start_carry", agent_id, carry_id); }
void audio_client_copy_carry(char *out, size_t cap) { if (cap) *out = 0; }
void audio_client_copy_selection(char *out, size_t cap, unsigned *revision) { if (cap) *out = 0; if (revision) *revision = 0; }
void audio_client_stop(void) { if (sim_audio_active) printf("AUDIO stop (stub)\n"); sim_audio_active = sim_audio_recording = false; }
void audio_client_abort(void) { if (sim_audio_active) printf("AUDIO abort (stub)\n"); sim_audio_active = sim_audio_recording = false; }
bool audio_client_active(void) { return sim_audio_active; }
bool audio_client_upload_matches(const char *id) { return id && upload_id[0] && !strcmp(id, upload_id); }
void audio_client_copy_upload_id(char *out, size_t cap) { snprintf(out, cap, "%s", upload_id); }
bool audio_client_recording(void) { return sim_audio_recording; }
bool audio_client_heard_voice(void) { return sim_audio_recording; }
unsigned audio_client_input_level(void) { return sim_audio_recording ? 2 : 0; }
void audio_client_start_question(const char *id, const char *token, unsigned index) { (void)index; audio_begin("start_question", id, token); }
void audio_client_copy_question(char *out, size_t cap, unsigned *index) { if (cap) *out = 0; if (index) *index = 0; }
static bool review;
void audio_client_request_review(void) { review = true; }
bool audio_client_review_requested(void) { return review; }
void audio_client_start_draft(const char *id, unsigned revision, bool append) { (void)revision; audio_begin("start_draft", id, append ? "append" : ""); }
void audio_client_copy_draft(char *out, size_t cap, unsigned *revision, bool *append) { if (cap) *out = 0; if (revision) *revision = 0; if (append) *append = false; }
void audio_client_start_search(const char *agent_id, const char *sel, unsigned revision) { (void)revision; audio_begin("start_search", agent_id, sel); }
void audio_client_copy_search(char *out, size_t cap, unsigned *revision) { if (cap) *out = 0; if (revision) *revision = 0; }

// ── speaker (STUBBED: prints) ──────────────────────────────────────────────────────────────────────────
static bool muted = true;   // Habitat starts muted (config_store.h)
void audio_notify_init(void) {}
void audio_notify_done(void) { printf("BEEP done%s\n", muted ? " (muted)" : ""); }
bool audio_notify_set_muted(bool m) { muted = m; printf("NVS muted=%d\n", m); return true; }
bool audio_notify_is_muted(void) { return muted; }
void audio_notify_set_sound(const char *style, int volume) { printf("SOUND style=%s volume=%d\n", style ? style : "(keep)", volume); }
void audio_notify_preview(void) { printf("BEEP preview\n"); }
void audio_notify_preview_sound(const char *style, int volume)
{ printf("BEEP preview sound=%s volume=%d%s\n", style ? style : "(chosen)", volume, sim_audio_active ? " (mic open: the real one stays silent)" : ""); }
bool audio_capture_init(void) { return false; }

// ── NVS (config_store.h), in memory ───────────────────────────────────────────────────────────────────
static struct { uint8_t brightness, options, character; bool scroll, swipe, have_character; char lang[CFG_VLANG_MAX]; }
    nvs = {.brightness = 102, .lang = "en"};
void config_store_init(void) {}
uint8_t config_load_brightness(void) { return nvs.brightness; }
void config_save_brightness(uint8_t level) { nvs.brightness = level; printf("NVS brightness=%u\n", level); }
bool config_load_muted(void) { return muted; }
bool config_save_muted(bool m) { muted = m; return true; }
uint8_t config_load_habitat_options(void) { return nvs.options; }
bool config_save_habitat_options(uint8_t o) { nvs.options = o; printf("NVS habitat_options=0x%02x\n", o); return true; }
uint8_t config_load_habitat_character(uint8_t fallback) { return nvs.have_character ? nvs.character : fallback; }
bool config_save_habitat_character(uint8_t c) { nvs.character = c; nvs.have_character = true; printf("NVS character=%u\n", c); return true; }
void config_load_voicelang(char *out, size_t cap) { snprintf(out, cap, "%s", nvs.lang); }
void config_save_voicelang(const char *lang) { snprintf(nvs.lang, sizeof nvs.lang, "%s", lang ? lang : ""); printf("NVS voicelang=%s\n", nvs.lang); }
bool config_load_scroll_reversed(void) { return nvs.scroll; }
void config_save_scroll_reversed(bool r) { nvs.scroll = r; printf("NVS scroll_reversed=%d\n", r); }
bool config_load_swipe_reversed(void) { return nvs.swipe; }
void config_save_swipe_reversed(bool r) { nvs.swipe = r; }
bool config_clear_all(void) { return true; }

// ── inert ──────────────────────────────────────────────────────────────────────────────────────────────
static const board_t sim_board = {.name = "sim", .touch = TOUCH_CST9217, .touch_mirror = true, .has_pmic = true};
const board_t *board(void) { return &sim_board; }
void board_detect(void) {}
bool board_factory_reset_requested(void) { return false; }
bool device_mac_str(char *out, size_t cap) { snprintf(out, cap, "00:00:5e:00:53:01"); return true; }
bool fw_update_offer(const char *version, int size, const char *sha) { printf("FW offer %s size=%d sha=%s (stub: declined)\n", version ? version : "?", size, sha ? sha : "?"); return false; }
void fw_update_slice(const uint8_t *data, size_t len) { (void)data; (void)len; }
void fw_update_abort(const char *why) { (void)why; }
void fw_update_tick(void) {}
void fw_mark_valid(void) {}
void last_words_boot(void) {}
void last_words_report(void) {}
void ram_telemetry_init(void) {}
void ram_telemetry_checkpoint(const char *tag) { (void)tag; }
void ram_telemetry_periodic(const char *tag) { (void)tag; }
void ptt_start(void) {}   // the small button is the driver's `boot tap` / `boot hold`, modelled on ptt.c
