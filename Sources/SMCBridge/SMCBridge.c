// SMC access through the AppleSMC user client, plus HID temperature sensors on Apple Silicon.
// Written for OneMac from the publicly documented AppleSMC structure layout.
#include "SMCBridge.h"

#include <IOKit/IOKitLib.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>
#include <CoreFoundation/CoreFoundation.h>
#include <math.h>
#include <pthread.h>
#include <string.h>

// MARK: - AppleSMC structures (layout fixed by the kernel driver, 80 bytes)

typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } SMCVersion;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimitData;
typedef struct { uint32_t dataSize; uint32_t dataType; uint8_t dataAttributes; } SMCKeyInfo;
typedef struct {
    uint32_t key;
    SMCVersion vers;
    SMCPLimitData pLimitData;
    SMCKeyInfo keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCParam;

_Static_assert(sizeof(SMCParam) == 80, "AppleSMC parameter block must be 80 bytes");

enum { kSMCUserClientHandle = 2, kSMCReadKey = 5, kSMCWriteKey = 6, kSMCGetKeyInfo = 9 };

static io_connect_t gConnection = 0;
static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;

static uint32_t fourcc(const char *key) {
    if (!key || strlen(key) != 4) return 0;
    return ((uint32_t)(uint8_t)key[0] << 24) | ((uint32_t)(uint8_t)key[1] << 16)
         | ((uint32_t)(uint8_t)key[2] << 8) | (uint32_t)(uint8_t)key[3];
}

static void typeString(uint32_t type, char out[5]) {
    out[0] = (char)(type >> 24); out[1] = (char)(type >> 16);
    out[2] = (char)(type >> 8); out[3] = (char)type; out[4] = 0;
}

/// Caller holds gLock.
static kern_return_t openLocked(void) {
    if (gConnection) return KERN_SUCCESS;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return KERN_FAILURE;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &gConnection);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS) gConnection = 0;
    return kr;
}

static kern_return_t call(SMCParam *in, SMCParam *out) {
    size_t outSize = sizeof(SMCParam);
    return IOConnectCallStructMethod(gConnection, kSMCUserClientHandle, in, sizeof(SMCParam), out, &outSize);
}

static int keyInfoLocked(uint32_t key, SMCKeyInfo *info) {
    SMCParam in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = key;
    in.data8 = kSMCGetKeyInfo;
    if (call(&in, &out) != KERN_SUCCESS || out.result != 0) return -1;
    *info = out.keyInfo;
    return 0;
}

int om_smc_read(const char *key, OMSMCValue *value) {
    uint32_t k = fourcc(key);
    if (!k || !value) return -1;
    memset(value, 0, sizeof *value);
    pthread_mutex_lock(&gLock);
    int rc = -1;
    SMCKeyInfo info;
    if (openLocked() == KERN_SUCCESS && keyInfoLocked(k, &info) == 0 && info.dataSize <= 32) {
        SMCParam in, out;
        memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
        in.key = k;
        in.keyInfo.dataSize = info.dataSize;
        in.data8 = kSMCReadKey;
        if (call(&in, &out) == KERN_SUCCESS && out.result == 0) {
            value->size = info.dataSize;
            typeString(info.dataType, value->type);
            memcpy(value->bytes, out.bytes, info.dataSize);
            rc = 0;
        }
    }
    pthread_mutex_unlock(&gLock);
    return rc;
}

int om_smc_write(const char *key, const uint8_t *bytes, uint32_t size) {
    uint32_t k = fourcc(key);
    if (!k || !bytes || size == 0 || size > 32) return -1;
    pthread_mutex_lock(&gLock);
    int rc = -1;
    SMCKeyInfo info;
    if (openLocked() == KERN_SUCCESS && keyInfoLocked(k, &info) == 0 && info.dataSize == size) {
        SMCParam in, out;
        memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
        in.key = k;
        in.data8 = kSMCWriteKey;
        in.keyInfo.dataSize = size;
        memcpy(in.bytes, bytes, size);
        kern_return_t kr = call(&in, &out);
        rc = (kr == KERN_SUCCESS && out.result == 0) ? 0 : (kr != KERN_SUCCESS ? (int)kr : (int)out.result);
    }
    pthread_mutex_unlock(&gLock);
    return rc;
}

double om_smc_value_as_double(const OMSMCValue *v) {
    if (!v || v->size == 0) return NAN;
    const uint8_t *b = v->bytes;
    if (strncmp(v->type, "flt ", 4) == 0 && v->size == 4) {
        float f; memcpy(&f, b, 4); return (double)f;          // little-endian on Apple Silicon
    }
    if (strncmp(v->type, "ui8 ", 4) == 0) return (double)b[0];
    if (strncmp(v->type, "ui16", 4) == 0 && v->size >= 2) return (double)((b[0] << 8) | b[1]);
    if (strncmp(v->type, "ui32", 4) == 0 && v->size >= 4)
        return (double)(((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3]);
    if (strncmp(v->type, "sp78", 4) == 0 && v->size >= 2) return (double)(int16_t)((b[0] << 8) | b[1]) / 256.0;
    if (strncmp(v->type, "fpe2", 4) == 0 && v->size >= 2) return (double)((b[0] << 8) | b[1]) / 4.0;
    if (strncmp(v->type, "fp88", 4) == 0 && v->size >= 2) return (double)((b[0] << 8) | b[1]) / 256.0;
    return NAN;
}

// MARK: - HID temperature sensors (IOHIDEventSystemClient, exported by IOKit)

// IOHIDEventSystemClientCopyServices / IOHIDServiceClientCopyProperty are public; the event calls
// below are exported by IOKit but undeclared in the SDK.
typedef struct __IOHIDEvent *OMHIDEvent;
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
extern OMHIDEvent IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp);
extern double IOHIDEventGetFloatValue(OMHIDEvent event, int32_t field);

enum { kOMHIDEventTypeTemperature = 15 };

static IOHIDEventSystemClientRef gHIDClient = NULL;

int om_hid_read_temperatures(OMTemperature *out, int max) {
    if (!out || max <= 0) return 0;
    pthread_mutex_lock(&gLock);
    if (!gHIDClient) {
        gHIDClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        if (gHIDClient) {
            int page = 0xff00, usage = 5;   // Apple vendor page, temperature sensor usage
            CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &page);
            CFNumberRef u = CFNumberCreate(NULL, kCFNumberIntType, &usage);
            const void *keys[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
            const void *vals[] = { p, u };
            CFDictionaryRef match = CFDictionaryCreate(NULL, keys, vals, 2,
                &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            IOHIDEventSystemClientSetMatching(gHIDClient, match);
            CFRelease(match); CFRelease(p); CFRelease(u);
        }
    }
    int count = 0;
    CFArrayRef services = gHIDClient ? IOHIDEventSystemClientCopyServices(gHIDClient) : NULL;
    if (services) {
        CFIndex n = CFArrayGetCount(services);
        for (CFIndex i = 0; i < n && count < max; i++) {
            IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
            OMHIDEvent event = IOHIDServiceClientCopyEvent(service, kOMHIDEventTypeTemperature, 0, 0);
            if (!event) continue;
            double celsius = IOHIDEventGetFloatValue(event, kOMHIDEventTypeTemperature << 16);
            CFRelease((CFTypeRef)event);
            if (!(celsius > -40 && celsius < 150)) continue;
            out[count].celsius = celsius;
            out[count].name[0] = 0;
            CFTypeRef name = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
            if (name && CFGetTypeID(name) == CFStringGetTypeID()) {
                CFStringGetCString((CFStringRef)name, out[count].name, sizeof out[count].name, kCFStringEncodingUTF8);
            }
            if (name) CFRelease(name);
            count++;
        }
        CFRelease(services);
    }
    pthread_mutex_unlock(&gLock);
    return count;
}
