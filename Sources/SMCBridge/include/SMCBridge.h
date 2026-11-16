#ifndef ONEMAC_SMC_BRIDGE_H
#define ONEMAC_SMC_BRIDGE_H

#include <stdint.h>
#include <stdbool.h>

/// A raw SMC value: 4-char type ("flt ", "ui8 ", "sp78"...), byte count and the bytes.
typedef struct {
    char type[5];
    uint32_t size;
    uint8_t bytes[32];
} OMSMCValue;

/// Read one 4-char key. Returns 0 on success, non-zero when the key is missing or the call fails.
int om_smc_read(const char *key, OMSMCValue *out);

/// Write raw bytes to a key (size must match the key's size). Needs root on Apple Silicon.
int om_smc_write(const char *key, const uint8_t *bytes, uint32_t size);

/// Decode the numeric types fans and temperatures use: flt, ui8/16/32, sp78, fpe2, fp88.
/// Returns NAN for anything else.
double om_smc_value_as_double(const OMSMCValue *value);

/// One Apple Silicon HID temperature sensor reading.
typedef struct {
    char name[64];
    double celsius;
} OMTemperature;

/// Fill up to `max` sensors; returns the count written (0 when the HID event system is unavailable).
int om_hid_read_temperatures(OMTemperature *out, int max);

#endif
