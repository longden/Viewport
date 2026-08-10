/**
 * Direct iOS Simulator input via SimulatorKit Indigo HID.
 *
 * HID message construction is adapted from Meta idb's FBSimulatorIndigoHID.m
 * (MIT), copyright Meta Platforms, Inc. and affiliates.
 * Session/load flow is adapted from vscode-ios-simulator-embed's
 * SimulatorIndigoTouch.m (Apache 2.0), copyright 2026 Mykola Odnosumov.
 * Full notices: THIRD_PARTY_NOTICES.md.
 */

#import "ViewportIndigoTouch.h"
#import "Indigo.h"

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>

static const unsigned long long kSimDeviceStateBooted = 3;
/// Low-rate present when damage callbacks drive frames (stall recovery only).
static const unsigned int kDamageHeartbeatFPS = 2;

static void StoreError(char *buffer, size_t length, NSString *message) {
  if (!buffer || length == 0) {
    return;
  }
  const char *utf8 = message.UTF8String ?: "Unknown HID error";
  strncpy(buffer, utf8, length - 1);
  buffer[length - 1] = '\0';
}

static BOOL BundleExistsAtPath(NSString *path) {
  BOOL isDirectory = NO;
  return path.length > 0
    && [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory]
    && isDirectory;
}

static BOOL LoadBundleAtPath(NSString *path) {
  if (!BundleExistsAtPath(path)) {
    return NO;
  }
  NSBundle *bundle = [NSBundle bundleWithPath:path];
  return bundle != nil && [bundle load];
}

/// Prefer DEVELOPER_DIR, then an Xcode that ships SimulatorKit, then xcode-select.
static NSString *ResolvedDeveloperDirectory(void) {
  NSString *fromEnv = NSProcessInfo.processInfo.environment[@"DEVELOPER_DIR"];
  if (fromEnv.length > 0 && BundleExistsAtPath(fromEnv)) {
    return fromEnv;
  }

  NSArray<NSString *> *candidates = @[
    @"/Applications/Xcode.app/Contents/Developer",
    @"/Applications/Xcode-beta.app/Contents/Developer",
  ];
  for (NSString *candidate in candidates) {
    NSString *privateKit = [[candidate
      stringByAppendingPathComponent:@"Library/PrivateFrameworks"]
      stringByAppendingPathComponent:@"SimulatorKit.framework"];
    NSString *sharedKit = [[[candidate stringByDeletingLastPathComponent]
      stringByAppendingPathComponent:@"SharedFrameworks"]
      stringByAppendingPathComponent:@"SimulatorKit.framework"];
    if (BundleExistsAtPath(privateKit) || BundleExistsAtPath(sharedKit)) {
      return candidate;
    }
  }

  NSTask *task = [[NSTask alloc] init];
  task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcode-select"];
  task.arguments = @[@"-p"];
  NSPipe *pipe = [NSPipe pipe];
  task.standardOutput = pipe;
  task.standardError = [NSPipe pipe];
  NSError *launchError = nil;
  if ([task launchAndReturnError:&launchError]) {
    [task waitUntilExit];
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *selected = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (selected.length > 0 && BundleExistsAtPath(selected)) {
      return selected;
    }
  }

  return @"/Applications/Xcode.app/Contents/Developer";
}

BOOL ViewportHIDLoadFrameworks(void) {
  static dispatch_once_t onceToken;
  static BOOL loaded = NO;
  dispatch_once(&onceToken, ^{
    NSString *developerDirectory = ResolvedDeveloperDirectory();
    NSString *xcodeContents = [developerDirectory stringByDeletingLastPathComponent];

    NSArray<NSString *> *coreSimulatorPaths = @[
      @"/Library/Developer/PrivateFrameworks/CoreSimulator.framework",
      [[developerDirectory stringByAppendingPathComponent:@"Library/PrivateFrameworks"]
        stringByAppendingPathComponent:@"CoreSimulator.framework"],
    ];
    BOOL coreLoaded = NO;
    for (NSString *path in coreSimulatorPaths) {
      if (LoadBundleAtPath(path)) {
        coreLoaded = YES;
        break;
      }
    }
    if (!coreLoaded) {
      loaded = NO;
      return;
    }

    // Xcode 27+ may ship SimulatorKit under Contents/SharedFrameworks;
    // older Xcodes keep it under Developer/Library/PrivateFrameworks.
    NSArray<NSString *> *simulatorKitPaths = @[
      [[xcodeContents stringByAppendingPathComponent:@"SharedFrameworks"]
        stringByAppendingPathComponent:@"SimulatorKit.framework"],
      [[developerDirectory stringByAppendingPathComponent:@"Library/PrivateFrameworks"]
        stringByAppendingPathComponent:@"SimulatorKit.framework"],
      @"/Library/Developer/PrivateFrameworks/SimulatorKit.framework",
    ];
    for (NSString *path in simulatorKitPaths) {
      if (LoadBundleAtPath(path)) {
        loaded = YES;
        return;
      }
    }
    loaded = NO;
  });
  return loaded;
}

static id BootedDevice(NSString *udid, NSError **error) {
  Class contextClass = objc_getClass("SimServiceContext");
  if (!contextClass) {
    if (error) {
      *error = [NSError errorWithDomain:@"ViewportHID" code:1 userInfo:@{
        NSLocalizedDescriptionKey: @"SimServiceContext is unavailable"
      }];
    }
    return nil;
  }

  NSString *developerDirectory = ResolvedDeveloperDirectory();
  id context = ((id (*)(Class, SEL, NSString *, NSError **))objc_msgSend)(
    contextClass,
    sel_registerName("sharedServiceContextForDeveloperDir:error:"),
    developerDirectory,
    error);
  if (!context) {
    return nil;
  }
  id deviceSet = ((id (*)(id, SEL, NSError **))objc_msgSend)(
    context,
    sel_registerName("defaultDeviceSetWithError:"),
    error);
  if (!deviceSet) {
    return nil;
  }
  NSArray *devices = ((NSArray *(*)(id, SEL))objc_msgSend)(
    deviceSet,
    sel_registerName("devices"));

  for (id device in devices) {
    unsigned long long state = ((unsigned long long (*)(id, SEL))objc_msgSend)(
      device,
      sel_registerName("state"));
    if (state != kSimDeviceStateBooted) {
      continue;
    }
    NSUUID *deviceUDID = ((NSUUID *(*)(id, SEL))objc_msgSend)(
      device,
      sel_registerName("UDID"));
    if ([deviceUDID.UUIDString caseInsensitiveCompare:udid] == NSOrderedSame) {
      return device;
    }
  }

  if (error) {
    *error = [NSError errorWithDomain:@"ViewportHID" code:2 userInfo:@{
      NSLocalizedDescriptionKey: @"The selected iOS Simulator is not booted"
    }];
  }
  return nil;
}

static Class HIDClientClass(void) {
  Class clientClass = NSClassFromString(@"SimulatorKit.SimDeviceLegacyHIDClient");
  if (!clientClass) {
    clientClass = NSClassFromString(@"SimDeviceLegacyHIDClient");
  }
  if (!clientClass) {
    clientClass = objc_lookUpClass("SimDeviceLegacyHIDClient");
  }
  return clientClass;
}

static IndigoMessage *MouseMessage(
  CGPoint *point,
  int eventType,
  BOOL flag) {
  IndigoMessage *(*function)(CGPoint *, CGPoint *, int, int, BOOL) =
    (void *)dlsym(RTLD_DEFAULT, "IndigoHIDMessageForMouseNSEvent");
  return function ? function(point, NULL, 0x32, eventType, flag) : NULL;
}

static IndigoMessage *CopyTouchMessage(IndigoTouch *touch) {
  size_t stride = sizeof(IndigoPayload);
  IndigoMessage *message = calloc(1, sizeof(IndigoMessage) + stride);
  if (!message) {
    return NULL;
  }

  message->innerSize = sizeof(IndigoPayload);
  message->eventType = IndigoEventTypeTouch;
  message->payload.field1 = 0x0000000b;
  message->payload.timestamp = mach_absolute_time();
  memcpy(&(message->payload.event.button), touch, sizeof(IndigoTouch));

  IndigoPayload *second = (IndigoPayload *)((char *)&message->payload + stride);
  memcpy(second, &message->payload, stride);
  second->event.touch.field1 = 0x00000001;
  second->event.touch.field2 = 0x00000002;
  return message;
}

static IndigoMessage *TouchMessage(double x, double y, int phase) {
  CGPoint point = CGPointMake(x, y);
  IndigoMessage *partial = NULL;

  if (phase == 0) {
    // Dragged/moved NSEvent types (5–8) are rate-limited and often return NULL
    // on Xcode 26. Fall back to a touch-down sample — the same pattern idb uses
    // for swipe interpolation — before giving up.
    static const int moveTypes[] = {6, 5, 7, 8, 1};
    for (size_t index = 0;
         index < sizeof(moveTypes) / sizeof(moveTypes[0]) && !partial;
         index++) {
      partial = MouseMessage(&point, moveTypes[index], NO);
      if (!partial) {
        partial = MouseMessage(&point, moveTypes[index], YES);
      }
    }
  } else {
    partial = MouseMessage(&point, phase, NO);
    if (!partial) {
      partial = MouseMessage(&point, phase, YES);
    }
  }

  if (!partial) {
    return NULL;
  }
  partial->payload.event.touch.xRatio = x;
  partial->payload.event.touch.yRatio = y;
  IndigoTouch touch = partial->payload.event.touch;
  free(partial);
  return CopyTouchMessage(&touch);
}

static BOOL SendMessage(
  id client,
  IndigoMessage *message,
  char *errorBuffer,
  size_t errorBufferLength) {
  if (!message) {
    StoreError(errorBuffer, errorBufferLength, @"Could not create an Indigo HID message");
    return NO;
  }

  SEL selector = sel_registerName(
    "sendWithMessage:freeWhenDone:completionQueue:completion:");
  Method method = class_getInstanceMethod([client class], selector);
  if (!method) {
    free(message);
    StoreError(errorBuffer, errorBufferLength, @"SimulatorKit HID send method is unavailable");
    return NO;
  }

  typedef void (^Completion)(NSError *);
  void (*send)(id, SEL, IndigoMessage *, BOOL, dispatch_queue_t, Completion) =
    (void *)method_getImplementation(method);
  send(client, selector, message, YES, nil, nil);
  return YES;
}

void *ViewportHIDSessionOpen(
  NSString *udid,
  char *errorBuffer,
  size_t errorBufferLength) {
  if (!ViewportHIDLoadFrameworks()) {
    StoreError(errorBuffer, errorBufferLength, @"Could not load CoreSimulator or SimulatorKit");
    return NULL;
  }

  NSError *error = nil;
  id device = BootedDevice(udid, &error);
  Class clientClass = HIDClientClass();
  if (!device || !clientClass) {
    StoreError(
      errorBuffer,
      errorBufferLength,
      error.localizedDescription ?: @"SimulatorKit HID client is unavailable");
    return NULL;
  }

  id allocation = ((id (*)(Class, SEL))objc_msgSend)(
    clientClass,
    sel_registerName("alloc"));
  id client = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(
    allocation,
    sel_registerName("initWithDevice:error:"),
    device,
    &error);
  if (!client) {
    StoreError(errorBuffer, errorBufferLength, error.localizedDescription ?: @"HID client initialization failed");
    return NULL;
  }
  return (__bridge_retained void *)client;
}

BOOL ViewportHIDSessionSendTouch(
  void *session,
  double x,
  double y,
  int phase,
  char *errorBuffer,
  size_t errorBufferLength) {
  if (!session || x < 0 || x > 1 || y < 0 || y > 1 || phase < 0 || phase > 2) {
    StoreError(errorBuffer, errorBufferLength, @"Invalid touch session, coordinate, or phase");
    return NO;
  }
  return SendMessage(
    (__bridge id)session,
    TouchMessage(x, y, phase),
    errorBuffer,
    errorBufferLength);
}

BOOL ViewportHIDSendTouch(
  NSString *udid,
  double x,
  double y,
  int phase,
  char *errorBuffer,
  size_t errorBufferLength) {
  void *session = ViewportHIDSessionOpen(
    udid,
    errorBuffer,
    errorBufferLength);
  if (!session) {
    return NO;
  }
  BOOL succeeded = ViewportHIDSessionSendTouch(
    session,
    x,
    y,
    phase,
    errorBuffer,
    errorBufferLength);
  if (succeeded) {
    dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC / 2)),
      dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
      ^{ ViewportHIDSessionClose(session); });
  } else {
    ViewportHIDSessionClose(session);
  }
  return succeeded;
}

BOOL ViewportHIDSessionSendKeyboard(
  void *session,
  unsigned int usage,
  BOOL keyDown,
  char *errorBuffer,
  size_t errorBufferLength) {
  if (!session) {
    StoreError(errorBuffer, errorBufferLength, @"HID session is unavailable");
    return NO;
  }
  IndigoMessage *(*keyboardMessage)(int, int) =
    (void *)dlsym(RTLD_DEFAULT, "IndigoHIDMessageForKeyboardArbitrary");
  if (!keyboardMessage) {
    StoreError(errorBuffer, errorBufferLength, @"SimulatorKit keyboard HID is unavailable");
    return NO;
  }
  return SendMessage(
    (__bridge id)session,
    keyboardMessage((int)usage, keyDown ? ButtonEventTypeDown : ButtonEventTypeUp),
    errorBuffer,
    errorBufferLength);
}

BOOL ViewportHIDSessionSendButton(
  void *session,
  unsigned int buttonCode,
  BOOL keyDown,
  char *errorBuffer,
  size_t errorBufferLength) {
  if (!session) {
    StoreError(errorBuffer, errorBufferLength, @"HID session is unavailable");
    return NO;
  }
  // IndigoHIDMessageForButton(code, op, target) — confirmed 3-arg on Xcode 26.
  IndigoMessage *(*buttonMessage)(unsigned int, unsigned int, unsigned int) =
    (void *)dlsym(RTLD_DEFAULT, "IndigoHIDMessageForButton");
  if (!buttonMessage) {
    StoreError(errorBuffer, errorBufferLength, @"SimulatorKit button HID is unavailable");
    return NO;
  }
  return SendMessage(
    (__bridge id)session,
    buttonMessage(
      buttonCode,
      keyDown ? ButtonEventTypeDown : ButtonEventTypeUp,
      ButtonEventTargetHardware),
    errorBuffer,
    errorBufferLength);
}

BOOL ViewportHIDSendKeyboard(
  NSString *udid,
  unsigned int usage,
  BOOL keyDown,
  char *errorBuffer,
  size_t errorBufferLength) {
  void *session = ViewportHIDSessionOpen(
    udid,
    errorBuffer,
    errorBufferLength);
  if (!session) {
    return NO;
  }
  BOOL succeeded = ViewportHIDSessionSendKeyboard(
    session,
    usage,
    keyDown,
    errorBuffer,
    errorBufferLength);
  if (succeeded) {
    dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC / 2)),
      dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
      ^{ ViewportHIDSessionClose(session); });
  } else {
    ViewportHIDSessionClose(session);
  }
  return succeeded;
}

void ViewportHIDSessionClose(void *session) {
  if (session) {
    id client = (__bridge_transfer id)session;
    (void)client;
  }
}

#pragma mark - Framebuffer IOSurface

@interface ViewportSurfaceSubscription : NSObject
@property(nonatomic, strong) id device;
@property(nonatomic, strong) id ioClient;
@property(nonatomic, strong) id renderable;
@property(nonatomic, copy) NSUUID *callbackUUID;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) dispatch_source_t frameTimer;
@property(nonatomic, copy) ViewportSurfaceFrameHandler handler;
@property(nonatomic, assign) BOOL usesDamageCallbacks;
@property(nonatomic, assign) CFAbsoluteTime lastPresentTime;
@property(nonatomic, assign) NSTimeInterval minimumPresentInterval;
@end

@implementation ViewportSurfaceSubscription
@end

static id MainDisplayRenderable(id ioClient) {
  NSArray *ports = ((NSArray *(*)(id, SEL))objc_msgSend)(
    ioClient,
    sel_registerName("ioPorts"));
  Protocol *renderableProtocol = NSProtocolFromString(@"SimDisplayIOSurfaceRenderable");
  Protocol *displayProtocol = NSProtocolFromString(@"SimDisplayRenderable");
  for (id port in ports) {
    id descriptor = ((id (*)(id, SEL))objc_msgSend)(
      port,
      sel_registerName("descriptor"));
    if (!descriptor) {
      continue;
    }
    if (displayProtocol && ![descriptor conformsToProtocol:displayProtocol]) {
      continue;
    }
    if (renderableProtocol && ![descriptor conformsToProtocol:renderableProtocol]) {
      continue;
    }
    if (![descriptor respondsToSelector:sel_registerName("state")]) {
      continue;
    }
    id state = ((id (*)(id, SEL))objc_msgSend)(
      descriptor,
      sel_registerName("state"));
    if ([state respondsToSelector:sel_registerName("displayClass")]) {
      unsigned short displayClass = ((unsigned short (*)(id, SEL))objc_msgSend)(
        state,
        sel_registerName("displayClass"));
      // 0 is the main display.
      if (displayClass != 0) {
        continue;
      }
    }
    return descriptor;
  }
  return nil;
}

static IOSurfaceRef CurrentFramebufferSurface(id renderable) {
  if ([renderable respondsToSelector:sel_registerName("framebufferSurface")]) {
    return (__bridge IOSurfaceRef)((id (*)(id, SEL))objc_msgSend)(
      renderable,
      sel_registerName("framebufferSurface"));
  }
  if ([renderable respondsToSelector:sel_registerName("ioSurface")]) {
    return (__bridge IOSurfaceRef)((id (*)(id, SEL))objc_msgSend)(
      renderable,
      sel_registerName("ioSurface"));
  }
  return NULL;
}

static void PresentCurrentSurface(ViewportSurfaceSubscription *subscription, BOOL force) {
  if (!subscription.handler) {
    return;
  }
  if (!force && subscription.minimumPresentInterval > 0) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if ((now - subscription.lastPresentTime) < subscription.minimumPresentInterval) {
      return;
    }
    subscription.lastPresentTime = now;
  } else {
    subscription.lastPresentTime = CFAbsoluteTimeGetCurrent();
  }
  IOSurfaceRef surface = CurrentFramebufferSurface(subscription.renderable);
  if (surface) {
    subscription.handler(surface);
  }
}

void *ViewportSurfaceSubscribe(
  NSString *udid,
  dispatch_queue_t queue,
  unsigned int frameRate,
  ViewportSurfaceFrameHandler handler,
  char *errorBuffer,
  size_t errorBufferLength) {
  if (!ViewportHIDLoadFrameworks()) {
    StoreError(errorBuffer, errorBufferLength, @"Could not load CoreSimulator or SimulatorKit");
    return NULL;
  }

  NSError *error = nil;
  id device = BootedDevice(udid, &error);
  if (!device) {
    StoreError(
      errorBuffer,
      errorBufferLength,
      error.localizedDescription ?: @"The selected iOS Simulator is not booted");
    return NULL;
  }

  id ioClient = nil;
  if ([device respondsToSelector:sel_registerName("io")]) {
    ioClient = ((id (*)(id, SEL))objc_msgSend)(device, sel_registerName("io"));
  }
  if (!ioClient) {
    Class ioClass = objc_getClass("SimDeviceIOClient");
    if (!ioClass) {
      ioClass = objc_getClass("SimDeviceIO");
    }
    if (ioClass && [ioClass respondsToSelector:sel_registerName("ioForSimDevice:errorQueue:errorHandler:")]) {
      ioClient = ((id (*)(Class, SEL, id, dispatch_queue_t, id))objc_msgSend)(
        ioClass,
        sel_registerName("ioForSimDevice:errorQueue:errorHandler:"),
        device,
        queue,
        ^(NSError *ioError) {
          NSLog(@"Viewport surface IO error: %@", ioError);
        });
    }
  }
  if (!ioClient) {
    StoreError(errorBuffer, errorBufferLength, @"Simulator device IO is unavailable");
    return NULL;
  }
  if ([ioClient respondsToSelector:sel_registerName("updateIOPorts")]) {
    ((void (*)(id, SEL))objc_msgSend)(ioClient, sel_registerName("updateIOPorts"));
  }

  id renderable = MainDisplayRenderable(ioClient);
  if (!renderable) {
    StoreError(errorBuffer, errorBufferLength, @"Could not find the simulator main display surface");
    return NULL;
  }

  ViewportSurfaceSubscription *subscription = [ViewportSurfaceSubscription new];
  subscription.device = device;
  subscription.ioClient = ioClient;
  subscription.renderable = renderable;
  subscription.queue = queue;
  subscription.handler = handler;
  subscription.callbackUUID = [NSUUID UUID];

  unsigned int effectiveFrameRate = MAX(1, MIN(frameRate, 120));
  subscription.minimumPresentInterval = 1.0 / (NSTimeInterval)effectiveFrameRate;

  __weak ViewportSurfaceSubscription *weakSubscription = subscription;
  void (^surfaceCallback)(IOSurfaceRef, IOSurfaceRef) = ^(IOSurfaceRef next, IOSurfaceRef previous) {
    (void)previous;
    ViewportSurfaceSubscription *strong = weakSubscription;
    if (!strong || !strong.handler || !strong.queue) {
      return;
    }
    IOSurfaceRef surface = next ?: CurrentFramebufferSurface(strong.renderable);
    if (!surface) {
      return;
    }
    // Serialize presents / lastPresentTime with the frame timer on subscription.queue.
    CFRetain(surface);
    dispatch_async(strong.queue, ^{
      if (strong.handler) {
        // Surface replacements should present immediately.
        strong.lastPresentTime = CFAbsoluteTimeGetCurrent();
        strong.handler(surface);
      }
      CFRelease(surface);
    });
  };

  SEL registerSurface = sel_registerName("registerCallbackWithUUID:ioSurfacesChangeCallback:");
  if (![renderable respondsToSelector:registerSurface]) {
    StoreError(errorBuffer, errorBufferLength, @"Simulator surface callbacks are unavailable");
    return NULL;
  }
  ((void (*)(id, SEL, NSUUID *, id))objc_msgSend)(
    renderable,
    registerSurface,
    subscription.callbackUUID,
    surfaceCallback);

  // Prefer damage-rect callbacks (idb-style) for per-frame updates; the surface
  // callback only fires when the backing IOSurface is replaced.
  SEL registerDamage = sel_registerName("registerCallbackWithUUID:damageRectanglesCallback:");
  if ([renderable respondsToSelector:registerDamage]) {
    void (^damageCallback)(NSArray *) = ^(NSArray *rects) {
      (void)rects;
      ViewportSurfaceSubscription *strong = weakSubscription;
      if (!strong || !strong.queue) {
        return;
      }
      // Simulator may invoke this off subscription.queue; hop so PresentCurrentSurface
      // does not race the timer on lastPresentTime.
      dispatch_async(strong.queue, ^{
        PresentCurrentSurface(strong, NO);
      });
    };
    ((void (*)(id, SEL, NSUUID *, id))objc_msgSend)(
      renderable,
      registerDamage,
      subscription.callbackUUID,
      damageCallback);
    subscription.usesDamageCallbacks = YES;
  }

  IOSurfaceRef initial = CurrentFramebufferSurface(renderable);
  if (initial) {
    dispatch_async(queue, ^{
      PresentCurrentSurface(subscription, YES);
    });
  }

  // With damage callbacks: low-rate heartbeat for stall recovery.
  // Without them: poll at the requested cadence (IOSurface is often reused).
  unsigned int timerFPS = subscription.usesDamageCallbacks
    ? kDamageHeartbeatFPS
    : effectiveFrameRate;
  uint64_t interval = NSEC_PER_SEC / MAX(1, timerFPS);
  dispatch_source_t timer = dispatch_source_create(
    DISPATCH_SOURCE_TYPE_TIMER,
    0,
    0,
    queue);
  subscription.frameTimer = timer;
  dispatch_source_set_timer(
    timer,
    dispatch_time(DISPATCH_TIME_NOW, interval),
    interval,
    MIN(interval / 8, 2 * NSEC_PER_MSEC));
  dispatch_source_set_event_handler(timer, ^{
    PresentCurrentSurface(subscription, subscription.usesDamageCallbacks);
  });
  dispatch_resume(timer);

  return (__bridge_retained void *)subscription;
}

void ViewportSurfaceUnsubscribe(void *subscriptionPointer) {
  if (!subscriptionPointer) {
    return;
  }
  ViewportSurfaceSubscription *subscription =
    (__bridge_transfer ViewportSurfaceSubscription *)subscriptionPointer;
  if (subscription.frameTimer) {
    dispatch_source_cancel(subscription.frameTimer);
    subscription.frameTimer = nil;
  }
  id renderable = subscription.renderable;
  NSUUID *uuid = subscription.callbackUUID;
  if (renderable && uuid) {
    if (subscription.usesDamageCallbacks) {
      SEL unregisterDamage = sel_registerName("unregisterDamageRectanglesCallbackWithUUID:");
      if ([renderable respondsToSelector:unregisterDamage]) {
        ((void (*)(id, SEL, NSUUID *))objc_msgSend)(renderable, unregisterDamage, uuid);
      }
    }
    SEL unregisterSurface = sel_registerName("unregisterIOSurfacesChangeCallbackWithUUID:");
    if ([renderable respondsToSelector:unregisterSurface]) {
      ((void (*)(id, SEL, NSUUID *))objc_msgSend)(renderable, unregisterSurface, uuid);
    } else {
      SEL generic = sel_registerName("unregisterCallbackWithUUID:");
      if ([renderable respondsToSelector:generic]) {
        ((void (*)(id, SEL, NSUUID *))objc_msgSend)(renderable, generic, uuid);
      }
    }
  }
  subscription.handler = nil;
}

