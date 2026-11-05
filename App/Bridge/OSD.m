// Shows the native macOS brightness/volume bezel via the private OSD.framework.
// Loaded at runtime so the app still works (without the bezel) if Apple
// changes or removes it.
//
// SPDX-License-Identifier: MIT

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>
#include "Mando-Bridging-Header.h"

bool MandoShowOSD(uint32_t displayID, long long image, uint32_t filled, uint32_t total) {
    static id manager = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/OSD.framework/OSD", RTLD_LAZY);
        Class cls = NSClassFromString(@"OSDManager");
        SEL shared = NSSelectorFromString(@"sharedManager");
        if (cls && [cls respondsToSelector:shared]) {
            manager = ((id (*)(id, SEL))objc_msgSend)(cls, shared);
        }
    });
    SEL sel = NSSelectorFromString(@"showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:");
    if (!manager || ![manager respondsToSelector:sel]) return false;
    ((void (*)(id, SEL, long long, unsigned int, unsigned int, unsigned int, unsigned int, unsigned int, BOOL))objc_msgSend)(
        manager, sel, image, displayID, 0x1F4, 1000, filled, total, NO);
    return true;
}
