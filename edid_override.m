// edid_override.m - Inject a custom EDID to unlock high refresh rates on Apple Silicon Macs
// Build: clang -fmodules -framework Foundation -framework CoreGraphics -framework IOKit -framework AppKit -o edid_override edid_override.m
//
// Usage:
//   ./edid_override                     # Inject EDID and re-enable the daemon if needed
//   ./edid_override --daemon            # Run as daemon, re-inject on display wake/reconnect
//   ./edid_override /path/to/edid.bin   # Inject EDID from specified path
//   ./edid_override --reset             # Stop daemon and clear virtual EDID override
//   ./edid_override --enable            # Re-enable daemon and inject EDID
//   ./edid_override --status            # Show current EDID status
//
@import Foundation;
@import CoreGraphics;
@import AppKit;
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>

typedef CFTypeRef IOAVServiceRef;
typedef IOAVServiceRef (*CreateFunc)(CFAllocatorRef, io_service_t);
typedef IOReturn (*SetVEDIDFunc)(IOAVServiceRef, uint32_t, CFDataRef);
typedef IOReturn (*CopyEDIDFunc)(IOAVServiceRef, CFDataRef *);

static void *g_iokit = NULL;
static NSString *g_edidPath = nil;

static NSString *launchAgentPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/LaunchAgents/com.edid-override.plist"];
}

static NSString *installDir(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@".config/edid-override"];
}

static NSString *installedBinaryPath(void) {
    return [installDir() stringByAppendingPathComponent:@"edid_override"];
}

static NSString *installedEDIDPath(void) {
    return [installDir() stringByAppendingPathComponent:@"edid.bin"];
}

static NSString *currentExecutablePath(void) {
    uint32_t size = 0;
    _NSGetExecutablePath(NULL, &size);
    if (size == 0) {
        return nil;
    }

    char *buffer = malloc(size);
    if (!buffer) {
        return nil;
    }

    NSString *result = nil;
    if (_NSGetExecutablePath(buffer, &size) == 0) {
        result = [[[NSFileManager defaultManager] stringWithFileSystemRepresentation:buffer length:strlen(buffer)] stringByResolvingSymlinksInPath];
    }
    free(buffer);
    return result;
}

static BOOL isInstalledBinaryInvocation(void) {
    NSString *exePath = currentExecutablePath();
    if (!exePath) {
        return NO;
    }
    return [exePath isEqualToString:[installedBinaryPath() stringByResolvingSymlinksInPath]];
}

static NSString *launchAgentPlistContent(void) {
    return [NSString stringWithFormat:
        @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
        "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
        "<plist version=\"1.0\">\n"
        "<dict>\n"
        "    <key>Label</key>\n"
        "    <string>com.edid-override</string>\n"
        "    <key>ProgramArguments</key>\n"
        "    <array>\n"
        "        <string>%@</string>\n"
        "        <string>--daemon</string>\n"
        "    </array>\n"
        "    <key>RunAtLoad</key>\n"
        "    <true/>\n"
        "    <key>KeepAlive</key>\n"
        "    <true/>\n"
        "    <key>StandardOutPath</key>\n"
        "    <string>/tmp/edid-override.log</string>\n"
        "    <key>StandardErrorPath</key>\n"
        "    <string>/tmp/edid-override.log</string>\n"
        "</dict>\n"
        "</plist>\n", installedBinaryPath()];
}

static int ensureLaunchAgentEnabled(void) {
    NSString *binaryPath = installedBinaryPath();
    NSString *plistPath = launchAgentPath();
    NSString *plistContent = launchAgentPlistContent();
    NSFileManager *fm = [NSFileManager defaultManager];

    if (![fm fileExistsAtPath:binaryPath]) {
        fprintf(stderr, "edid_override not found at %s\n", binaryPath.UTF8String);
        fprintf(stderr, "Run install.sh first to compile and install.\n");
        return 1;
    }

    NSString *existing = [NSString stringWithContentsOfFile:plistPath encoding:NSUTF8StringEncoding error:nil];
    if (![existing isEqualToString:plistContent]) {
        NSString *launchAgentsDir = [plistPath stringByDeletingLastPathComponent];
        [fm createDirectoryAtPath:launchAgentsDir
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];

        NSError *writeError = nil;
        [plistContent writeToFile:plistPath atomically:YES encoding:NSUTF8StringEncoding error:&writeError];
        if (writeError) {
            fprintf(stderr, "Failed to write LaunchAgent: %s\n", writeError.localizedDescription.UTF8String);
            return 1;
        }
    }

    if (system("launchctl list com.edid-override >/dev/null 2>&1") != 0) {
        NSString *loadCmd = [NSString stringWithFormat:@"launchctl load '%@'", plistPath];
        if (system(loadCmd.UTF8String) != 0) {
            fprintf(stderr, "Failed to load LaunchAgent.\n");
            return 1;
        }
        printf("LaunchAgent installed and loaded.\n");
        printf("EDID override daemon will start automatically.\n");
    }

    return 0;
}

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
    // Stop the daemon first so it doesn't re-inject the EDID
    NSString *plistPath = launchAgentPath();
    int stopped = 0;
    if ([[NSFileManager defaultManager] fileExistsAtPath:plistPath]) {
        printf("Stopping EDID override daemon...\n");
        NSString *cmd = [NSString stringWithFormat:@"launchctl unload '%@' 2>/dev/null", plistPath];
        system(cmd.UTF8String);
        stopped = 1;
        usleep(500000);
    }

    SetVEDIDFunc setVEDID = dlsym(g_iokit, "IOAVServiceSetVirtualEDIDMode");
    IOAVServiceRef avSvc = findExtAVService();
    if (!avSvc) {
        fprintf(stderr, "No external display found.\n");
        return 1;
    }
    IOReturn r = setVEDID(avSvc, 0, NULL);
    if (r == 0) {
        printf("Virtual EDID override cleared.\n");
        if (stopped) {
            printf("To re-enable, run: %s/edid_override\n", installDir().UTF8String);
        }
        return 0;
    } else {
        fprintf(stderr, "Reset failed: 0x%x\n", r);
        return 1;
    }
}

static int doEnable(void) {
    if (ensureLaunchAgentEnabled() != 0) {
        return 1;
    }
    return doInject(installedEDIDPath().UTF8String);
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
            if (strcmp(argv[1], "--enable") == 0) return doEnable();
            if (strcmp(argv[1], "--status") == 0) return doStatus();
            if (strcmp(argv[1], "--daemon") == 0) {
                const char *path = (argc > 2) ? argv[2] : "~/.config/edid-override/edid.bin";
                return doDaemon(path);
            }
            return doInject(argv[1]);
        }

        if (isInstalledBinaryInvocation()) {
            return doEnable();
        }
        return doInject("~/.config/edid-override/edid.bin");
    }
}
