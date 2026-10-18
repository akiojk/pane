#import "VirtualDisplayPrivate.h"
#import <dlfcn.h>
#import <math.h>
#import <string.h>

// Private WindowServer API. Stable enough that display tools use it, but it is
// not a public SDK contract and is unfit for the App Store.
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width
                       height:(unsigned int)height
                  refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic) unsigned int hiDPI;
@property (strong, nonatomic) NSArray *modes;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int serialNumber;
@property (strong, nonatomic) NSString *name;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@end

@interface CGVirtualDisplay : NSObject
- (nullable instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (readonly, nonatomic) unsigned int displayID;
@end

@implementation PaneVirtualDisplay {
    CGVirtualDisplay *_display;
}

- (instancetype)initWithName:(NSString *)name
                       width:(uint32_t)width
                      height:(uint32_t)height
                 refreshRate:(double)refreshRate
                    vendorID:(uint32_t)vendorID
                   productID:(uint32_t)productID
                serialNumber:(uint32_t)serialNumber
           sizeInMillimeters:(CGSize)sizeInMillimeters
                       hiDPI:(BOOL)hiDPI {
    self = [super init];
    if (!self) {
        return nil;
    }
    if (width < 2 || height < 2 || refreshRate < 1) {
        return nil;
    }

    CGVirtualDisplayDescriptor *descriptor = [CGVirtualDisplayDescriptor new];
    descriptor.name = name;
    descriptor.vendorID = vendorID;
    descriptor.productID = productID;
    descriptor.serialNum = serialNumber;
    descriptor.serialNumber = serialNumber;
    descriptor.maxPixelsWide = width;
    descriptor.maxPixelsHigh = height;
    descriptor.sizeInMillimeters = sizeInMillimeters;

    CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
    if (!display) {
        return nil;
    }

    NSMutableArray *modes = [NSMutableArray array];
    CGVirtualDisplayMode *full = [[CGVirtualDisplayMode alloc] initWithWidth:width
                                                                      height:height
                                                                 refreshRate:refreshRate];
    [modes addObject:full];
    if (hiDPI) {
        CGVirtualDisplayMode *half = [[CGVirtualDisplayMode alloc] initWithWidth:width / 2
                                                                          height:height / 2
                                                                     refreshRate:refreshRate];
        [modes addObject:half];
    }

    CGVirtualDisplaySettings *settings = [CGVirtualDisplaySettings new];
    settings.hiDPI = hiDPI ? 1u : 0u;
    settings.modes = modes;
    if (![display applySettings:settings]) {
        return nil;
    }

    _display = display;
    return self;
}

- (CGDirectDisplayID)displayID {
    return _display.displayID;
}

@end

typedef int (*PaneModeCountFunction)(CGDirectDisplayID, int *);
typedef int (*PaneModeDescriptionFunction)(CGDirectDisplayID, int, void *, int);
typedef int (*PaneModeSetFunction)(CGDisplayConfigRef, CGDirectDisplayID, int32_t);

static void PaneReadMode(const uint8_t *raw, uint32_t *number, uint32_t *flags, uint32_t *width, uint32_t *height, uint16_t *refresh, float *density) {
    memcpy(number, raw + 0, 4);
    memcpy(flags, raw + 4, 4);
    memcpy(width, raw + 8, 4);
    memcpy(height, raw + 12, 4);
    memcpy(refresh, raw + 190, 2);
    memcpy(density, raw + 208, 4);
}

BOOL PaneConfigureVirtualDisplay(CGDirectDisplayID displayID,
                                 uint32_t pixelWidth,
                                 uint32_t pixelHeight,
                                 double refreshRate,
                                 BOOL hiDPI,
                                 PaneDisplayGeometry *geometryOut) {
    if (displayID == 0 || pixelWidth < 2 || pixelHeight < 2) {
        return NO;
    }
    PaneModeCountFunction modeCount = dlsym(RTLD_DEFAULT, "CGSGetNumberOfDisplayModes");
    PaneModeDescriptionFunction modeDescription = dlsym(RTLD_DEFAULT, "CGSGetDisplayModeDescriptionOfLength");
    PaneModeSetFunction setMode = dlsym(RTLD_DEFAULT, "CGSConfigureDisplayMode");
    if (!modeCount || !modeDescription || !setMode) {
        return NO;
    }

    int count = 0;
    if (modeCount(displayID, &count) != 0 || count <= 0) {
        return NO;
    }

    const uint32_t wantWidth = hiDPI ? pixelWidth / 2 : pixelWidth;
    const uint32_t wantHeight = hiDPI ? pixelHeight / 2 : pixelHeight;
    int32_t chosenNumber = -1;
    float chosenDensity = hiDPI ? 2.f : 1.f;
    int chosenRefreshDistance = 100000;
    uint16_t chosenRefresh = 0;

    for (int index = 0; index < count; index++) {
        uint8_t raw[256];
        memset(raw, 0, sizeof(raw));
        if (modeDescription(displayID, index, raw, 212) != 0) {
            continue;
        }
        uint32_t number = 0, flags = 0, width = 0, height = 0;
        uint16_t refresh = 0;
        float density = 0;
        PaneReadMode(raw, &number, &flags, &width, &height, &refresh, &density);
        if ((flags & 0x40000000u) != 0) {
            continue;
        }
        if (width != wantWidth || height != wantHeight) {
            continue;
        }
        if (hiDPI && density < 1.5f) {
            continue;
        }
        if (!hiDPI && density > 1.25f) {
            continue;
        }
        int distance = (int)llabs((long long)refresh - (long long)llround(refreshRate));
        if (chosenNumber < 0 || distance < chosenRefreshDistance) {
            chosenNumber = (int32_t)number;
            chosenDensity = density > 0.1f ? density : (hiDPI ? 2.f : 1.f);
            chosenRefreshDistance = distance;
            chosenRefresh = refresh;
        }
    }
    if (chosenNumber < 0) {
        return NO;
    }

    CGDisplayConfigRef config = NULL;
    if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess || !config) {
        return NO;
    }
    setMode(config, displayID, chosenNumber);
    CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay);
    CGRect mainBounds = CGDisplayBounds(CGMainDisplayID());
    CGConfigureDisplayOrigin(config, displayID, (int32_t)llround(CGRectGetMaxX(mainBounds)), (int32_t)llround(CGRectGetMinY(mainBounds)));
    if (CGCompleteDisplayConfiguration(config, kCGConfigureForSession) != kCGErrorSuccess) {
        return NO;
    }

    CGRect bounds = CGDisplayBounds(displayID);
    if (bounds.size.width < 2 || bounds.size.height < 2) {
        return NO;
    }
    if (geometryOut) {
        geometryOut->pointWidth = (uint32_t)llround(bounds.size.width);
        geometryOut->pointHeight = (uint32_t)llround(bounds.size.height);
        geometryOut->pixelWidth = (uint32_t)llround(bounds.size.width * chosenDensity);
        geometryOut->pixelHeight = (uint32_t)llround(bounds.size.height * chosenDensity);
        geometryOut->refreshRate = chosenRefresh;
    }
    return YES;
}
