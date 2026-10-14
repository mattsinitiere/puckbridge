/* SIM STUB: just enough FreeRTOS for ui_habitat.c / cable_client.c on a host. Single-threaded:
 * tasks are recorded, not run; queues are in-memory FIFOs; semaphores and locks are no-ops. */
#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
typedef int BaseType_t;
typedef unsigned UBaseType_t;
typedef uint32_t TickType_t;
typedef void (*TaskFunction_t)(void *);
typedef struct sim_task *TaskHandle_t;
typedef struct sim_queue *QueueHandle_t;
typedef struct sim_sem *SemaphoreHandle_t;
#define pdTRUE 1
#define pdFALSE 0
#define pdPASS 1
#define pdFAIL 0
#define portMAX_DELAY 0xffffffffu
#define pdMS_TO_TICKS(ms) ((TickType_t)(ms))
#define portTICK_PERIOD_MS 1
#define portYIELD_FROM_ISR() ((void)0)
typedef int portMUX_TYPE;
#define portMUX_INITIALIZER_UNLOCKED 0
#define portENTER_CRITICAL(m) ((void)(m))
#define portEXIT_CRITICAL(m) ((void)(m))
