/*
 * SIM: the fake platform under the real firmware sources.
 *   - esp_timer_get_time(): a fake clock that only the script moves (sim_advance_us).
 *   - FreeRTOS: tasks are RECORDED, never run as threads. Queues are in-memory FIFOs. A receive on an
 *     empty queue returns pdFALSE at once, which is what lets the driver run ui_habitat.c's worker()
 *     synchronously: call it, it drains the queue and returns. Mutexes always succeed; a binary
 *     semaphore that was never given times out at once (so a blocking wait for an answer just fails).
 *   - ESP_LOG*: printf, gated by sim_log_level.
 */
#include "sim.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "esp_timer.h"
#include "esp_app_desc.h"
#include "esp_random.h"
#include "esp_system.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef SIM_FW_VERSION
#define SIM_FW_VERSION "0.0.0-sim"
#endif

int sim_log_level = 3;
static int64_t now_us = 10 * 1000000LL;   // boot + 10 s: keeps ms() away from 0, which some code treats as "never"
int64_t esp_timer_get_time(void) { return now_us; }
void sim_advance_us(int64_t us) { now_us += us; }
uint32_t sim_now_ms(void) { return (uint32_t)(now_us / 1000); }

static esp_app_desc_t desc = {.version = SIM_FW_VERSION, .project_name = "harness-sim"};
const esp_app_desc_t *esp_app_get_description(void) { return &desc; }
uint32_t esp_random(void) { static uint32_t x = 0x2545f491u; x ^= x << 13; x ^= x >> 17; x ^= x << 5; return x; }
void esp_restart(void) { printf("SIM esp_restart() called — exiting\n"); exit(3); }

// ── tasks ─────────────────────────────────────────────────────────────────────────────────────────────
struct sim_task { char name[32]; TaskFunction_t fn; void *arg; };
static struct sim_task tasks[16];
static int task_count;
static struct sim_task self_task = {.name = "sim"};
static BaseType_t create(TaskFunction_t fn, const char *name, void *arg, TaskHandle_t *out)
{
    if (task_count >= 16) return pdFAIL;
    struct sim_task *t = &tasks[task_count++];
    snprintf(t->name, sizeof t->name, "%s", name ? name : "?");
    t->fn = fn; t->arg = arg;
    if (out) *out = t;
    return pdPASS;
}
BaseType_t xTaskCreate(TaskFunction_t fn, const char *name, uint32_t stack, void *arg, UBaseType_t prio, TaskHandle_t *out)
{ (void)stack; (void)prio; return create(fn, name, arg, out); }
BaseType_t xTaskCreatePinnedToCore(TaskFunction_t fn, const char *name, uint32_t stack, void *arg, UBaseType_t prio,
                                   TaskHandle_t *out, BaseType_t core)
{ (void)stack; (void)prio; (void)core; return create(fn, name, arg, out); }
void vTaskDelete(TaskHandle_t t) { (void)t; }
void vTaskDelay(TickType_t ticks) { (void)ticks; }
uint32_t ulTaskNotifyTake(BaseType_t clear, TickType_t wait) { (void)clear; (void)wait; return 0; }
BaseType_t xTaskNotifyGive(TaskHandle_t t) { (void)t; return pdPASS; }
void vTaskNotifyGiveFromISR(TaskHandle_t t, BaseType_t *woken) { (void)t; if (woken) *woken = pdFALSE; }
TaskHandle_t xTaskGetCurrentTaskHandle(void) { return &self_task; }
UBaseType_t uxTaskGetStackHighWaterMark(TaskHandle_t t) { (void)t; return 1000; }
// Run a recorded task's function once (only for tasks written as "loop while the queue has items").
bool sim_task_run(const char *name)
{
    for (int i = 0; i < task_count; i++)
        if (!strcmp(tasks[i].name, name)) { tasks[i].fn(tasks[i].arg); return true; }
    return false;
}

// ── queues ────────────────────────────────────────────────────────────────────────────────────────────
struct sim_queue { unsigned len, size, head, count; unsigned char *buf; };
QueueHandle_t xQueueCreate(UBaseType_t length, UBaseType_t item_size)
{
    QueueHandle_t q = calloc(1, sizeof *q);
    q->len = length; q->size = item_size; q->buf = calloc(length, item_size);
    return q;
}
BaseType_t xQueueSend(QueueHandle_t q, const void *item, TickType_t wait)
{
    (void)wait;
    if (!q || q->count >= q->len) return pdFAIL;
    memcpy(q->buf + ((q->head + q->count) % q->len) * q->size, item, q->size);
    q->count++;
    return pdPASS;
}
BaseType_t xQueueReceive(QueueHandle_t q, void *item, TickType_t wait)
{
    (void)wait;
    if (!q || !q->count) return pdFALSE;
    memcpy(item, q->buf + q->head * q->size, q->size);
    q->head = (q->head + 1) % q->len;
    q->count--;
    return pdTRUE;
}
UBaseType_t uxQueueSpacesAvailable(QueueHandle_t q) { return q ? q->len - q->count : 0; }
UBaseType_t uxQueueMessagesWaiting(QueueHandle_t q) { return q ? q->count : 0; }
void vQueueDelete(QueueHandle_t q) { if (q) { free(q->buf); free(q); } }

// ── semaphores ────────────────────────────────────────────────────────────────────────────────────────
struct sim_sem { bool mutex; int count; };
static SemaphoreHandle_t sem(bool mutex) { SemaphoreHandle_t s = calloc(1, sizeof *s); s->mutex = mutex; return s; }
SemaphoreHandle_t xSemaphoreCreateMutex(void) { return sem(true); }
SemaphoreHandle_t xSemaphoreCreateRecursiveMutex(void) { return sem(true); }
SemaphoreHandle_t xSemaphoreCreateBinary(void) { return sem(false); }
BaseType_t xSemaphoreTake(SemaphoreHandle_t s, TickType_t wait)
{
    (void)wait;
    if (!s) return pdFALSE;
    if (s->mutex) return pdTRUE;
    if (s->count > 0) { s->count--; return pdTRUE; }
    return pdFALSE;   // nothing will ever give it while we "wait": a single-threaded sim times out at once
}
BaseType_t xSemaphoreGive(SemaphoreHandle_t s) { if (s && !s->mutex) s->count = 1; return pdTRUE; }
BaseType_t xSemaphoreTakeRecursive(SemaphoreHandle_t s, TickType_t wait) { return xSemaphoreTake(s, wait); }
BaseType_t xSemaphoreGiveRecursive(SemaphoreHandle_t s) { return xSemaphoreGive(s); }
BaseType_t xSemaphoreGiveFromISR(SemaphoreHandle_t s, BaseType_t *woken) { if (woken) *woken = pdFALSE; return xSemaphoreGive(s); }
void vSemaphoreDelete(SemaphoreHandle_t s) { free(s); }
