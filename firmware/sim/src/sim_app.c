/*
 * SIM: the REAL app_main.c in this translation unit — its boot order (display_init, ui_init,
 * ui_enter_boot_loading, cable_client_start, …) and refresh_projects(), the reconcile that turns the
 * cable's agent list into tiles. refresh_task() itself is an endless loop, so its body is repeated here.
 */
#define app_main sim_app_main_impl
#include "app_main.c"
#undef app_main
#include "sim.h"

void sim_app_boot(void) { sim_app_main_impl(); }
void sim_app_refresh_once(void)
{
    // refresh_task's loop body, minus the 1 s wait (the driver calls this after every step).
    ui_service_model_picker();
    ui_tick_machine_select();
    if (ui_peek_agent_reload_req() && !audio_client_active() && ui_take_agent_reload_req()) refresh_projects();
    ui_prune_stale_busy();
}
