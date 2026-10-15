#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
// Compatibility for CGWarp's source-less suppression; see the scoped caller.
CGError MTSetCursorWarpSuppression(CFTimeInterval interval);
void *MTCreateWindowDisplay(unsigned int width, unsigned int height);
unsigned int MTWindowDisplayID(void *object);
void MTReleaseWindowDisplay(void *object);
