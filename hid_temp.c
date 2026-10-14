/* hid_temp.c — read Apple vendor-page temperature sensors (page 0xff00, usage 5)
 * via IOHIDEventSystemClient. Exact call sequence from vladkens/macmon.
 *
 * Build as:
 *   - shared library  : clang -dynamiclib -o libhidtemp.dylib hid_temp.c -framework IOKit -framework CoreFoundation
 *   - standalone test : clang -o hid_temp hid_temp.c -framework IOKit -framework CoreFoundation -DSTANDALONE
 *
 * Public entry (C, linkable from Swift):
 *   // Returns count of sensors written into the buffers; <=0 on failure.
 *   int hid_temp_get_sensors(char *names, int name_capacity, double *temps, int max_sensors);
 *   // names: caller buffer holding name_capacity*NUL-terminated chars
 *   // temps: caller buffer of max_sensors doubles (Celsius)
 *   // Each sensor i writes names[i*cap] (capped) and temps[i].
 */
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>

typedef struct __IOHIDEvent *IOHIDEventRef;

/* Private IOKit HID declarations (stable; used by macmon + Stats) */
kern_return_t IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef matching);
IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t event_type, uint32_t event_options, int64_t timestamp);
double IOHIDEventGetFloatValue(IOHIDEventRef event, int64_t type_and_range);
enum { kIOHIDEventTypeTemperature = 15 };

/* macmon's exact sequence: Create (not CreateSimpleClient) + SetMatching + CopyServices + CopyEvent */
IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(const void *allocator);

#define NAME_SLOT 64
int hid_temp_get_sensors(char *names, int name_capacity, double *temps, int max_sensors) {
    if (name_capacity < NAME_SLOT || max_sensors <= 0 || !names || !temps) return -1;

    CFMutableDictionaryRef match = CFDictionaryCreateMutable(kCFAllocatorDefault, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    int pageVal = 0xff00;
    CFNumberRef page = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &pageVal);
    CFDictionarySetValue(match, CFSTR("PrimaryUsagePage"), page);
    CFRelease(page);
    /* NOTE: match on page only (0xff00), NOT usage=5 — the NVMe "NAND CH0 temp"
     * sensor does not report usage 5, so a page+usage match would miss it.
     * Caller classifies sensors by name. */

    IOHIDEventSystemClientRef sys = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!sys) { CFRelease(match); return -1; }
    IOHIDEventSystemClientSetMatching(sys, match);
    CFArrayRef services = IOHIDEventSystemClientCopyServices(sys);
    if (!services) { CFRelease(sys); CFRelease(match); return 0; }

    CFIndex n = CFArrayGetCount(services);
    int count = 0;
    for (CFIndex i = 0; i < n && count < max_sensors; i++) {
        IOHIDServiceClientRef svc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        IOHIDEventRef ev = IOHIDServiceClientCopyEvent(svc, kIOHIDEventTypeTemperature, 0, 0);
        if (!ev) continue;
        double val = IOHIDEventGetFloatValue(ev, ((int64_t)kIOHIDEventTypeTemperature) << 16);
        CFRelease(ev);
        if (val <= 0.0 || val > 150.0) continue;   // skip sensors that don't deliver

        char name[NAME_SLOT] = "sensor";
        CFTypeRef p = IOHIDServiceClientCopyProperty(svc, CFSTR("Product"));
        if (p && CFGetTypeID(p) == CFStringGetTypeID() &&
            CFStringGetCString((CFStringRef)p, name, NAME_SLOT, kCFStringEncodingUTF8)) {
            if (p) CFRelease(p);
        } else if (p) { CFRelease(p); }

        int slot = count * name_capacity;
        memcpy(names + slot, name, NAME_SLOT);
        temps[count] = val;
        count++;
    }
    CFRelease(services);
    CFRelease(sys);
    CFRelease(match);
    return count;
}

#ifdef STANDALONE
int main(void) {
    char names[16 * NAME_SLOT];
    double temps[16];
    int n = hid_temp_get_sensors(names, NAME_SLOT, temps, 16);
    if (n <= 0) { printf("no temperature sensors delivered values\n"); return n < 0 ? 1 : 0; }
    for (int i = 0; i < n; i++) printf("%-24s %.1f C\n", names + i * NAME_SLOT, temps[i]);
    return 0;
}
#endif
