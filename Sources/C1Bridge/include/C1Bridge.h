#pragma once
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct C1Session C1Session;
typedef struct {
    char identifier[64];
    char name[64];
    uint16_t product_id;
} C1Device;

typedef struct {
    int32_t width;  /* 1280, 1920 or 3840; height must be 9/16 width */
    int32_t height;
    int32_t fps;    /* 1..30 */
} C1Configuration;

typedef struct {
    int32_t manual_focus;
    int32_t lens_position; /* 0..255, optical position, not meters */
    int32_t manual_exposure;
    int32_t exposure_us;   /* 1..1000000/fps */
    int32_t iso;           /* 100..1600 */
    int32_t exposure_compensation; /* -9..9 */
    int32_t exposure_lock;
    int32_t manual_white_balance;
    int32_t white_balance_kelvin;  /* 1000..12000 */
    int32_t white_balance_lock;
    int32_t antibanding;   /* 0 off, 1 50Hz, 2 60Hz, 3 auto */
    int32_t sharpness;     /* 0..4 */
    int32_t luma_denoise;  /* 0..4 */
    int32_t chroma_denoise;/* 0..4 */
} C1Controls;

typedef struct {
    const uint8_t *y;
    const uint8_t *uv;
    size_t y_stride;
    size_t uv_stride;
    int32_t width;
    int32_t height;
    uint64_t host_time_ns;
    int32_t exposure_us;
    int32_t iso;
    int32_t lens_position;
    int32_t white_balance_kelvin;
} C1Frame;

/* Callbacks run on worker threads. Frame and string pointers expire on return.
 * Copy NV12 bytes before returning; do not call close from either callback. */
typedef void (*C1FrameCallback)(const C1Frame *frame, void *context);
typedef void (*C1StatusCallback)(const char *message, int32_t is_error, void *context);

/* Passive IORegistry enumeration; opens no USB handles. Returns total written (<=capacity), -1 on error. */
int32_t c1_list_devices(C1Device *devices, int32_t capacity, char *error, size_t error_size);
C1Controls c1_default_controls(void);

/* Explicitly takes over the selected C1, rebooting it into a RAM-only DepthAI
 * runtime. Stock UVC/microphone may disappear until close/power-cycle. No flash
 * write is requested. Blocks; run off the UI thread. Never selects an arbitrary
 * fallback device. Requires the exact identifier obtained from enumeration. */
C1Session *c1_open(const char *identifier, C1Configuration configuration,
                   C1Controls initial_controls, C1FrameCallback frames,
                   C1StatusCallback status, void *context,
                   char *error, size_t error_size);

/* Returns 1 on success, 0 on failure. Changed controls only are transmitted. */
int32_t c1_set_controls(C1Session *session, C1Controls controls, char *error, size_t error_size);
int32_t c1_trigger_autofocus(C1Session *session, char *error, size_t error_size);

/* Stop callbacks, release queues/device. SDK close reboots to stock firmware.
 * Blocks and must run off the UI thread; serialize lifetime with control calls.
 * Caller must not access a session after close starts. */
void c1_close(C1Session *session);

#ifdef __cplusplus
}
#endif
