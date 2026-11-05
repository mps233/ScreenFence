/*
 * Controlled relative mouse input for ScreenFence validation.
 *
 * This helper observes and injects input in a separate process. It never
 * constrains the cursor: the running ScreenFence App must do that itself.
 * It requires existing Accessibility / event permissions and never requests
 * them. No keyboard or button events are generated.
 */
#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/hidsystem/IOHIDLib.h>
#include <IOKit/hidsystem/IOHIDShared.h>
#include <IOKit/hidsystem/IOLLEvent.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct {
    int64_t pid;
    unsigned count;
    unsigned moving;
    double deltaX, deltaY;
    double unacceleratedX, unacceleratedY;
    CGPoint first, last;
} ForeignSource;

static CFMachPortRef eventTap;
static io_connect_t connection;
static IOHIDManagerRef physicalMonitor;
static bool physicalMonitorAvailable;
static CGPoint originalPointer;
static bool restorePointer;
static bool bottomEdge;
static CGPoint trialStart;
static int64_t allowedAppPID;
static atomic_bool measuring;
static atomic_bool injectionFinished;
static atomic_bool interference;
static atomic_int injectionError;
static unsigned ownEvents, physicalInputs, foreignEvents, foreignMoving, tapTimeouts;
static ForeignSource foreignSources[16];
static unsigned foreignSourceCount;
static double lastOwnEventTime, maximumEventGap, maximumCallbackTime;

static CGPoint currentPointer(void) {
    CGEventRef event = CGEventCreate(NULL);
    if (!event) {
        return CGPointMake(NAN, NAN);
    }
    CGPoint point = CGEventGetLocation(event);
    CFRelease(event);
    return point;
}

static CGError positionPointer(CGPoint point) {
    CGError status = CGWarpMouseCursorPosition(point);
    CGAssociateMouseAndMouseCursorPosition(true);
    return status;
}

static bool buttonsReleased(void) {
    for (unsigned button = 0; button < 5; ++button) {
        if (CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, button)) {
            return false;
        }
    }
    return true;
}

static bool permissionsReady(void) {
    return AXIsProcessTrusted() &&
        CGPreflightPostEventAccess() &&
        CGPreflightListenEventAccess() &&
        IOHIDCheckAccess(kIOHIDRequestTypePostEvent) == kIOHIDAccessTypeGranted;
}

static void cleanup(void) {
    atomic_store(&measuring, false);
    if (eventTap) {
        CGEventTapEnable(eventTap, false);
        CFMachPortInvalidate(eventTap);
        CFRelease(eventTap);
        eventTap = NULL;
    }
    if (physicalMonitor) {
        IOHIDManagerUnscheduleFromRunLoop(
            physicalMonitor, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode
        );
        IOHIDManagerClose(physicalMonitor, kIOHIDOptionsTypeNone);
        CFRelease(physicalMonitor);
        physicalMonitor = NULL;
    }
    if (connection) {
        IOServiceClose(connection);
        connection = IO_OBJECT_NULL;
    }
    if (restorePointer) {
        positionPointer(originalPointer);
        restorePointer = false;
    }
}

static void observePhysicalValue(
    void *context, IOReturn status, void *sender, IOHIDValueRef value
) {
    (void)context; (void)status; (void)sender;
    if (!atomic_load(&measuring)) {
        return;
    }
    IOHIDElementRef element = IOHIDValueGetElement(value);
    uint32_t page = IOHIDElementGetUsagePage(element);
    uint32_t usage = IOHIDElementGetUsage(element);
    if (page != 1 || (usage != 0x30 && usage != 0x31) ||
        IOHIDValueGetIntegerValue(value) == 0) {
        return;
    }
    IOHIDDeviceRef device = IOHIDElementGetDevice(element);
    CFTypeRef product = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductKey));
    if (product && CFGetTypeID(product) == CFStringGetTypeID()) {
        ++physicalInputs;
        atomic_store(&interference, true);
    }
}

static void recordForeignEvent(CGEventRef event) {
    if (!atomic_load(&measuring)) {
        return;
    }
    int64_t pid = CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID);
    double dx = CGEventGetDoubleValueField(event, kCGMouseEventDeltaX);
    double dy = CGEventGetDoubleValueField(event, kCGMouseEventDeltaY);
    double ux = CGEventGetDoubleValueField(event, kCGEventUnacceleratedPointerMovementX);
    double uy = CGEventGetDoubleValueField(event, kCGEventUnacceleratedPointerMovementY);
    CGPoint point = CGEventGetLocation(event);
    bool moving = fabs(dx) > 0.01 || fabs(dy) > 0.01 ||
        fabs(ux) > 0.01 || fabs(uy) > 0.01;
    ++foreignEvents;
    foreignMoving += moving;

    unsigned index;
    for (index = 0; index < foreignSourceCount; ++index) {
        if (foreignSources[index].pid == pid) {
            break;
        }
    }
    if (index == foreignSourceCount && foreignSourceCount < 16) {
        ++foreignSourceCount;
        foreignSources[index].pid = pid;
        foreignSources[index].first = point;
    }
    if (index < 16) {
        ForeignSource *source = &foreignSources[index];
        ++source->count;
        source->moving += moving;
        source->deltaX += dx;
        source->deltaY += dy;
        source->unacceleratedX += ux;
        source->unacceleratedY += uy;
        source->last = point;
    }

    /* The App's own boundary repairs are controlled test activity. Actual
       physical mouse movement is independently detected above. Zero-movement
       polling events do not invalidate a trial. */
    if (pid != allowedAppPID &&
        (fabs(ux) > 0.01 || fabs(uy) > 0.01 || (pid > 0 && moving))) {
        atomic_store(&interference, true);
    }
}

static CGEventRef observeEvent(
    CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *context
) {
    (void)proxy; (void)context;
    double began = CFAbsoluteTimeGetCurrent();
    if (type == kCGEventTapDisabledByTimeout) {
        ++tapTimeouts;
        atomic_store(&interference, true);
        return event;
    }
    if (type != kCGEventMouseMoved) {
        return event;
    }
    if (CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID) != getpid()) {
        recordForeignEvent(event);
        return event;
    }
    ++ownEvents;
    if (lastOwnEventTime && !atomic_load(&injectionFinished)) {
        double gap = began - lastOwnEventTime;
        if (gap > maximumEventGap) {
            maximumEventGap = gap;
        }
    }
    lastOwnEventTime = began;
    double elapsed = CFAbsoluteTimeGetCurrent() - began;
    if (elapsed > maximumCallbackTime) {
        maximumCallbackTime = elapsed;
    }
    return event;
}

static bool postRelative(int deltaX, int deltaY) {
    if (IOHIDCheckAccess(kIOHIDRequestTypePostEvent) != kIOHIDAccessTypeGranted) {
        atomic_store(&injectionError, kIOReturnNotPermitted);
        return false;
    }
    NXEventData data;
    memset(&data, 0, sizeof(data));
    data.mouseMove.dx = deltaX;
    data.mouseMove.dy = deltaY;
    IOGPoint ignoredAbsolutePosition = {0, 0};

    /* Isolated to this diagnostic helper. The public, deprecated API's
       HID-manager option reaches relative pointing-device input on the
       tested host. The ordinary relative-position option does not. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    kern_return_t status = IOHIDPostEvent(
        connection, NX_MOUSEMOVED, ignoredAbsolutePosition,
        &data, kNXEventDataVersion, 0, kIOHIDPostHIDManagerEvent
    );
#pragma clang diagnostic pop
    if (status != KERN_SUCCESS) {
        atomic_store(&injectionError, status);
        return false;
    }
    return true;
}

static void *injectSequence(void *context) {
    (void)context;
    usleep(80000);
    if (!atomic_load(&interference)) {
        postRelative(bottomEdge ? 0 : 8, bottomEdge ? 8 : 0);
    }
    for (unsigned step = 0; step < 25 &&
         !atomic_load(&interference) && !atomic_load(&injectionError); ++step) {
        usleep(8000);
        postRelative(bottomEdge ? 2 : 5, bottomEdge ? 5 : 2);
    }
    atomic_store(&injectionFinished, true);
    return NULL;
}

static void pumpFor(double seconds) {
    double end = CFAbsoluteTimeGetCurrent() + seconds;
    while (CFAbsoluteTimeGetCurrent() < end) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.005, false);
    }
}

static void printReport(CGPoint pushed, CGPoint inward) {
    printf(
        "{\"mode\":0,\"axis\":\"%s\",\"pid\":%d,\"interference\":%s,"
        "\"physicalMonitorAvailable\":%s,\"physicalHIDInputs\":%u,"
        "\"foreignEvents\":%u,\"foreignMoving\":%u,\"events\":%u,"
        "\"timeouts\":%u,\"injectionError\":%d,"
        "\"maxCallbackMs\":%.3f,\"maxGapMs\":%.3f,"
        "\"pushedX\":%.2f,\"pushedY\":%.2f,"
        "\"inwardX\":%.2f,\"inwardY\":%.2f,"
        "\"tangentMoved\":%s,\"inwardImmediate\":%s,\"foreign\":[",
        bottomEdge ? "bottom" : "right", getpid(),
        atomic_load(&interference) ? "true" : "false",
        physicalMonitorAvailable ? "true" : "false",
        physicalInputs, foreignEvents, foreignMoving, ownEvents, tapTimeouts,
        atomic_load(&injectionError), maximumCallbackTime * 1000,
        maximumEventGap * 1000, pushed.x, pushed.y, inward.x, inward.y,
        (bottomEdge ? pushed.x > trialStart.x + 10 : pushed.y > trialStart.y + 10) ?
            "true" : "false",
        (bottomEdge ? inward.y < pushed.y - 0.1 : inward.x < pushed.x - 0.1) ?
            "true" : "false"
    );
    for (unsigned index = 0; index < foreignSourceCount; ++index) {
        ForeignSource *source = &foreignSources[index];
        printf(
            "%s{\"pid\":%lld,\"count\":%u,\"moving\":%u,"
            "\"rawDelta\":[%.2f,%.2f],\"unaccelerated\":[%.2f,%.2f],"
            "\"first\":[%.2f,%.2f],\"last\":[%.2f,%.2f]}",
            index ? "," : "", source->pid, source->count, source->moving,
            source->deltaX, source->deltaY,
            source->unacceleratedX, source->unacceleratedY,
            source->first.x, source->first.y, source->last.x, source->last.y
        );
    }
    puts("]}");
    fflush(stdout);
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--preflight") == 0) {
        bool ready = permissionsReady();
        bool released = buttonsReleased();
        printf(
            "{\"accessibility\":%s,\"postAccess\":%s,\"listenAccess\":%s,"
            "\"hidPostAccess\":%s,\"mouseButtonsReleased\":%s,\"ready\":%s}\n",
            AXIsProcessTrusted() ? "true" : "false",
            CGPreflightPostEventAccess() ? "true" : "false",
            CGPreflightListenEventAccess() ? "true" : "false",
            IOHIDCheckAccess(kIOHIDRequestTypePostEvent) == kIOHIDAccessTypeGranted ?
                "true" : "false",
            released ? "true" : "false", ready && released ? "true" : "false"
        );
        return ready && released ? 0 : 77;
    }
    if (argc == 2 && strcmp(argv[1], "--where") == 0) {
        CGPoint point = currentPointer();
        if (!isfinite(point.x) || !isfinite(point.y)) {
            return 1;
        }
        printf("%.6f %.6f\n", point.x, point.y);
        return 0;
    }
    if (argc == 4 && strcmp(argv[1], "--restore") == 0) {
        CGPoint point = {atof(argv[2]), atof(argv[3])};
        if (!isfinite(point.x) || !isfinite(point.y)) {
            return 64;
        }
        return positionPointer(point) == kCGErrorSuccess ? 0 : 1;
    }
    if (argc != 4 || strcmp(argv[1], "0") != 0 ||
        (strcmp(argv[2], "right") != 0 && strcmp(argv[2], "bottom") != 0)) {
        fputs("Usage: RelativeHIDInput 0 right|bottom APP_PID\n", stderr);
        return 64;
    }
    if (!permissionsReady() || !buttonsReleased()) {
        fputs("Existing event authorization and released mouse buttons are required.\n", stderr);
        return 77;
    }
    bottomEdge = strcmp(argv[2], "bottom") == 0;
    allowedAppPID = atoll(argv[3]);
    originalPointer = currentPointer();
    if (!isfinite(originalPointer.x) || !isfinite(originalPointer.y)) {
        return 1;
    }
    atexit(cleanup);

    io_service_t service = IOServiceGetMatchingService(
        kIOMainPortDefault, IOServiceMatching("IOHIDSystem")
    );
    if (!service) {
        return 77;
    }
    kern_return_t status = IOServiceOpen(
        service, mach_task_self(), kIOHIDParamConnectType, &connection
    );
    IOObjectRelease(service);
    if (status != KERN_SUCCESS) {
        return 77;
    }

    physicalMonitor = IOHIDManagerCreate(NULL, kIOHIDOptionsTypeNone);
    int pageValue = 1, usageValue = 2;
    CFNumberRef page = CFNumberCreate(NULL, kCFNumberIntType, &pageValue);
    CFNumberRef usage = CFNumberCreate(NULL, kCFNumberIntType, &usageValue);
    const void *keys[] = {CFSTR(kIOHIDDeviceUsagePageKey), CFSTR(kIOHIDDeviceUsageKey)};
    const void *values[] = {page, usage};
    CFDictionaryRef matching = CFDictionaryCreate(
        NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    IOHIDManagerSetDeviceMatching(physicalMonitor, matching);
    CFRelease(matching);
    CFRelease(page);
    CFRelease(usage);
    IOHIDManagerRegisterInputValueCallback(physicalMonitor, observePhysicalValue, NULL);
    IOHIDManagerScheduleWithRunLoop(
        physicalMonitor, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode
    );
    physicalMonitorAvailable =
        IOHIDManagerOpen(physicalMonitor, kIOHIDOptionsTypeNone) == kIOReturnSuccess;
    if (!physicalMonitorAvailable) {
        fputs("Cannot observe physical mouse interference with existing permissions.\n", stderr);
        return 77;
    }

    eventTap = CGEventTapCreate(
        kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionListenOnly,
        CGEventMaskBit(kCGEventMouseMoved), observeEvent, NULL
    );
    if (!eventTap) {
        return 77;
    }
    CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(NULL, eventTap, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
    CFRelease(source);

    CGRect bounds = CGDisplayBounds(CGMainDisplayID());
    double horizontalMargin = fmin(100, bounds.size.width / 4);
    double verticalMargin = fmin(100, bounds.size.height / 4);
    double startX = fmin(
        fmax(CGRectGetMinX(bounds) + 1100, CGRectGetMinX(bounds) + horizontalMargin),
        CGRectGetMaxX(bounds) - horizontalMargin
    );
    double startY = fmin(
        fmax(CGRectGetMinY(bounds) + 400, CGRectGetMinY(bounds) + verticalMargin),
        CGRectGetMaxY(bounds) - verticalMargin
    );
    trialStart = bottomEdge ?
        CGPointMake(startX, CGRectGetMaxY(bounds) - 3) :
        CGPointMake(CGRectGetMaxX(bounds) - 3, startY);
    restorePointer = true;
    if (positionPointer(trialStart) != kCGErrorSuccess) {
        return 1;
    }
    pumpFor(0.3);
    ownEvents = 0;
    lastOwnEventTime = 0;
    atomic_store(&measuring, true);

    pthread_t injector;
    if (pthread_create(&injector, NULL, injectSequence, NULL) != 0) {
        return 1;
    }
    double deadline = CFAbsoluteTimeGetCurrent() + 1.2;
    while (CFAbsoluteTimeGetCurrent() < deadline) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.005, false);
        if (atomic_load(&interference) ||
            (atomic_load(&injectionFinished) &&
             CFAbsoluteTimeGetCurrent() - lastOwnEventTime > 0.08)) {
            break;
        }
    }
    CGPoint pushed = currentPointer();
    if (!atomic_load(&interference) && !atomic_load(&injectionError)) {
        postRelative(bottomEdge ? 0 : -3, bottomEdge ? -3 : 0);
    }
    pumpFor(0.1);
    CGPoint inward = currentPointer();
    atomic_store(&measuring, false);
    pthread_join(injector, NULL);
    cleanup();
    printReport(pushed, inward);
    return atomic_load(&injectionError) ? 1 : 0;
}
