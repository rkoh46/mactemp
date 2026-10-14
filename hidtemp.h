/* Bridging header for TempMeter Swift app. */
#ifndef hidtemp_bridging_h
#define hidtemp_bridging_h
#ifdef __cplusplus
extern "C" {
#endif
/* Returns count of sensors (0..max_sensors) written to buffers; <0 on failure.
 * names: caller buffer of name_capacity*max_sensors bytes, one NUL-terminated
 * name (<= 63 chars) per 64-byte slot. temps: caller buffer of max_sensors doubles (Celsius). */
int hid_temp_get_sensors(char *names, int name_capacity, double *temps, int max_sensors);
#ifdef __cplusplus
}
#endif
#endif
