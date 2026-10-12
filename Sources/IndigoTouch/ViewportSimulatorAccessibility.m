/**
 * iOS Simulator accessibility snapshots via AccessibilityPlatformTranslation.
 *
 * The translator / bridge-token flow follows Meta idb's
 * FBSimulatorAccessibilityCommands.m (MIT), copyright Meta Platforms, Inc.
 * and affiliates. Full notices: THIRD_PARTY_NOTICES.md.
 */

#import "ViewportSimulatorAccessibility.h"
#import "SimDeviceLookup.h"

#import <AppKit/AppKit.h>
#import <dispatch/dispatch.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>

NSString *const ViewportAXRoleKey = @"role";
NSString *const ViewportAXSubroleKey = @"subrole";
NSString *const ViewportAXLabelKey = @"label";
NSString *const ViewportAXIdentifierKey = @"identifier";
NSString *const ViewportAXValueKey = @"value";
NSString *const ViewportAXTitleKey = @"title";
NSString *const ViewportAXFrameKey = @"frame";
NSString *const ViewportAXDepthKey = @"depth";
NSString *const ViewportAXEnabledKey = @"enabled";

static const NSUInteger kMaximumDepth = 48;

static void StoreAXError(char *buffer, size_t length, NSString *message) {
  if (!buffer || length == 0) {
    return;
  }
  const char *utf8 = message.UTF8String ?: "Unknown accessibility error";
  strncpy(buffer, utf8, length - 1);
  buffer[length - 1] = '\0';
}

/// Routes translator requests for each bridge token to its SimDevice.
@interface ViewportAXBridge : NSObject
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *devicesByToken;
@property (nonatomic, strong) dispatch_queue_t completionQueue;
@property (nonatomic, assign) double requestTimeout;
@end

@implementation ViewportAXBridge

- (instancetype)init {
  self = [super init];
  if (self) {
    _devicesByToken = [NSMutableDictionary dictionary];
    // Responses must not land on the thread blocked waiting for them.
    _completionQueue = dispatch_queue_create(
      "com.longden.viewport.ax-completion",
      DISPATCH_QUEUE_CONCURRENT);
    _requestTimeout = 2;
  }
  return self;
}

- (id)deviceForToken:(NSString *)token {
  @synchronized (self.devicesByToken) {
    return self.devicesByToken[token];
  }
}

- (void)setDevice:(id)device forToken:(NSString *)token {
  @synchronized (self.devicesByToken) {
    if (device) {
      self.devicesByToken[token] = device;
    } else {
      [self.devicesByToken removeObjectForKey:token];
    }
  }
}

// AXPTranslationTokenDelegateHelper
- (id)accessibilityTranslationDelegateBridgeCallbackWithToken:(NSString *)token {
  id device = [self deviceForToken:token];
  dispatch_queue_t queue = self.completionQueue;
  double timeout = self.requestTimeout;
  return ^id(id request) {
    Class responseClass = objc_getClass("AXPTranslatorResponse");
    id empty = responseClass
      ? ((id (*)(Class, SEL))objc_msgSend)(responseClass, sel_registerName("emptyResponse"))
      : nil;
    SEL send = sel_registerName("sendAccessibilityRequestAsync:completionQueue:completionHandler:");
    if (!device || ![device respondsToSelector:send]) {
      return empty;
    }
    __block id response = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    void (^handler)(id) = ^(id innerResponse) {
      response = innerResponse;
      dispatch_semaphore_signal(semaphore);
    };
    ((void (*)(id, SEL, id, dispatch_queue_t, id))objc_msgSend)(
      device, send, request, queue, handler);
    long timedOut = dispatch_semaphore_wait(
      semaphore,
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
    return (timedOut == 0 && response) ? response : empty;
  };
}

- (CGRect)accessibilityTranslationConvertPlatformFrameToSystem:(CGRect)rect
                                                     withToken:(NSString *)token {
  // Keep Simulator points; callers normalise against the application frame.
  return rect;
}

- (id)accessibilityTranslationRootParentWithToken:(NSString *)token {
  return nil;
}

@end

static ViewportAXBridge *SharedBridge(void) {
  static ViewportAXBridge *bridge = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    bridge = [[ViewportAXBridge alloc] init];
  });
  return bridge;
}

static id SharedTranslator(NSString **failure) {
  static id translator = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    NSBundle *bundle = [NSBundle bundleWithPath:
      @"/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework"];
    if (![bundle load]) {
      return;
    }
    Class translatorClass = objc_getClass("AXPTranslator");
    if (!translatorClass) {
      return;
    }
    id shared = ((id (*)(Class, SEL))objc_msgSend)(
      translatorClass, sel_registerName("sharedInstance"));
    SEL setDelegate = sel_registerName("setBridgeTokenDelegate:");
    SEL setSupportsTokens = sel_registerName("setSupportsDelegateTokens:");
    if (![shared respondsToSelector:setDelegate]
        || ![shared respondsToSelector:setSupportsTokens]) {
      return;
    }
    ((void (*)(id, SEL, id))objc_msgSend)(shared, setDelegate, SharedBridge());
    ((void (*)(id, SEL, BOOL))objc_msgSend)(shared, setSupportsTokens, YES);
    translator = shared;
  });
  if (!translator && failure) {
    *failure = @"AccessibilityPlatformTranslation is unavailable on this Mac";
  }
  return translator;
}

static NSString *StringAttribute(id value) {
  if ([value isKindOfClass:[NSString class]]) {
    NSString *string = (NSString *)value;
    return string.length > 0 ? string : nil;
  }
  if ([value isKindOfClass:[NSAttributedString class]]) {
    NSString *string = [(NSAttributedString *)value string];
    return string.length > 0 ? string : nil;
  }
  if ([value isKindOfClass:[NSNumber class]]) {
    return [(NSNumber *)value stringValue];
  }
  return nil;
}

static void AttachToken(id element, NSString *token) {
  SEL translationSelector = sel_registerName("translation");
  if (![element respondsToSelector:translationSelector]) {
    return;
  }
  id translation = ((id (*)(id, SEL))objc_msgSend)(element, translationSelector);
  SEL setToken = sel_registerName("setBridgeDelegateToken:");
  if ([translation respondsToSelector:setToken]) {
    ((void (*)(id, SEL, NSString *))objc_msgSend)(translation, setToken, token);
  }
}

static void CollectElements(
  id element,
  NSString *token,
  NSUInteger depth,
  NSUInteger maximumElements,
  CFAbsoluteTime deadline,
  NSMutableArray<NSDictionary<NSString *, id> *> *output) {
  if (output.count >= maximumElements
      || depth > kMaximumDepth
      || CFAbsoluteTimeGetCurrent() > deadline) {
    return;
  }
  AttachToken(element, token);

  NSMutableDictionary<NSString *, id> *entry = [NSMutableDictionary dictionary];
  NSRect frame = [element accessibilityFrame];
  entry[ViewportAXFrameKey] = [NSValue valueWithRect:frame];
  entry[ViewportAXDepthKey] = @(depth);
  entry[ViewportAXEnabledKey] = @([element isAccessibilityEnabled]);
  NSString *role = StringAttribute([element accessibilityRole]);
  if (role) entry[ViewportAXRoleKey] = role;
  NSString *subrole = StringAttribute([element accessibilitySubrole]);
  if (subrole) entry[ViewportAXSubroleKey] = subrole;
  NSString *label = StringAttribute([element accessibilityLabel]);
  if (label) entry[ViewportAXLabelKey] = label;
  NSString *identifier = StringAttribute([element accessibilityIdentifier]);
  if (identifier) entry[ViewportAXIdentifierKey] = identifier;
  NSString *value = StringAttribute([element accessibilityValue]);
  if (value) entry[ViewportAXValueKey] = value;
  NSString *title = StringAttribute([element accessibilityTitle]);
  if (title) entry[ViewportAXTitleKey] = title;
  [output addObject:entry];

  NSArray *children = [element accessibilityChildren];
  for (id child in children) {
    CollectElements(child, token, depth + 1, maximumElements, deadline, output);
    if (output.count >= maximumElements || CFAbsoluteTimeGetCurrent() > deadline) {
      return;
    }
  }
}

NSArray<NSDictionary<NSString *, id> *> *ViewportAccessibilitySnapshot(
  NSString *udid,
  double timeoutSeconds,
  NSUInteger maximumElements,
  char *errorBuffer,
  size_t errorBufferLength) {
  NSError *error = nil;
  id device = ViewportBootedSimDevice(udid, &error);
  if (!device) {
    StoreAXError(errorBuffer, errorBufferLength,
      error.localizedDescription ?: @"The selected iOS Simulator is not booted");
    return nil;
  }
  NSString *failure = nil;
  id translator = SharedTranslator(&failure);
  if (!translator) {
    StoreAXError(errorBuffer, errorBufferLength, failure);
    return nil;
  }

  // The translator is a process-wide singleton; one snapshot at a time.
  static dispatch_queue_t snapshotQueue;
  static dispatch_once_t queueToken;
  dispatch_once(&queueToken, ^{
    snapshotQueue = dispatch_queue_create("com.longden.viewport.ax-snapshot", DISPATCH_QUEUE_SERIAL);
  });

  __block NSArray<NSDictionary<NSString *, id> *> *result = nil;
  __block NSString *snapshotFailure = nil;
  dispatch_sync(snapshotQueue, ^{
    @autoreleasepool {
      NSString *token = [[NSUUID UUID] UUIDString];
      ViewportAXBridge *bridge = SharedBridge();
      [bridge setDevice:device forToken:token];
      bridge.requestTimeout = MIN(MAX(timeoutSeconds / 4, 0.5), 3);

      SEL frontmost = sel_registerName("frontmostApplicationWithDisplayId:bridgeDelegateToken:");
      SEL platformElement = sel_registerName("macPlatformElementFromTranslation:");
      if (![translator respondsToSelector:frontmost]
          || ![translator respondsToSelector:platformElement]) {
        snapshotFailure = @"This macOS version changed the accessibility translator";
        [bridge setDevice:nil forToken:token];
        return;
      }
      id translation = ((id (*)(id, SEL, unsigned int, NSString *))objc_msgSend)(
        translator, frontmost, 0, token);
      if (!translation) {
        snapshotFailure = @"The Simulator didn’t return an accessibility tree. Unlock it and open an app.";
        [bridge setDevice:nil forToken:token];
        return;
      }
      SEL setToken = sel_registerName("setBridgeDelegateToken:");
      if ([translation respondsToSelector:setToken]) {
        ((void (*)(id, SEL, NSString *))objc_msgSend)(translation, setToken, token);
      }
      id root = ((id (*)(id, SEL, id))objc_msgSend)(translator, platformElement, translation);
      if (!root) {
        snapshotFailure = @"The Simulator accessibility root is unavailable";
        [bridge setDevice:nil forToken:token];
        return;
      }

      NSMutableArray<NSDictionary<NSString *, id> *> *elements = [NSMutableArray array];
      CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + MAX(timeoutSeconds, 1);
      CollectElements(root, token, 0, MAX(maximumElements, 1), deadline, elements);
      [bridge setDevice:nil forToken:token];
      result = [elements copy];
    }
  });

  if (!result) {
    StoreAXError(errorBuffer, errorBufferLength,
      snapshotFailure ?: @"Accessibility snapshot failed");
  }
  return result;
}
