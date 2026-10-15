#import <Foundation/Foundation.h>
void *MTCreateWindowDisplay(unsigned int width, unsigned int height);
unsigned int MTWindowDisplayID(void *object);
void MTReleaseWindowDisplay(void *object);
