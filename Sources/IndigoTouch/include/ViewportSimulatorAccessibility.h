#import <Foundation/Foundation.h>

/// Keys in each element dictionary returned by ViewportAccessibilitySnapshot.
FOUNDATION_EXPORT NSString *_Nonnull const ViewportAXRoleKey;
FOUNDATION_EXPORT NSString *_Nonnull const ViewportAXSubroleKey;
FOUNDATION_EXPORT NSString *_Nonnull const ViewportAXLabelKey;
FOUNDATION_EXPORT NSString *_Nonnull const ViewportAXIdentifierKey;
FOUNDATION_EXPORT NSString *_Nonnull const ViewportAXValueKey;
FOUNDATION_EXPORT NSString *_Nonnull const ViewportAXTitleKey;
FOUNDATION_EXPORT NSString *_Nonnull const ViewportAXFrameKey;
FOUNDATION_EXPORT NSString *_Nonnull const ViewportAXDepthKey;
FOUNDATION_EXPORT NSString *_Nonnull const ViewportAXEnabledKey;

/// Depth-first accessibility snapshot of the booted Simulator's frontmost app.
/// The first element is the application; its frame is the screen in points.
/// Frames are `NSValue` rects in points with a top-left origin. Traversal stops
/// at `maximumElements` or when `timeoutSeconds` elapses (partial results).
/// Blocks the calling thread; call it off the main thread.
FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, id> *> *_Nullable ViewportAccessibilitySnapshot(
  NSString *_Nonnull udid,
  double timeoutSeconds,
  NSUInteger maximumElements,
  char *_Nonnull errorBuffer,
  size_t errorBufferLength);
