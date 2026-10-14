/*
 * SIM: the REAL cable_client.c, compiled into this translation unit so the driver can reach its static
 * entry points without editing it: on_frame() is the reader's callback (cable_json_guard + cJSON parse +
 * handle_message, exactly the device path) and send_hello() is the greeting the session task sends.
 */
#include "cable_client.c"
#include "sim.h"

void sim_cable_hello(void) { send_hello(); }
void sim_cable_inbound(const char *json, size_t len)
{
    on_frame(CABLE_FRAME_VERSION, CABLE_TYPE_JSON, (const uint8_t *)json, len, NULL);
}
void sim_cable_tick(void) { session_tick(NULL); }
void sim_cable_frame(uint8_t type, const uint8_t *data, size_t len) { on_frame(CABLE_FRAME_VERSION, type, data, len, NULL); }
