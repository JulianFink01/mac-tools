#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
// Compatibility for CGWarp's source-less suppression; see the scoped caller.
CGError MTSetCursorWarpSuppression(CFTimeInterval interval);
void *MTCreateWindowDisplay(unsigned int width, unsigned int height);
void *MTCreateWindowDisplayWithScale(unsigned int width, unsigned int height, BOOL retina);
unsigned int MTWindowDisplayID(void *object);
void MTReleaseWindowDisplay(void *object);
// The fork child executes C only, then replaces itself immediately with SSH.
int MTStartTerminal(int *master, const char *executable, char *const argv[], char *const envp[], unsigned short columns, unsigned short rows);
void MTResizeTerminal(int master, unsigned short columns, unsigned short rows);
