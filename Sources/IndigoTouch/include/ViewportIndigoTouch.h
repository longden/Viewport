#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>

/// Loads CoreSimulator and SimulatorKit from the active Xcode installation.
FOUNDATION_EXPORT BOOL ViewportHIDLoadFrameworks(void);

/// Sends one touch phase through a short-lived HID client. Recreating the
/// client avoids a SimulatorKit deadlock seen when Xcode 26.5 reuses a client.
FOUNDATION_EXPORT BOOL ViewportHIDSendTouch(
  NSString *_Nonnull udid,
  double xRatio,
  double yRatio,
  int phase,
  char *_Nonnull errorBuffer,
  size_t errorBufferLength);

FOUNDATION_EXPORT BOOL ViewportHIDSendKeyboard(
  NSString *_Nonnull udid,
  unsigned int hidUsage,
  BOOL keyDown,
  char *_Nonnull errorBuffer,
  size_t errorBufferLength);

/// Opens one HID connection for a booted simulator.
FOUNDATION_EXPORT void *_Nullable ViewportHIDSessionOpen(
  NSString *_Nonnull udid,
  char *_Nonnull errorBuffer,
  size_t errorBufferLength);

/// phase: 0 = move, 1 = down, 2 = up. Coordinates are normalized from top-left.
FOUNDATION_EXPORT BOOL ViewportHIDSessionSendTouch(
  void *_Nonnull session,
  double xRatio,
  double yRatio,
  int phase,
  char *_Nonnull errorBuffer,
  size_t errorBufferLength);

/// Sends a USB HID keyboard usage (page 0x07).
FOUNDATION_EXPORT BOOL ViewportHIDSessionSendKeyboard(
  void *_Nonnull session,
  unsigned int hidUsage,
  BOOL keyDown,
  char *_Nonnull errorBuffer,
  size_t errorBufferLength);

FOUNDATION_EXPORT void ViewportHIDSessionClose(void *_Nullable session);

/// Callback for SimulatorKit framebuffer surface changes.
/// `surface` is the latest unmasked framebuffer (may be NULL while reconnecting).
typedef void (^ViewportSurfaceFrameHandler)(IOSurfaceRef _Nullable surface);

/// Subscribes to the booted simulator's main display IOSurface.
/// Returns an opaque subscription handle, or NULL on failure.
FOUNDATION_EXPORT void *_Nullable ViewportSurfaceSubscribe(
  NSString *_Nonnull udid,
  dispatch_queue_t _Nonnull queue,
  unsigned int frameRate,
  ViewportSurfaceFrameHandler _Nonnull handler,
  char *_Nonnull errorBuffer,
  size_t errorBufferLength);

FOUNDATION_EXPORT void ViewportSurfaceUnsubscribe(void *_Nullable subscription);
