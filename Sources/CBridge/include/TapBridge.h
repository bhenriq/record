// TapBridge.h — C wrapper for CoreAudio Process Tap (CATapDescription)
// Exposes the ObjC-only tap creation as C functions callable from Swift.

#ifndef TAPBRIDGE_H
#define TAPBRIDGE_H

#include <CoreAudio/CoreAudio.h>

/// Creates a stereo global process tap that captures all system audio.
/// Returns noErr on success, with a valid tapID.
/// @param tapName  C string name for the tap (e.g. "com.record.capture")
/// @param uuidStr  C string UUID (e.g. "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")
/// @param outTapID Receives the created tap's AudioObjectID
OSStatus TapBridgeCreate(const char *tapName, const char *uuidStr, AudioObjectID *outTapID);

#endif /* TAPBRIDGE_H */
