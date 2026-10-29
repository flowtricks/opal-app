#pragma once
#include "C1Bridge.h"
#ifdef __cplusplus
extern "C" {
#endif

typedef struct StockC1Control StockC1Control;
typedef struct {
    int32_t position;
    int32_t minimum;
    int32_t maximum;
    int32_t resolution;
    int32_t automatic;
} StockC1FocusState;

/* All calls except list may block and must be serialized away from UI/video.
 * Passive list opens no USB handle. Open uses USBDeviceOpen, never Seize, and
 * selects only the exact stock C1 serial. No runtime, resets or flash writes. */
int32_t stock_c1_list(C1Device *devices, int32_t capacity, char *error, size_t error_size);
StockC1Control *stock_c1_open(const char *serial, StockC1FocusState *state, char *error, size_t error_size);
int32_t stock_c1_read_focus(StockC1Control *control, StockC1FocusState *state, char *error, size_t error_size);
/* Reproduces verified Composer sequence: AF off, then absolute focus. Firmware
 * can clamp values, so state.position reports actual GET_CUR, not requested.
 * C1 firmware misreports AF as GET-only; this narrowly scoped quirk is based
 * on native Composer code and a successful bounded test on stock f63d. */
int32_t stock_c1_set_focus(StockC1Control *control, int32_t position, StockC1FocusState *state, char *error, size_t error_size);
int32_t stock_c1_set_auto_focus(StockC1Control *control, int32_t enabled, StockC1FocusState *state, char *error, size_t error_size);
typedef struct {
    int32_t temperature;
    /* Temperature is unreadable while this C1 is in auto mode. A zero validity
     * flag means temperature is cached metadata, never a live sensor reading. */
    int32_t temperature_valid;
    int32_t requested_temperature;
    int32_t resolution;
    int32_t temperature_info;
    int32_t automatic_info;
    int32_t minimum;
    int32_t maximum;
    int32_t automatic;
} StockC1WhiteBalanceState;
int32_t stock_c1_read_white_balance(StockC1Control *control, StockC1WhiteBalanceState *state, char *error, size_t error_size);
int32_t stock_c1_set_white_balance(StockC1Control *control, int32_t kelvin, StockC1WhiteBalanceState *state, char *error, size_t error_size);
int32_t stock_c1_set_auto_white_balance(StockC1Control *control, int32_t enabled, StockC1WhiteBalanceState *state, char *error, size_t error_size);

typedef struct {
    int32_t value; /* Physical backlight-compensation register. */
    int32_t composer_value;
    int32_t info;
    int32_t minimum;
    int32_t maximum;
    int32_t resolution;
} StockC1ExposureState;
int32_t stock_c1_read_exposure(StockC1Control *control, StockC1ExposureState *state, char *error, size_t error_size);
/* Composer truncates before this call: negative n -> -n+9; nonnegative n -> n. */
int32_t stock_c1_set_exposure(StockC1Control *control, int32_t composer_value, StockC1ExposureState *state, char *error, size_t error_size);

typedef StockC1ExposureState StockC1SaturationState;
int32_t stock_c1_read_saturation(StockC1Control *control, StockC1SaturationState *state, char *error, size_t error_size);
/* Native integer mapping from Composer -10...10 to the reported device range. */
int32_t stock_c1_set_saturation(StockC1Control *control, int32_t composer_value, StockC1SaturationState *state, char *error, size_t error_size);

/* Closing only releases our handle; it does not change focus/capture state. */
void stock_c1_close(StockC1Control *control);
#ifdef __cplusplus
}
#endif
