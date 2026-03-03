// edid_check.m - Display current EDID and mode status for external displays
// Build: clang -fmodules -framework Foundation -framework CoreGraphics -framework IOKit -o edid_check edid_check.m
@import Foundation;
@import CoreGraphics;
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>

typedef CFTypeRef IOAVServiceRef;
typedef IOAVServiceRef (*CreateFunc)(CFAllocatorRef, io_service_t);
typedef IOReturn (*CopyEDIDFunc)(IOAVServiceRef, CFDataRef *);
typedef CGError (*SLSGetNumberOfDisplayModesFunc)(CGDirectDisplayID, int *);
typedef CGError (*SLSGetDisplayModeDescriptionOfLengthFunc)(CGDirectDisplayID, int, void *, int);
typedef CGError (*SLSGetCurrentDisplayModeFunc)(CGDirectDisplayID, int32_t *);

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        void *sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW);
        CreateFunc pCreate = dlsym(iokit, "IOAVServiceCreateWithService");
        CopyEDIDFunc copyEDID = dlsym(iokit, "IOAVServiceCopyEDID");
        SLSGetNumberOfDisplayModesFunc getNum = dlsym(sl, "SLSGetNumberOfDisplayModes");
        SLSGetDisplayModeDescriptionOfLengthFunc getDesc = dlsym(sl, "SLSGetDisplayModeDescriptionOfLength");
        SLSGetCurrentDisplayModeFunc getCur = dlsym(sl, "SLSGetCurrentDisplayMode");

        CGDirectDisplayID displays[16];
        uint32_t count = 0;
        CGGetActiveDisplayList(16, displays, &count);

        for (uint32_t i = 0; i < count; i++) {
            CGDirectDisplayID d = displays[i];
            bool builtin = CGDisplayIsBuiltin(d);
            int n = 0;
            getNum(d, &n);
            int32_t curModeId = -1;
            getCur(d, &curModeId);

            printf("Display %u (ID=%u) %s: %d modes, curMode=%d\n",
                   i, d, builtin ? "BUILTIN" : "EXTERNAL", n, curModeId);

            if (!builtin) {
                CGDisplayModeRef mode = CGDisplayCopyDisplayMode(d);
                if (mode) {
                    printf("  Current: %zux%zu @%.1fHz\n",
                           CGDisplayModeGetWidth(mode), CGDisplayModeGetHeight(mode),
                           CGDisplayModeGetRefreshRate(mode));
                    CGDisplayModeRelease(mode);
                }

                // Unique refresh rates
                NSMutableSet *rates = [NSMutableSet set];
                for (int j = 0; j < n; j++) {
                    uint8_t desc[0x100] = {0};
                    getDesc(d, j, desc, sizeof(desc));
                    uint32_t hz = *(uint32_t *)&desc[0x24];
                    [rates addObject:@(hz)];
                }
                NSArray *sorted = [[rates allObjects] sortedArrayUsingSelector:@selector(compare:)];
                printf("  Refresh rates: ");
                for (NSNumber *r in sorted) printf("%u ", r.unsignedIntValue);
                printf("Hz\n");

                // Show HiDPI modes at native-ish resolutions (useful ones)
                for (int j = 0; j < n; j++) {
                    uint8_t desc[0x100] = {0};
                    getDesc(d, j, desc, sizeof(desc));
                    uint32_t w = *(uint32_t *)&desc[0x08];
                    uint32_t h = *(uint32_t *)&desc[0x0c];
                    uint32_t hz = *(uint32_t *)&desc[0x24];
                    uint32_t mid = *(uint32_t *)&desc[0x00];
                    uint32_t flags = *(uint32_t *)&desc[0x04];
                    // Only show HiDPI modes at key resolutions
                    if (flags & 0x2000000) {
                        printf("  mode %d: %ux%u @%uHz HiDPI%s\n",
                               mid, w, h, hz,
                               mid == curModeId ? " <-- CURRENT" : "");
                    }
                }
            }
        }

        // EDID status
        printf("\nEDID:\n");
        io_iterator_t iter;
        IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iter);
        io_service_t s;
        while ((s = IOIteratorNext(iter)) != IO_OBJECT_NULL) {
            CFMutableDictionaryRef props = NULL;
            IORegistryEntryCreateCFProperties(s, &props, kCFAllocatorDefault, 0);
            if (props) {
                CFStringRef loc = CFDictionaryGetValue(props, CFSTR("Location"));
                if (loc && CFStringCompare(loc, CFSTR("External"), 0) == kCFCompareEqualTo) {
                    IOAVServiceRef avSvc = pCreate(kCFAllocatorDefault, s);
                    if (avSvc) {
                        CFDataRef edid = NULL;
                        IOReturn r = copyEDID(avSvc, &edid);
                        if (r == 0 && edid) {
                            long len = CFDataGetLength(edid);
                            printf("  External EDID: %ld bytes\n", len);
                            NSString *edidPath = [@"~/.config/edid-override/edid.bin" stringByExpandingTildeInPath];
                            NSData *ourEdid = [NSData dataWithContentsOfFile:edidPath];
                            NSData *currentEdid = (__bridge NSData *)edid;
                            if (ourEdid && [currentEdid isEqualToData:ourEdid]) {
                                printf("  Status: Custom EDID override ACTIVE\n");
                            } else {
                                printf("  Status: Factory EDID (no override)\n");
                            }
                            CFRelease(edid);
                        } else {
                            printf("  External EDID: read failed (0x%x)\n", r);
                        }
                    }
                }
                CFRelease(props);
            }
            IOObjectRelease(s);
        }
        IOObjectRelease(iter);

        return 0;
    }
}
