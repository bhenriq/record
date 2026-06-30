// TapBridge.m — ObjC implementation of tap creation wrapper

#include "TapBridge.h"
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <Foundation/Foundation.h>

OSStatus TapBridgeCreate(const char *tapName, const char *uuidStr, AudioObjectID *outTapID) {
    @autoreleasepool {
        NSString *name = [NSString stringWithUTF8String:tapName];
        NSUUID   *uuid = [[NSUUID alloc] initWithUUIDString:[NSString stringWithUTF8String:uuidStr]];

        CATapDescription *tapDesc = [[CATapDescription alloc]
            initStereoGlobalTapButExcludeProcesses:@[]];
        tapDesc.name = name;
        tapDesc.UUID = uuid;

        if (@available(macOS 14.2, *)) {
            return AudioHardwareCreateProcessTap(tapDesc, outTapID);
        } else {
            return kAudioHardwareBadPropertySizeError;
        }
    }
}
