#pragma once
#include <stdio.h>
/* SIM STUB: ESP_LOG* -> stdout, prefixed so the driver's own lines stay distinguishable. */
extern int sim_log_level;   /* 0 none, 1 E, 2 W, 3 I, 4 D */
#define SIM_LOG(lvl, ch, tag, fmt, ...) do { if (sim_log_level >= (lvl)) \
    printf("LOG %c %s: " fmt "\n", ch, tag, ##__VA_ARGS__); } while (0)
#define ESP_LOGE(tag, fmt, ...) SIM_LOG(1, 'E', tag, fmt, ##__VA_ARGS__)
#define ESP_LOGW(tag, fmt, ...) SIM_LOG(2, 'W', tag, fmt, ##__VA_ARGS__)
#define ESP_LOGI(tag, fmt, ...) SIM_LOG(3, 'I', tag, fmt, ##__VA_ARGS__)
#define ESP_LOGD(tag, fmt, ...) SIM_LOG(4, 'D', tag, fmt, ##__VA_ARGS__)
#define ESP_LOGV(tag, fmt, ...) ((void)0)
