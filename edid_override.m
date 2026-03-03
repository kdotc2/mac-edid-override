// edid_override.m - Inject a custom EDID to unlock high refresh rates on Apple Silicon Macs
// Build: clang -fmodules -framework Foundation -framework CoreGraphics -framework IOKit -framework AppKit -o edid_override edid_override.m
//
// Usage:
//   ./edid_override                     # Inject EDID and exit
//   ./edid_override --daemon            # Run as daemon, re-inject on display wake/reconnect
//   ./edid_override /path/to/edid.bin   # Inject EDID from specified path
//   ./edid_override --reset             # Clear virtual EDID override
//   ./edid_override --status            # Show current EDID status
//
@import Foundation;
@import CoreGraphics;
@import AppKit;
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>

typedef CFTypeRef IOAVServiceRef;
typedef IOAVServiceRef (*CreateFunc)(CFAllocatorRef, io_service_t);
typedef IOReturn (*SetVEDIDFunc)(IOAVServiceRef, uint32_t, CFDataRef);
typedef IOReturn (*CopyEDIDFunc)(IOAVServiceRef, CFDataRef *);

static void *g_iokit = NULL;
static NSString *g_edidPath = nil;

static IOAVServiceRef findExtAVService(void) {
    CreateFunc pCreate = dlsym(g_iokit, "IOAVServiceCreateWithService");
    io_iterator_t iter;
    IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iter);
    IOAVServiceRef result = NULL;
    io_service_t s;
    while ((s = IOIteratorNext(iter)) != IO_OBJECT_NULL) {
        CFMutableDictionaryRef props = NULL;
        IORegistryEntryCreateCFProperties(s, &props, kCFAllocatorDefault, 0);
        if (props) {
            CFStringRef loc = CFDictionaryGetValue(props, CFSTR("Location"));
            if (loc && CFStringCompare(loc, CFSTR("External"), 0) == kCFCompareEqualTo) {
                result = pCreate(kCFAllocatorDefault, s);
            }
            CFRelease(props);
        }
        IOObjectRelease(s);
        if (result) break;
    }
    IOObjectRelease(iter);
    return result;
}

static int doInject(const char *edidPath) {
    SetVEDIDFunc setVEDID = dlsym(g_iokit, "IOAVServiceSetVirtualEDIDMode");
    CopyEDIDFunc copyEDID = dlsym(g_iokit, "IOAVServiceCopyEDID");

    NSString *path = [[NSString stringWithUTF8String:edidPath] stringByExpandingTildeInPath];
    NSData *edidFile = [NSData dataWithContentsOfFile:path];
    if (!edidFile) {
        fprintf(stderr, "Cannot read EDID file: %s\n", path.UTF8String);
        return 1;
    }
    CFDataRef edidCF = CFDataCreate(kCFAllocatorDefault, edidFile.bytes, edidFile.length);
    printf("EDID: %lu bytes from %s\n", (unsigned long)edidFile.length, path.UTF8String);

    IOAVServiceRef avSvc = findExtAVService();
    if (!avSvc) {
        fprintf(stderr, "No external display found.\n");
        CFRelease(edidCF);
        return 1;
    }

    // Check if already injected
    CFDataRef current = NULL;
    copyEDID(avSvc, &current);
    if (current) {
        NSData *curData = (__bridge NSData *)current;
        if ([curData isEqualToData:edidFile]) {
            printf("EDID already active, skipping.\n");
            CFRelease(current);
            CFRelease(edidCF);
            return 0;
        }
        CFRelease(current);
    }

    // Reset any existing override first
    setVEDID(avSvc, 0, NULL);
    usleep(500000);

    // Inject
    IOReturn r = setVEDID(avSvc, 1, edidCF);
    if (r != 0) {
        fprintf(stderr, "Injection failed: 0x%x\n", r);
        CFRelease(edidCF);
        return 1;
    }
    printf("EDID injected successfully.\n");

    // Verify
    CFDataRef readBack = NULL;
    copyEDID(avSvc, &readBack);
    if (readBack) {
        NSData *cur = (__bridge NSData *)readBack;
        if ([cur isEqualToData:edidFile]) {
            printf("Verified: EDID matches.\n");
        } else {
            printf("Warning: EDID readback doesn't match.\n");
        }
        CFRelease(readBack);
    }

    CFRelease(edidCF);
    return 0;
}

static int doReset(void) {
    SetVEDIDFunc setVEDID = dlsym(g_iokit, "IOAVServiceSetVirtualEDIDMode");
    IOAVServiceRef avSvc = findExtAVService();
    if (!avSvc) {
        fprintf(stderr, "No external display found.\n");
        return 1;
    }
    IOReturn r = setVEDID(avSvc, 0, NULL);
    if (r == 0) {
        printf("Virtual EDID override cleared.\n");
        return 0;
    } else {
        fprintf(stderr, "Reset failed: 0x%x\n", r);
        return 1;
    }
}

static int doStatus(void) {
    CopyEDIDFunc copyEDID = dlsym(g_iokit, "IOAVServiceCopyEDID");
    IOAVServiceRef avSvc = findExtAVService();
    if (!avSvc) {
        fprintf(stderr, "No external display found.\n");
        return 1;
    }
    CFDataRef edid = NULL;
    IOReturn r = copyEDID(avSvc, &edid);
    if (r == 0 && edid) {
        long len = CFDataGetLength(edid);
        printf("External display EDID: %ld bytes\n", len);
        NSString *edidPath = [@"~/.config/edid-override/edid.bin" stringByExpandingTildeInPath];
        NSData *installed = [NSData dataWithContentsOfFile:edidPath];
        NSData *current = (__bridge NSData *)edid;
        if (installed && [current isEqualToData:installed]) {
            printf("Status: Custom EDID override is ACTIVE\n");
        } else {
            printf("Status: Factory EDID (no override)\n");
        }
        CFRelease(edid);
    } else {
        fprintf(stderr, "Cannot read EDID: 0x%x\n", r);
        return 1;
    }
    return 0;
}

// Callback for display reconfiguration events (wake, plug, etc.)
static void displayReconfigCallback(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags, void *context) {
    // Try re-injection on any meaningful display change
    if (flags & kCGDisplayBeginConfigurationFlag) {
        return; // Wait for the end of reconfiguration
    }

    // Stagger retries: try at 1s, 3s, and 5s after the event
    // The display may not be ready immediately, especially in clamshell mode
    int delays[] = {1, 3, 5};
    for (int i = 0; i < 3; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i] * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            doInject(g_edidPath.UTF8String);
        });
    }
}

// Objective-C helper for NSWorkspace wake notifications
@interface WakeObserver : NSObject
@end

@implementation WakeObserver
- (void)onWake:(NSNotification *)note {
    printf("[%s] System wake detected, re-injecting EDID...\n",
           [NSDate.now descriptionWithLocale:nil].UTF8String);
    // Stagger retries after wake — display may take a moment to be ready
    int delays[] = {1, 3, 5, 8};
    for (int i = 0; i < 4; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i] * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            doInject(g_edidPath.UTF8String);
        });
    }
}

- (void)onDisplayWake:(NSNotification *)note {
    printf("[%s] Screens wake detected, re-injecting EDID...\n",
           [NSDate.now descriptionWithLocale:nil].UTF8String);
    int delays[] = {1, 3, 5};
    for (int i = 0; i < 3; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i] * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            doInject(g_edidPath.UTF8String);
        });
    }
}
@end

static int doDaemon(const char *edidPath) {
    g_edidPath = [[NSString stringWithUTF8String:edidPath] stringByExpandingTildeInPath];
    printf("Starting EDID override daemon...\n");
    printf("EDID: %s\n", g_edidPath.UTF8String);

    // Initial injection
    doInject(edidPath);

    // Register for display change notifications
    CGDisplayRegisterReconfigurationCallback(displayReconfigCallback, NULL);

    // Register for system wake notifications (works in clamshell mode)
    WakeObserver *observer = [[WakeObserver alloc] init];
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserver:observer
        selector:@selector(onWake:)
        name:NSWorkspaceDidWakeNotification
        object:nil];
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserver:observer
        selector:@selector(onDisplayWake:)
        name:NSWorkspaceScreensDidWakeNotification
        object:nil];

    printf("Watching for display changes and system wake...\n");

    // Safety net: check every 5 seconds
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 5 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{
        CopyEDIDFunc copyEDID = dlsym(g_iokit, "IOAVServiceCopyEDID");
        IOAVServiceRef avSvc = findExtAVService();
        if (avSvc) {
            CFDataRef current = NULL;
            copyEDID(avSvc, &current);
            if (current) {
                NSData *installed = [NSData dataWithContentsOfFile:g_edidPath];
                NSData *curData = (__bridge NSData *)current;
                if (installed && ![curData isEqualToData:installed]) {
                    printf("[%s] EDID mismatch detected, re-injecting...\n",
                           [NSDate.now descriptionWithLocale:nil].UTF8String);
                    doInject(g_edidPath.UTF8String);
                }
                CFRelease(current);
            }
        }
    });
    dispatch_resume(timer);

    // Run the main loop forever
    [[NSRunLoop mainRunLoop] run];
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        g_iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);

        if (argc > 1) {
            if (strcmp(argv[1], "--reset") == 0) return doReset();
            if (strcmp(argv[1], "--status") == 0) return doStatus();
            if (strcmp(argv[1], "--daemon") == 0) {
                const char *path = (argc > 2) ? argv[2] : "~/.config/edid-override/edid.bin";
                return doDaemon(path);
            }
            return doInject(argv[1]);
        }

        return doInject("~/.config/edid-override/edid.bin");
    }
}
