#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    uint32_t pointWidth;
    uint32_t pointHeight;
    uint32_t pixelWidth;
    uint32_t pixelHeight;
    uint32_t refreshRate;
} PaneDisplayGeometry;

/// Selects the retina or 1x mode, then places the display to the right of the main screen.
BOOL PaneConfigureVirtualDisplay(CGDirectDisplayID displayID,
                                 uint32_t pixelWidth,
                                 uint32_t pixelHeight,
                                 double refreshRate,
                                 BOOL hiDPI,
                                 PaneDisplayGeometry *_Nullable geometryOut);

/// Owns one virtual display created with the private CGVirtualDisplay API.
/// Releasing the object removes the display.
@interface PaneVirtualDisplay : NSObject
@property (nonatomic, readonly) CGDirectDisplayID displayID;
- (nullable instancetype)initWithName:(NSString *)name
                                 width:(uint32_t)width
                                height:(uint32_t)height
                           refreshRate:(double)refreshRate
                              vendorID:(uint32_t)vendorID
                             productID:(uint32_t)productID
                          serialNumber:(uint32_t)serialNumber
                     sizeInMillimeters:(CGSize)sizeInMillimeters
                                 hiDPI:(BOOL)hiDPI;
@end

NS_ASSUME_NONNULL_END
