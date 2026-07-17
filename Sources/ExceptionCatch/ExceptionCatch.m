#import "ExceptionCatch.h"

NSException *_Nullable NutolaTryBlock(void (^_Nullable block)(void)) {
    @try {
        if (block) block();
    } @catch (NSException *exception) {
        return exception;
    }
    return nil;
}
