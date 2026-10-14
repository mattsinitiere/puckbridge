// SIM: what the driver and the stubs share. Nothing here is firmware.
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

// sim_platform.c
void sim_advance_us(int64_t us);
uint32_t sim_now_ms(void);
bool sim_task_run(const char *name);
extern int sim_log_level;

// sim_device.c — the board half that is stubbed
typedef struct {
    bool asleep, idle_slept, force_frame, render_requested;
    uint32_t last_activity;
    void (*power_cb)(bool);
} sim_display_t;
extern sim_display_t sim_display;
extern bool sim_quiet_keepalive;   // hide the pong / hello traffic the driver itself generates
void sim_out_mark(void);
bool sim_out_since_mark_contains(const char *needle);
void sim_out_print_since_mark(void);
typedef void (*sim_frame_cb)(uint8_t version, uint8_t type, const uint8_t *payload, size_t len, void *ctx);
typedef void (*sim_tick_cb)(void *ctx);
extern sim_frame_cb sim_link_frame;
extern sim_tick_cb sim_link_tick;
extern void *sim_link_ctx;
extern bool sim_audio_active, sim_audio_recording;

// sim_cable.c — the real cable_client.c, plus access to its static entry points
void sim_cable_hello(void);
void sim_cable_inbound(const char *json, size_t len);
void sim_cable_tick(void);
void sim_cable_frame(uint8_t type, const uint8_t *data, size_t len);

// sim_app.c — the real app_main.c (boot + refresh_projects)
void sim_app_boot(void);
void sim_app_refresh_once(void);

// sim_ui.c — the real ui_habitat.c, plus read-only introspection
const char *sim_ui_view_name(void);
void sim_ui_dump_hits(void);
int sim_ui_hit_count(void);
bool sim_ui_hit(int i, int *x, int *y, int *w, int *h, const char **action, bool *enabled);
void sim_ui_dump_state(void);
