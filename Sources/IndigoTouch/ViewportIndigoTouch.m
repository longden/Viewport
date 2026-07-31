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
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>

static const unsigned long long kSimDeviceStateBooted = 3;

static void StoreError(char *buffer, size_t length, NSString *message) {
  if (!buffer || length == 0) {
    return;
  }
  const char *utf8 = message.UTF8String ?: "Unknown HID error";
  strncpy(buffer, utf8, length - 1);
  buffer[length - 1] = '\0';
}

BOOL ViewportHIDLoadFrameworks(void) {
  NSBundle *coreSimulator = [NSBundle
    bundleWithPath:@"/Library/Developer/PrivateFrameworks/CoreSimulator.framework"];
  if (![coreSimulator load]) {
    return NO;
  }

  NSString *developerDirectory = NSProcessInfo.processInfo.environment[@"DEVELOPER_DIR"];
  if (developerDirectory.length == 0) {
    developerDirectory = @"/Applications/Xcode.app/Contents/Developer";
  }
  NSString *simulatorKitPath = [[developerDirectory
    stringByAppendingPathComponent:@"Library/PrivateFrameworks"]
    stringByAppendingPathComponent:@"SimulatorKit.framework"];
  return [[NSBundle bundleWithPath:simulatorKitPath] load];
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

  NSString *developerDirectory = NSProcessInfo.processInfo.environment[@"DEVELOPER_DIR"];
  if (developerDirectory.length == 0) {
    developerDirectory = @"/Applications/Xcode.app/Contents/Developer";
  }
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
    static const int moveTypes[] = {6, 5, 7, 8};
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
