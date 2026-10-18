// PaneAudio: a Core Audio server plug-in that adds a "Pane" output device.
//
// The device has one stereo output stream and a volume control, and keeps time like real
// hardware so apps can play to it. It discards the samples itself. Pane captures what apps play
// and streams it to the tablet whenever this device is the selected output.

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <stddef.h>
#include <string.h>

enum {
    kObjectPlugIn = kAudioObjectPlugInObject,
    kObjectDevice = 2,
    kObjectStream = 3,
    kObjectVolume = 4,
};

static const Float64 kSampleRate = 48000.0;
static const UInt32 kChannels = 2;
static const UInt32 kZeroTimeStampPeriod = 16384;
static const Float32 kMinDecibels = -64.0f;
static const Float32 kMaxDecibels = 0.0f;

#define kDeviceUID CFSTR("app.pane.audio.device")
#define kModelUID CFSTR("app.pane.audio.model")
#define kDeviceName CFSTR("Pane")
#define kManufacturer CFSTR("Pane")

static pthread_mutex_t gMutex = PTHREAD_MUTEX_INITIALIZER;
static AudioServerPlugInHostRef gHost = NULL;
static UInt32 gRefCount = 0;
static UInt32 gIOCount = 0;
static UInt64 gAnchorHostTime = 0;
static UInt64 gTimeStampCount = 0;
static Float64 gHostTicksPerFrame = 0;
static Float32 gVolumeScalar = 1.0f;

#pragma mark Interface

static HRESULT PaneAudio_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
static ULONG PaneAudio_AddRef(void *inDriver);
static ULONG PaneAudio_Release(void *inDriver);
static OSStatus PaneAudio_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus PaneAudio_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID);
static OSStatus PaneAudio_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus PaneAudio_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus PaneAudio_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus PaneAudio_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo);
static OSStatus PaneAudio_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo);
static Boolean PaneAudio_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress);
static OSStatus PaneAudio_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable);
static OSStatus PaneAudio_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize);
static OSStatus PaneAudio_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData);
static OSStatus PaneAudio_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, const void *inData);
static OSStatus PaneAudio_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus PaneAudio_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus PaneAudio_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed);
static OSStatus PaneAudio_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace);
static OSStatus PaneAudio_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo);
static OSStatus PaneAudio_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer);
static OSStatus PaneAudio_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    PaneAudio_QueryInterface,
    PaneAudio_AddRef,
    PaneAudio_Release,
    PaneAudio_Initialize,
    PaneAudio_CreateDevice,
    PaneAudio_DestroyDevice,
    PaneAudio_AddDeviceClient,
    PaneAudio_RemoveDeviceClient,
    PaneAudio_PerformDeviceConfigurationChange,
    PaneAudio_AbortDeviceConfigurationChange,
    PaneAudio_HasProperty,
    PaneAudio_IsPropertySettable,
    PaneAudio_GetPropertyDataSize,
    PaneAudio_GetPropertyData,
    PaneAudio_SetPropertyData,
    PaneAudio_StartIO,
    PaneAudio_StopIO,
    PaneAudio_GetZeroTimeStamp,
    PaneAudio_WillDoIOOperation,
    PaneAudio_BeginIOOperation,
    PaneAudio_DoIOOperation,
    PaneAudio_EndIOOperation,
};
static AudioServerPlugInDriverInterface *gInterfacePointer = &gInterface;
static AudioServerPlugInDriverRef gDriver = &gInterfacePointer;

/// Named in Info.plist under CFPlugInFactories.
void *PaneAudio_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    (void)inAllocator;
    if (CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return gDriver;
    }
    return NULL;
}

static HRESULT PaneAudio_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    if (inDriver != gDriver || outInterface == NULL) {
        return kAudioHardwareBadObjectError;
    }
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gMutex);
        gRefCount++;
        pthread_mutex_unlock(&gMutex);
        *outInterface = gDriver;
        result = S_OK;
    }
    CFRelease(requested);
    return result;
}

static ULONG PaneAudio_AddRef(void *inDriver) {
    if (inDriver != gDriver) return 0;
    pthread_mutex_lock(&gMutex);
    ULONG count = ++gRefCount;
    pthread_mutex_unlock(&gMutex);
    return count;
}

static ULONG PaneAudio_Release(void *inDriver) {
    if (inDriver != gDriver) return 0;
    pthread_mutex_lock(&gMutex);
    if (gRefCount > 0) gRefCount--;
    ULONG count = gRefCount;
    pthread_mutex_unlock(&gMutex);
    return count;
}

static OSStatus PaneAudio_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    if (inDriver != gDriver) return kAudioHardwareBadObjectError;
    gHost = inHost;
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    Float64 hostTicksPerSecond = (Float64)timebase.denom / (Float64)timebase.numer * 1000000000.0;
    gHostTicksPerFrame = hostTicksPerSecond / kSampleRate;
    return kAudioHardwareNoError;
}

static OSStatus PaneAudio_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID) {
    (void)inDriver; (void)inDescription; (void)inClientInfo; (void)outDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus PaneAudio_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID) {
    (void)inDriver; (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus PaneAudio_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo) {
    (void)inClientInfo;
    if (inDriver != gDriver || inDeviceObjectID != kObjectDevice) return kAudioHardwareBadObjectError;
    return kAudioHardwareNoError;
}

static OSStatus PaneAudio_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo) {
    (void)inClientInfo;
    if (inDriver != gDriver || inDeviceObjectID != kObjectDevice) return kAudioHardwareBadObjectError;
    return kAudioHardwareNoError;
}

static OSStatus PaneAudio_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return kAudioHardwareNoError;
}

static OSStatus PaneAudio_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return kAudioHardwareNoError;
}

#pragma mark Properties

static AudioStreamBasicDescription StreamFormat(void) {
    AudioStreamBasicDescription format;
    memset(&format, 0, sizeof(format));
    format.mSampleRate = kSampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    format.mBytesPerPacket = kChannels * sizeof(Float32);
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = kChannels * sizeof(Float32);
    format.mChannelsPerFrame = kChannels;
    format.mBitsPerChannel = 32;
    return format;
}

static Float32 ScalarToDecibels(Float32 scalar) {
    if (scalar < 0) scalar = 0;
    if (scalar > 1) scalar = 1;
    return kMinDecibels + scalar * (kMaxDecibels - kMinDecibels);
}

static Float32 DecibelsToScalar(Float32 decibels) {
    if (decibels < kMinDecibels) decibels = kMinDecibels;
    if (decibels > kMaxDecibels) decibels = kMaxDecibels;
    return (decibels - kMinDecibels) / (kMaxDecibels - kMinDecibels);
}

static Boolean IsKnownObject(AudioObjectID objectID) {
    return objectID == kObjectPlugIn || objectID == kObjectDevice || objectID == kObjectStream || objectID == kObjectVolume;
}

// Writes one fixed-size value, or only reports its size when outData is NULL.
#define RETURN_VALUE(type, value) do { \
    if (outDataSize) *outDataSize = sizeof(type); \
    if (outData) { \
        if (inDataSize < sizeof(type)) return kAudioHardwareBadPropertySizeError; \
        *(type *)outData = (value); \
    } \
    return kAudioHardwareNoError; \
} while (0)

#define RETURN_STRING(string) RETURN_VALUE(CFStringRef, (CFStringRef)CFRetain(string))

// Writes an array of object IDs, truncated to the caller's buffer.
static OSStatus ReturnObjects(const AudioObjectID *objects, UInt32 count, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    UInt32 bytes = count * (UInt32)sizeof(AudioObjectID);
    if (outData) {
        if (inDataSize < bytes) bytes = inDataSize - (inDataSize % sizeof(AudioObjectID));
        memcpy(outData, objects, bytes);
    }
    if (outDataSize) *outDataSize = bytes;
    return kAudioHardwareNoError;
}

/// One place for every property. With outData NULL it answers whether the property exists and its size.
static OSStatus Property(AudioObjectID objectID, const AudioObjectPropertyAddress *address, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    const AudioObjectPropertySelector selector = address->mSelector;
    const AudioObjectPropertyScope scope = address->mScope;

    switch (objectID) {
    case kObjectPlugIn:
        switch (selector) {
        case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: RETURN_VALUE(AudioClassID, kAudioPlugInClassID);
        case kAudioObjectPropertyOwner: RETURN_VALUE(AudioObjectID, kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer: RETURN_STRING(kManufacturer);
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: {
            AudioObjectID devices[] = { kObjectDevice };
            return ReturnObjects(devices, 1, inDataSize, outDataSize, outData);
        }
        case kAudioPlugInPropertyBoxList:
            return ReturnObjects(NULL, 0, inDataSize, outDataSize, outData);
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            AudioObjectID found = kAudioObjectUnknown;
            if (inQualifierDataSize == sizeof(CFStringRef) && inQualifierData) {
                CFStringRef uid = *(const CFStringRef *)inQualifierData;
                if (uid && CFStringCompare(uid, kDeviceUID, 0) == kCFCompareEqualTo) found = kObjectDevice;
            }
            RETURN_VALUE(AudioObjectID, found);
        }
        case kAudioPlugInPropertyTranslateUIDToBox: RETURN_VALUE(AudioObjectID, kAudioObjectUnknown);
        case kAudioPlugInPropertyResourceBundle: RETURN_STRING(CFSTR(""));
        }
        break;

    case kObjectDevice:
        switch (selector) {
        case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: RETURN_VALUE(AudioClassID, kAudioDeviceClassID);
        case kAudioObjectPropertyOwner: RETURN_VALUE(AudioObjectID, kObjectPlugIn);
        case kAudioObjectPropertyName: RETURN_STRING(kDeviceName);
        case kAudioObjectPropertyManufacturer: RETURN_STRING(kManufacturer);
        case kAudioObjectPropertyOwnedObjects: {
            if (scope == kAudioObjectPropertyScopeInput) return ReturnObjects(NULL, 0, inDataSize, outDataSize, outData);
            AudioObjectID owned[] = { kObjectStream, kObjectVolume };
            return ReturnObjects(owned, 2, inDataSize, outDataSize, outData);
        }
        case kAudioDevicePropertyDeviceUID: RETURN_STRING(kDeviceUID);
        case kAudioDevicePropertyModelUID: RETURN_STRING(kModelUID);
        case kAudioDevicePropertyTransportType: RETURN_VALUE(UInt32, kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyRelatedDevices: {
            AudioObjectID related[] = { kObjectDevice };
            return ReturnObjects(related, 1, inDataSize, outDataSize, outData);
        }
        case kAudioDevicePropertyClockDomain: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyDeviceIsAlive: RETURN_VALUE(UInt32, 1);
        case kAudioDevicePropertyDeviceIsRunning: {
            pthread_mutex_lock(&gMutex);
            UInt32 running = gIOCount > 0 ? 1 : 0;
            pthread_mutex_unlock(&gMutex);
            RETURN_VALUE(UInt32, running);
        }
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            RETURN_VALUE(UInt32, scope == kAudioObjectPropertyScopeInput ? 0 : 1);
        case kAudioDevicePropertyLatency: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertySafetyOffset: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyStreams: {
            if (scope == kAudioObjectPropertyScopeInput) return ReturnObjects(NULL, 0, inDataSize, outDataSize, outData);
            AudioObjectID streams[] = { kObjectStream };
            return ReturnObjects(streams, 1, inDataSize, outDataSize, outData);
        }
        case kAudioObjectPropertyControlList: {
            AudioObjectID controls[] = { kObjectVolume };
            return ReturnObjects(controls, 1, inDataSize, outDataSize, outData);
        }
        case kAudioDevicePropertyNominalSampleRate: RETURN_VALUE(Float64, kSampleRate);
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            AudioValueRange range = { kSampleRate, kSampleRate };
            RETURN_VALUE(AudioValueRange, range);
        }
        case kAudioDevicePropertyIsHidden: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyZeroTimeStampPeriod: RETURN_VALUE(UInt32, kZeroTimeStampPeriod);
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            if (outDataSize) *outDataSize = 2 * sizeof(UInt32);
            if (outData) {
                if (inDataSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                ((UInt32 *)outData)[0] = 1;
                ((UInt32 *)outData)[1] = 2;
            }
            return kAudioHardwareNoError;
        }
        case kAudioDevicePropertyPreferredChannelLayout: {
            UInt32 size = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + kChannels * sizeof(AudioChannelDescription));
            if (outDataSize) *outDataSize = size;
            if (outData) {
                if (inDataSize < size) return kAudioHardwareBadPropertySizeError;
                AudioChannelLayout *layout = (AudioChannelLayout *)outData;
                memset(layout, 0, size);
                layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
                layout->mNumberChannelDescriptions = kChannels;
                layout->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
                layout->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
            }
            return kAudioHardwareNoError;
        }
        }
        break;

    case kObjectStream:
        switch (selector) {
        case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: RETURN_VALUE(AudioClassID, kAudioStreamClassID);
        case kAudioObjectPropertyOwner: RETURN_VALUE(AudioObjectID, kObjectDevice);
        case kAudioObjectPropertyOwnedObjects: return ReturnObjects(NULL, 0, inDataSize, outDataSize, outData);
        case kAudioStreamPropertyIsActive: RETURN_VALUE(UInt32, 1);
        case kAudioStreamPropertyDirection: RETURN_VALUE(UInt32, 0);
        case kAudioStreamPropertyTerminalType: RETURN_VALUE(UInt32, kAudioStreamTerminalTypeSpeaker);
        case kAudioStreamPropertyStartingChannel: RETURN_VALUE(UInt32, 1);
        case kAudioStreamPropertyLatency: RETURN_VALUE(UInt32, 0);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            RETURN_VALUE(AudioStreamBasicDescription, StreamFormat());
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription ranged;
            ranged.mFormat = StreamFormat();
            ranged.mSampleRateRange.mMinimum = kSampleRate;
            ranged.mSampleRateRange.mMaximum = kSampleRate;
            RETURN_VALUE(AudioStreamRangedDescription, ranged);
        }
        }
        break;

    case kObjectVolume:
        switch (selector) {
        case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioLevelControlClassID);
        case kAudioObjectPropertyClass: RETURN_VALUE(AudioClassID, kAudioVolumeControlClassID);
        case kAudioObjectPropertyOwner: RETURN_VALUE(AudioObjectID, kObjectDevice);
        case kAudioObjectPropertyOwnedObjects: return ReturnObjects(NULL, 0, inDataSize, outDataSize, outData);
        case kAudioControlPropertyScope: RETURN_VALUE(AudioObjectPropertyScope, kAudioObjectPropertyScopeOutput);
        case kAudioControlPropertyElement: RETURN_VALUE(AudioObjectPropertyElement, kAudioObjectPropertyElementMain);
        case kAudioLevelControlPropertyScalarValue: {
            pthread_mutex_lock(&gMutex);
            Float32 value = gVolumeScalar;
            pthread_mutex_unlock(&gMutex);
            RETURN_VALUE(Float32, value);
        }
        case kAudioLevelControlPropertyDecibelValue: {
            pthread_mutex_lock(&gMutex);
            Float32 value = ScalarToDecibels(gVolumeScalar);
            pthread_mutex_unlock(&gMutex);
            RETURN_VALUE(Float32, value);
        }
        case kAudioLevelControlPropertyDecibelRange: {
            AudioValueRange range = { kMinDecibels, kMaxDecibels };
            RETURN_VALUE(AudioValueRange, range);
        }
        case kAudioLevelControlPropertyConvertScalarToDecibels: {
            if (outDataSize) *outDataSize = sizeof(Float32);
            if (outData) {
                if (inDataSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
                *(Float32 *)outData = ScalarToDecibels(*(Float32 *)outData);
            }
            return kAudioHardwareNoError;
        }
        case kAudioLevelControlPropertyConvertDecibelsToScalar: {
            if (outDataSize) *outDataSize = sizeof(Float32);
            if (outData) {
                if (inDataSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
                *(Float32 *)outData = DecibelsToScalar(*(Float32 *)outData);
            }
            return kAudioHardwareNoError;
        }
        }
        break;
    }
    return kAudioHardwareUnknownPropertyError;
}

static Boolean PaneAudio_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress) {
    (void)inClientProcessID;
    if (inDriver != gDriver || inAddress == NULL || !IsKnownObject(inObjectID)) return false;
    UInt32 size = 0;
    return Property(inObjectID, inAddress, 0, NULL, 0, &size, NULL) == kAudioHardwareNoError;
}

static OSStatus PaneAudio_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable) {
    if (inDriver != gDriver || !IsKnownObject(inObjectID)) return kAudioHardwareBadObjectError;
    if (inAddress == NULL || outIsSettable == NULL) return kAudioHardwareIllegalOperationError;
    if (!PaneAudio_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) return kAudioHardwareUnknownPropertyError;
    *outIsSettable = inObjectID == kObjectVolume &&
        (inAddress->mSelector == kAudioLevelControlPropertyScalarValue || inAddress->mSelector == kAudioLevelControlPropertyDecibelValue);
    return kAudioHardwareNoError;
}

static OSStatus PaneAudio_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize) {
    (void)inClientProcessID;
    if (inDriver != gDriver || !IsKnownObject(inObjectID)) return kAudioHardwareBadObjectError;
    if (inAddress == NULL || outDataSize == NULL) return kAudioHardwareIllegalOperationError;
    return Property(inObjectID, inAddress, inQualifierDataSize, inQualifierData, 0, outDataSize, NULL);
}

static OSStatus PaneAudio_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    (void)inClientProcessID;
    if (inDriver != gDriver || !IsKnownObject(inObjectID)) return kAudioHardwareBadObjectError;
    if (inAddress == NULL || outDataSize == NULL || outData == NULL) return kAudioHardwareIllegalOperationError;
    return Property(inObjectID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
}

static OSStatus PaneAudio_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, const void *inData) {
    (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inDriver != gDriver || !IsKnownObject(inObjectID)) return kAudioHardwareBadObjectError;
    if (inAddress == NULL || inData == NULL) return kAudioHardwareIllegalOperationError;
    if (inObjectID != kObjectVolume) return kAudioHardwareUnsupportedOperationError;
    if (inDataSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;

    Float32 scalar;
    if (inAddress->mSelector == kAudioLevelControlPropertyScalarValue) {
        scalar = *(const Float32 *)inData;
    } else if (inAddress->mSelector == kAudioLevelControlPropertyDecibelValue) {
        scalar = DecibelsToScalar(*(const Float32 *)inData);
    } else {
        return kAudioHardwareUnknownPropertyError;
    }
    if (scalar < 0) scalar = 0;
    if (scalar > 1) scalar = 1;

    pthread_mutex_lock(&gMutex);
    Boolean changed = gVolumeScalar != scalar;
    gVolumeScalar = scalar;
    pthread_mutex_unlock(&gMutex);

    if (changed && gHost) {
        AudioObjectPropertyAddress changes[] = {
            { kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
            { kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
        };
        gHost->PropertiesChanged(gHost, kObjectVolume, 2, changes);
    }
    return kAudioHardwareNoError;
}

#pragma mark IO

static OSStatus PaneAudio_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inClientID;
    if (inDriver != gDriver || inDeviceObjectID != kObjectDevice) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gMutex);
    if (gIOCount == 0) {
        gAnchorHostTime = mach_absolute_time();
        gTimeStampCount = 0;
    }
    gIOCount++;
    pthread_mutex_unlock(&gMutex);
    return kAudioHardwareNoError;
}

static OSStatus PaneAudio_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inClientID;
    if (inDriver != gDriver || inDeviceObjectID != kObjectDevice) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gMutex);
    if (gIOCount > 0) gIOCount--;
    pthread_mutex_unlock(&gMutex);
    return kAudioHardwareNoError;
}

/// Reports a timestamp every `kZeroTimeStampPeriod` frames at exactly 48 kHz of host time,
/// which is what keeps players running at the right speed.
static OSStatus PaneAudio_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    (void)inClientID;
    if (inDriver != gDriver || inDeviceObjectID != kObjectDevice) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gMutex);
    UInt64 now = mach_absolute_time();
    Float64 ticksPerPeriod = gHostTicksPerFrame * (Float64)kZeroTimeStampPeriod;
    UInt64 next = gAnchorHostTime + (UInt64)((Float64)(gTimeStampCount + 1) * ticksPerPeriod);
    if (next <= now) gTimeStampCount++;
    *outSampleTime = (Float64)(gTimeStampCount * kZeroTimeStampPeriod);
    *outHostTime = gAnchorHostTime + (UInt64)((Float64)gTimeStampCount * ticksPerPeriod);
    *outSeed = 1;
    pthread_mutex_unlock(&gMutex);
    return kAudioHardwareNoError;
}

static OSStatus PaneAudio_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace) {
    (void)inClientID; (void)inOperationID;
    if (inDriver != gDriver || inDeviceObjectID != kObjectDevice) return kAudioHardwareBadObjectError;
    // Nothing to do with the samples: Pane captures the apps' audio on its own.
    if (outWillDo) *outWillDo = false;
    if (outWillDoInPlace) *outWillDoInPlace = true;
    return kAudioHardwareNoError;
}

static OSStatus PaneAudio_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    if (inDriver != gDriver || inDeviceObjectID != kObjectDevice) return kAudioHardwareBadObjectError;
    return kAudioHardwareNoError;
}

static OSStatus PaneAudio_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer) {
    (void)inStreamObjectID; (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize;
    (void)inIOCycleInfo; (void)ioMainBuffer; (void)ioSecondaryBuffer;
    if (inDriver != gDriver || inDeviceObjectID != kObjectDevice) return kAudioHardwareBadObjectError;
    return kAudioHardwareNoError;
}

static OSStatus PaneAudio_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    if (inDriver != gDriver || inDeviceObjectID != kObjectDevice) return kAudioHardwareBadObjectError;
    return kAudioHardwareNoError;
}
