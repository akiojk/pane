#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(uint8_t, PaneGesturePhase) {
    PaneGesturePhaseBegan = 1,
    PaneGesturePhaseChanged = 2,
    PaneGesturePhaseEnded = 3,
    PaneGesturePhaseCancelled = 4,
};

/// Posts a trackpad pinch through the private gesture event type, so apps receive
/// NSEventTypeMagnify exactly as from a trackpad. `magnification` is the change for this step,
/// for example 0.05 for 5% larger. `location` is in global display points.
/// As with a real trackpad, the pinch goes to the key window under the pointer.
void PanePostMagnify(CGPoint location, PaneGesturePhase phase, double magnification);

NS_ASSUME_NONNULL_END
