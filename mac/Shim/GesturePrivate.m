#import <Foundation/Foundation.h>
#import "GesturePrivate.h"

// Private WindowServer event layout for trackpad gestures. The same field numbers are used by
// Hammerspoon and by calftrail's TouchEvents, which reverse engineered them.
static const CGEventField PaneFieldGestureHIDType = (CGEventField)110;
static const CGEventField PaneFieldGestureZoomValue = (CGEventField)113;
static const CGEventField PaneFieldGesturePhase = (CGEventField)132;

static const uint32_t PaneEventTypeGesture = 29;

// IOHIDEventType values carried in the gesture event.
static const int64_t PaneHIDTypeZoom = 8;
static const int64_t PaneHIDTypeBeginGesture = 61;
static const int64_t PaneHIDTypeEndGesture = 62;

static void PanePostRaw(CGPoint location, int64_t hidType, int64_t phase, double zoom) {
    CGEventRef event = CGEventCreate(NULL);
    if (!event) {
        return;
    }
    CGEventSetType(event, (CGEventType)PaneEventTypeGesture);
    CGEventSetLocation(event, location);
    if (hidType != 0) {
        CGEventSetIntegerValueField(event, PaneFieldGestureHIDType, hidType);
    }
    if (phase != 0) {
        CGEventSetIntegerValueField(event, PaneFieldGesturePhase, phase);
    }
    if (hidType == PaneHIDTypeZoom) {
        CGEventSetDoubleValueField(event, PaneFieldGestureZoomValue, zoom);
    }
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

// Gesture phases as AppKit expects them: began 1, changed 2, ended 4, cancelled 8.
// Each gesture event has to be followed by an empty gesture event, or AppKit never delivers it.
static void PanePostGesture(CGPoint location, int64_t hidType, int64_t phase, double zoom) {
    PanePostRaw(location, hidType, phase, zoom);
    PanePostRaw(location, 0, 0, 0);
}

void PanePostMagnify(CGPoint location, PaneGesturePhase phase, double magnification) {
    switch (phase) {
        case PaneGesturePhaseBegan:
            PanePostGesture(location, PaneHIDTypeBeginGesture, 0, 0);
            PanePostGesture(location, PaneHIDTypeZoom, 1, magnification);
            break;
        case PaneGesturePhaseChanged:
            PanePostGesture(location, PaneHIDTypeZoom, 2, magnification);
            break;
        case PaneGesturePhaseEnded:
            PanePostGesture(location, PaneHIDTypeZoom, 4, 0);
            PanePostGesture(location, PaneHIDTypeEndGesture, 0, 0);
            break;
        case PaneGesturePhaseCancelled:
            PanePostGesture(location, PaneHIDTypeZoom, 8, 0);
            PanePostGesture(location, PaneHIDTypeEndGesture, 0, 0);
            break;
    }
}
