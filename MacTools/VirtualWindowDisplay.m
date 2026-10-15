#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import "MacToolsNative.h"
// Runtime interfaces exposed by CoreGraphics; the test owns the display's
// lifetime and removes it before it exits. No system protection is changed.
@interface CGVirtualDisplayDescriptor : NSObject
@property unsigned int vendorID, productID, serialNum, serialNumber;
@property(strong) NSString *name;
@property CGSize sizeInMillimeters;
@property unsigned int maxPixelsWide, maxPixelsHigh;
@property CGPoint redPrimary, greenPrimary, bluePrimary, whitePoint;
@property(strong) id queue;
@end
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate;
@end
@interface CGVirtualDisplaySettings : NSObject
@property unsigned int hiDPI, rotation;
@property(strong) NSArray *modes;
@end
@interface CGVirtualDisplay : NSObject
@property(readonly) unsigned int displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end
void * MTCreateWindowDisplay(unsigned int width, unsigned int height) {
    if (!NSClassFromString(@"CGVirtualDisplay")) return NULL;
    CGVirtualDisplayDescriptor *descriptor = [CGVirtualDisplayDescriptor new];
    descriptor.queue = dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0);
    descriptor.name = @"MacTools Fensterfläche";
    descriptor.maxPixelsWide = width * 2; descriptor.maxPixelsHigh = height * 2;
    descriptor.sizeInMillimeters = CGSizeMake(530, 400);
    descriptor.whitePoint = CGPointMake(.3125,.3291);
    descriptor.bluePrimary = CGPointMake(.1494,.0557);
    descriptor.greenPrimary = CGPointMake(.2559,.6983);
    descriptor.redPrimary = CGPointMake(.6797,.3203);
    descriptor.vendorID = 0x4D54; descriptor.productID = 1;
    unsigned int serial = arc4random_uniform(0xFFFFFFFE) + 1;
    descriptor.serialNum = serial; descriptor.serialNumber = serial;
    CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
    if (!display) return NULL;
    CGVirtualDisplaySettings *settings = [CGVirtualDisplaySettings new];
    settings.hiDPI = 1; settings.rotation = 0;
    settings.modes = @[[[CGVirtualDisplayMode alloc] initWithWidth:width height:height refreshRate:60]];
    if (![display applySettings:settings]) return NULL;
    return (void *)CFBridgingRetain(display);
}
unsigned int MTWindowDisplayID(void *object) { return [(__bridge CGVirtualDisplay *)object displayID]; }
void MTReleaseWindowDisplay(void *object) { if(object) CFRelease(object); }
