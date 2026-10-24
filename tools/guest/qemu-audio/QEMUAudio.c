/*
 * QEMUAudio.driver: a CoreAudio HAL (AudioServerPlugIn) driver for the iOS
 * guest, loaded by mediaserverd from /System/Library/Audio/Plug-Ins/HAL.
 *
 * iOS routes all audio through VirtualAudio.plugin, which builds its virtual
 * devices (VirtualAudioDevice_Default, ...) out of the physical HAL devices
 * it recognises. It classifies a physical device by its UID alone
 * (DeviceManager -> factory comparing the UID with "Codec", "Speaker",
 * "USB Audio Output", ...), so this driver publishes one output device whose
 * UID is "Codec", the built-in codec of the iPhone X profile. VirtualAudio
 * only accepts a codec that also has input streams (SubPortPolicy.cpp: "The
 * HAL returned input stream size of %u"), so there is a microphone stream
 * too; it records silence. It also needs output volume and mute: the HAL
 * answers a device's 'vold'/'mute' from its control objects.
 *
 * Step 1: the device runs on its own clock (host time at 48 kHz) and only
 * measures what it is given (peak level once a second in the log). Step 2
 * hands the samples to the kernel's virtio-sound driver.
 *
 * Every property we do not answer is logged once, so the log shows what
 * VirtualAudio asks of a codec. Log: /private/var/tmp/QEMUAudio.log and
 * os_log ("QEMUAudio:").
 */
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <math.h>
#include <os/log.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

enum {
	kObjPlugIn = kAudioObjectPlugInObject, kObjDevice = 2, kObjOutStream = 3, kObjInStream = 4,
	kObjVolume = 5, kObjMute = 6,	/* output volume and mute controls */
};

#define RATE		48000.0
#define CHANNELS	2
#define PERIOD		16384		/* frames between zero time stamps */
#define DEVICE_UID	"Codec"
#define MODEL_UID	"cx.lev.ios-qemu.QEMUAudio.model"
#define MIN_DB		-64.0f

static AudioServerPlugInHostRef host;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static UInt32 io_clients;
static Float64 ticks_per_frame;
static UInt64 anchor_time, period_count;
static UInt32 seed = 1;
static Float32 peak;
static UInt64 frames_seen, last_report;
static Float32 volume_db;		/* MIN_DB..0 */
static UInt32 muted;

static void qlog(const char *fmt, ...)
{
	char msg[512];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(msg, sizeof(msg), fmt, ap);
	va_end(ap);
	os_log(OS_LOG_DEFAULT, "QEMUAudio: %{public}s", msg);
	int fd = open("/private/var/tmp/QEMUAudio.log", O_WRONLY | O_APPEND | O_CREAT, 0666);
	if (fd >= 0) {
		dprintf(fd, "%s[%d] %s\n", getprogname(), getpid(), msg);
		close(fd);
	}
}

static const char *fourcc(UInt32 v, char buf[8])
{
	for (int i = 0; i < 4; i++) {
		char c = (char)(v >> (24 - 8 * i));
		buf[i] = c >= 32 && c < 127 ? c : '?';
	}
	buf[4] = 0;
	return buf;
}

/* Log each (call, object, selector, scope) we do not answer once. */
static void unknown(AudioObjectID obj, const AudioObjectPropertyAddress *a, const char *what)
{
	static struct { const char *what; AudioObjectID o; UInt32 sel, scope; } seen[256];
	static int nseen;
	pthread_mutex_lock(&lock);
	for (int i = 0; i < nseen; i++)
		if (seen[i].what == what && seen[i].o == obj && seen[i].sel == a->mSelector &&
		    seen[i].scope == a->mScope) {
			pthread_mutex_unlock(&lock);
			return;
		}
	if (nseen < 256)
		seen[nseen++] = (typeof(seen[0])){ what, obj, a->mSelector, a->mScope };
	pthread_mutex_unlock(&lock);
	char s[8], sc[8];
	qlog("%s: object %u has no '%s' (scope '%s', element %u)", what, obj,
	     fourcc(a->mSelector, s), fourcc(a->mScope, sc), a->mElement);
}

static AudioStreamBasicDescription stream_format(void)
{
	return (AudioStreamBasicDescription){
		.mSampleRate = RATE,
		.mFormatID = kAudioFormatLinearPCM,
		.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
		.mBytesPerPacket = CHANNELS * sizeof(Float32),
		.mFramesPerPacket = 1,
		.mBytesPerFrame = CHANNELS * sizeof(Float32),
		.mChannelsPerFrame = CHANNELS,
		.mBitsPerChannel = 32,
	};
}

/* ---- IUnknown ---- */

static AudioServerPlugInDriverInterface iface;
static AudioServerPlugInDriverInterface *iface_ptr = &iface;
static AudioServerPlugInDriverRef driver_ref = &iface_ptr;
static UInt32 refcount = 1;

static HRESULT QueryInterface(void *self, REFIID iid, LPVOID *out)
{
	CFUUIDRef want = CFUUIDCreateFromUUIDBytes(NULL, iid);
	Boolean ok = CFEqual(want, IUnknownUUID) || CFEqual(want, kAudioServerPlugInDriverInterfaceUUID);
	CFRelease(want);
	if (!ok) {
		*out = NULL;
		return E_NOINTERFACE;
	}
	refcount++;
	*out = driver_ref;
	return S_OK;
}

static ULONG AddRef(void *self) { return ++refcount; }
static ULONG Release(void *self) { return refcount > 1 ? --refcount : refcount; }

/* ---- driver lifecycle ---- */

static OSStatus Initialize(AudioServerPlugInDriverRef d, AudioServerPlugInHostRef h)
{
	host = h;
	mach_timebase_info_data_t tb;
	mach_timebase_info(&tb);
	ticks_per_frame = 1e9 / RATE * tb.denom / tb.numer;
	qlog("initialized: device '%s', %d ch, %.0f Hz", DEVICE_UID, CHANNELS, RATE);
	return noErr;
}

static OSStatus CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc,
			     const AudioServerPlugInClientInfo *ci, AudioObjectID *out)
{
	return kAudioHardwareUnsupportedOperationError;
}

static OSStatus DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID dev)
{
	return kAudioHardwareUnsupportedOperationError;
}

static OSStatus AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID dev,
				const AudioServerPlugInClientInfo *ci)
{
	return noErr;
}

static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID dev,
				   const AudioServerPlugInClientInfo *ci)
{
	return noErr;
}

static OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID dev,
						 UInt64 action, void *info)
{
	return noErr;
}

static OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID dev,
					       UInt64 action, void *info)
{
	return noErr;
}

/* ---- properties ---- */

static Boolean HasProperty(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid,
			   const AudioObjectPropertyAddress *a);

static OSStatus IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid,
				   const AudioObjectPropertyAddress *a, Boolean *out)
{
	if (!HasProperty(d, obj, pid, a))
		return kAudioHardwareUnknownPropertyError;
	switch (obj) {
	case kObjOutStream:
	case kObjInStream:
		*out = a->mSelector == kAudioStreamPropertyVirtualFormat ||
		       a->mSelector == kAudioStreamPropertyPhysicalFormat;
		break;
	case kObjVolume:
		*out = a->mSelector == kAudioLevelControlPropertyScalarValue ||
		       a->mSelector == kAudioLevelControlPropertyDecibelValue;
		break;
	case kObjMute:
		*out = a->mSelector == kAudioBooleanControlPropertyValue;
		break;
	default:
		*out = false;
	}
	return noErr;
}

/*
 * One table drives HasProperty, GetPropertyDataSize and GetPropertyData:
 * get() writes the value into out (if size bytes fit) and returns the
 * value's size, 0 for "no such property" or EMPTY for an empty list.
 */
#define EMPTY 0x80000000u
static UInt32 get(AudioObjectID obj, const AudioObjectPropertyAddress *a, UInt32 size, void *out)
{
	char buf[256];
	UInt32 n = 0;
#define VAL(T, v) do { T _v = (v); n = sizeof(T); memcpy(buf, &_v, n); } while (0)
#define STR(s) VAL(CFStringRef, CFSTR(s))
	switch (obj) {
	case kObjPlugIn:
		switch (a->mSelector) {
		case kAudioObjectPropertyBaseClass: VAL(AudioClassID, kAudioObjectClassID); break;
		case kAudioObjectPropertyClass: VAL(AudioClassID, kAudioPlugInClassID); break;
		case kAudioObjectPropertyOwner: VAL(AudioObjectID, kAudioObjectUnknown); break;
		case kAudioObjectPropertyManufacturer: STR("ios-qemu"); break;
		case kAudioObjectPropertyOwnedObjects:
		case kAudioPlugInPropertyDeviceList: VAL(AudioObjectID, kObjDevice); break;
		case kAudioPlugInPropertyResourceBundle: STR(""); break;
		case kAudioPlugInPropertyTranslateUIDToDevice: {
			/* the qualifier (a CFString UID) arrives in out's slot; checked by the caller */
			VAL(AudioObjectID, kObjDevice);
			break;
		}
		}
		break;
	case kObjDevice:
		switch (a->mSelector) {
		case kAudioObjectPropertyBaseClass: VAL(AudioClassID, kAudioObjectClassID); break;
		case kAudioObjectPropertyClass: VAL(AudioClassID, kAudioDeviceClassID); break;
		case kAudioObjectPropertyOwner: VAL(AudioObjectID, kObjPlugIn); break;
		case kAudioObjectPropertyName: STR("QEMU Audio"); break;
		case kAudioObjectPropertyManufacturer: STR("ios-qemu"); break;
		case kAudioDevicePropertyDeviceUID: STR(DEVICE_UID); break;
		case kAudioDevicePropertyModelUID: STR(MODEL_UID); break;
		case kAudioDevicePropertyTransportType: VAL(UInt32, kAudioDeviceTransportTypeBuiltIn); break;
		case kAudioDevicePropertyRelatedDevices: VAL(AudioObjectID, kObjDevice); break;
		case kAudioDevicePropertyClockDomain: VAL(UInt32, 0); break;
		case kAudioDevicePropertyDeviceIsAlive: VAL(UInt32, 1); break;
		case kAudioDevicePropertyDeviceIsRunning: VAL(UInt32, io_clients > 0); break;
		case kAudioDevicePropertyDeviceCanBeDefaultDevice:
		case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: VAL(UInt32, 1); break;
		case kAudioDevicePropertyLatency:
		case kAudioDevicePropertySafetyOffset: VAL(UInt32, 0); break;
		case kAudioDevicePropertyStreams:
			if (a->mScope == kAudioObjectPropertyScopeInput)
				VAL(AudioObjectID, kObjInStream);
			else if (a->mScope == kAudioObjectPropertyScopeOutput)
				VAL(AudioObjectID, kObjOutStream);
			else {
				AudioObjectID ids[2] = { kObjOutStream, kObjInStream };
				n = sizeof(ids);
				memcpy(buf, ids, n);
			}
			break;
		case kAudioObjectPropertyOwnedObjects: {
			AudioObjectID ids[4] = { kObjOutStream, kObjInStream, kObjVolume, kObjMute };
			if (a->mScope == kAudioObjectPropertyScopeInput)
				VAL(AudioObjectID, kObjInStream);
			else if (a->mScope == kAudioObjectPropertyScopeOutput) {
				ids[1] = kObjVolume;
				ids[2] = kObjMute;
				n = 3 * sizeof(AudioObjectID);
				memcpy(buf, ids, n);
			} else {
				n = sizeof(ids);
				memcpy(buf, ids, n);
			}
			break;
		}
		case kAudioObjectPropertyControlList:
			if (a->mScope == kAudioObjectPropertyScopeInput)
				n = EMPTY;
			else {
				AudioObjectID ids[2] = { kObjVolume, kObjMute };
				n = sizeof(ids);
				memcpy(buf, ids, n);
			}
			break;
		case kAudioDevicePropertyNominalSampleRate: VAL(Float64, RATE); break;
		case kAudioDevicePropertyAvailableNominalSampleRates:
			VAL(AudioValueRange, ((AudioValueRange){ RATE, RATE }));
			break;
		case kAudioDevicePropertyIsHidden: VAL(UInt32, 0); break;
		case kAudioDevicePropertyZeroTimeStampPeriod: VAL(UInt32, PERIOD); break;
		case kAudioDevicePropertyPreferredChannelsForStereo: {
			UInt32 ch[2] = { 1, 2 };
			n = sizeof(ch);
			memcpy(buf, ch, n);
			break;
		}
		case kAudioDevicePropertyPreferredChannelLayout: {
			AudioChannelLayout l = { .mChannelLayoutTag = kAudioChannelLayoutTag_Stereo };
			n = sizeof(l);
			memcpy(buf, &l, n);
			break;
		}
		}
		break;
	case kObjOutStream:
	case kObjInStream: {
		Boolean in = obj == kObjInStream;
		switch (a->mSelector) {
		case kAudioObjectPropertyBaseClass: VAL(AudioClassID, kAudioObjectClassID); break;
		case kAudioObjectPropertyClass: VAL(AudioClassID, kAudioStreamClassID); break;
		case kAudioObjectPropertyOwner: VAL(AudioObjectID, kObjDevice); break;
		case kAudioObjectPropertyName:
			if (in)
				STR("QEMU Audio Input");
			else
				STR("QEMU Audio Output");
			break;
		case kAudioObjectPropertyOwnedObjects: n = EMPTY; break;
		case kAudioStreamPropertyIsActive: VAL(UInt32, 1); break;
		case kAudioStreamPropertyDirection: VAL(UInt32, in); break;	/* 1 = input */
		case kAudioStreamPropertyTerminalType:
			VAL(UInt32, in ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker);
			break;
		case kAudioStreamPropertyStartingChannel: VAL(UInt32, 1); break;
		case kAudioStreamPropertyLatency: VAL(UInt32, 0); break;
		case kAudioStreamPropertyVirtualFormat:
		case kAudioStreamPropertyPhysicalFormat: VAL(AudioStreamBasicDescription, stream_format()); break;
		case kAudioStreamPropertyAvailableVirtualFormats:
		case kAudioStreamPropertyAvailablePhysicalFormats:
			VAL(AudioStreamRangedDescription,
			    ((AudioStreamRangedDescription){ stream_format(), { RATE, RATE } }));
			break;
		}
		break;
	}
	case kObjVolume:
	case kObjMute: {
		Boolean vol = obj == kObjVolume;
		switch (a->mSelector) {
		case kAudioObjectPropertyBaseClass:
			VAL(AudioClassID, vol ? kAudioLevelControlClassID : kAudioBooleanControlClassID);
			break;
		case kAudioObjectPropertyClass: VAL(AudioClassID, vol ? kAudioVolumeControlClassID : kAudioMuteControlClassID); break;
		case kAudioObjectPropertyOwner: VAL(AudioObjectID, kObjDevice); break;
		case kAudioObjectPropertyOwnedObjects: n = EMPTY; break;
		case kAudioControlPropertyScope: VAL(AudioObjectPropertyScope, kAudioObjectPropertyScopeOutput); break;
		case kAudioControlPropertyElement: VAL(AudioObjectPropertyElement, kAudioObjectPropertyElementMain); break;
		}
		if (n)
			break;
		if (vol)
			switch (a->mSelector) {
			case kAudioLevelControlPropertyScalarValue: VAL(Float32, 1.0f - volume_db / MIN_DB); break;
			case kAudioLevelControlPropertyDecibelValue: VAL(Float32, volume_db); break;
			case kAudioLevelControlPropertyDecibelRange:
				VAL(AudioValueRange, ((AudioValueRange){ MIN_DB, 0 }));
				break;
			/* the value to convert arrives in out; done by the caller */
			case kAudioLevelControlPropertyConvertScalarToDecibels:
			case kAudioLevelControlPropertyConvertDecibelsToScalar: VAL(Float32, 0); break;
			}
		else if (a->mSelector == kAudioBooleanControlPropertyValue)
			VAL(UInt32, muted);
		break;
	}
	}
#undef VAL
#undef STR
	if (n && n != EMPTY && out && size >= n)
		memcpy(out, buf, n);
	return n;
}

static Boolean HasProperty(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid,
			   const AudioObjectPropertyAddress *a)
{
	if (get(obj, a, 0, NULL))
		return true;
	unknown(obj, a, "HasProperty");
	return false;
}

static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid,
				    const AudioObjectPropertyAddress *a, UInt32 qsize, const void *q,
				    UInt32 *out)
{
	UInt32 n = get(obj, a, 0, NULL);
	if (!n) {
		unknown(obj, a, "GetPropertyDataSize");
		return kAudioHardwareUnknownPropertyError;
	}
	*out = n == EMPTY ? 0 : n;
	return noErr;
}

static OSStatus GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid,
				const AudioObjectPropertyAddress *a, UInt32 qsize, const void *q,
				UInt32 size, UInt32 *outsize, void *out)
{
	if (obj == kObjPlugIn && a->mSelector == kAudioPlugInPropertyTranslateUIDToDevice) {
		CFStringRef uid = qsize >= sizeof(CFStringRef) ? *(CFStringRef *)q : NULL;
		AudioObjectID dev = uid && CFEqual(uid, CFSTR(DEVICE_UID)) ? kObjDevice : kAudioObjectUnknown;
		if (size < sizeof(dev))
			return kAudioHardwareBadPropertySizeError;
		memcpy(out, &dev, sizeof(dev));
		*outsize = sizeof(dev);
		return noErr;
	}
	if (obj == kObjVolume && (a->mSelector == kAudioLevelControlPropertyConvertScalarToDecibels ||
				  a->mSelector == kAudioLevelControlPropertyConvertDecibelsToScalar)) {
		if (size < sizeof(Float32))
			return kAudioHardwareBadPropertySizeError;
		Float32 v = *(Float32 *)out;
		if (a->mSelector == kAudioLevelControlPropertyConvertScalarToDecibels)
			v = (1.0f - fminf(fmaxf(v, 0), 1)) * MIN_DB;
		else
			v = 1.0f - fminf(fmaxf(v, MIN_DB), 0) / MIN_DB;
		*(Float32 *)out = v;
		*outsize = sizeof(v);
		return noErr;
	}
	UInt32 n = get(obj, a, size, out);
	if (!n) {
		unknown(obj, a, "GetPropertyData");
		return kAudioHardwareUnknownPropertyError;
	}
	if (n == EMPTY) {
		*outsize = 0;
		return noErr;
	}
	if (size < n)
		return kAudioHardwareBadPropertySizeError;
	*outsize = n;
	/* CF values handed out are retained for the caller */
	if (n == sizeof(CFStringRef) && (a->mSelector == kAudioObjectPropertyName ||
					 a->mSelector == kAudioObjectPropertyManufacturer ||
					 a->mSelector == kAudioDevicePropertyDeviceUID ||
					 a->mSelector == kAudioDevicePropertyModelUID ||
					 a->mSelector == kAudioPlugInPropertyResourceBundle))
		CFRetain(*(CFStringRef *)out);
	return noErr;
}

static OSStatus SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid,
				const AudioObjectPropertyAddress *a, UInt32 qsize, const void *q,
				UInt32 size, const void *data)
{
	if ((obj == kObjOutStream || obj == kObjInStream) && (a->mSelector == kAudioStreamPropertyVirtualFormat ||
				     a->mSelector == kAudioStreamPropertyPhysicalFormat)) {
		/* only one format: accept it unchanged, refuse anything else */
		AudioStreamBasicDescription f = stream_format();
		if (size >= sizeof(f) && !memcmp(data, &f, sizeof(f)))
			return noErr;
		return kAudioDeviceUnsupportedFormatError;
	}
	if (size >= sizeof(Float32) && obj == kObjVolume &&
	    (a->mSelector == kAudioLevelControlPropertyScalarValue ||
	     a->mSelector == kAudioLevelControlPropertyDecibelValue)) {
		Float32 v = *(const Float32 *)data;
		volume_db = a->mSelector == kAudioLevelControlPropertyDecibelValue ?
		    fminf(fmaxf(v, MIN_DB), 0) : (1.0f - fminf(fmaxf(v, 0), 1)) * MIN_DB;
		AudioObjectPropertyAddress ch[2] = {
			{ kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
			{ kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
		};
		host->PropertiesChanged(host, kObjVolume, 2, ch);
		qlog("volume %.1f dB", volume_db);
		return noErr;
	}
	if (size >= sizeof(UInt32) && obj == kObjMute && a->mSelector == kAudioBooleanControlPropertyValue) {
		muted = *(const UInt32 *)data != 0;
		AudioObjectPropertyAddress ch = { kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal,
						  kAudioObjectPropertyElementMain };
		host->PropertiesChanged(host, kObjMute, 1, &ch);
		qlog("mute %u", muted);
		return noErr;
	}
	unknown(obj, a, "SetPropertyData");
	return kAudioHardwareUnknownPropertyError;
}

/* ---- IO ---- */

static OSStatus StartIO(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client)
{
	pthread_mutex_lock(&lock);
	if (io_clients++ == 0) {
		anchor_time = mach_absolute_time();
		period_count = 0;
		seed++;
		qlog("IO started");
	}
	pthread_mutex_unlock(&lock);
	return noErr;
}

static OSStatus StopIO(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client)
{
	pthread_mutex_lock(&lock);
	if (io_clients && --io_clients == 0)
		qlog("IO stopped after %llu frames", frames_seen);
	pthread_mutex_unlock(&lock);
	return noErr;
}

static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client,
				 Float64 *sample_time, UInt64 *host_time, UInt64 *out_seed)
{
	/* the latest period boundary at or before now, on a 48 kHz host-time clock */
	UInt64 now = mach_absolute_time();
	Float64 ticks_per_period = ticks_per_frame * PERIOD;
	UInt64 next = anchor_time + (UInt64)((period_count + 1) * ticks_per_period);
	if (now >= next)
		period_count = (UInt64)((now - anchor_time) / ticks_per_period);
	*sample_time = (Float64)period_count * PERIOD;
	*host_time = anchor_time + (UInt64)(period_count * ticks_per_period);
	*out_seed = seed;
	return noErr;
}

static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client,
				  UInt32 op, Boolean *will, Boolean *in_place)
{
	*will = op == kAudioServerPlugInIOOperationWriteMix || op == kAudioServerPlugInIOOperationReadInput;
	*in_place = true;
	return noErr;
}

static OSStatus BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client,
				 UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *ci)
{
	return noErr;
}

static OSStatus DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, AudioObjectID stream,
			      UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *ci,
			      void *main_buf, void *secondary)
{
	if (op == kAudioServerPlugInIOOperationReadInput) {
		memset(main_buf, 0, frames * CHANNELS * sizeof(Float32));	/* no microphone yet */
		return noErr;
	}
	if (op != kAudioServerPlugInIOOperationWriteMix)
		return noErr;
	const Float32 *s = main_buf;
	for (UInt32 i = 0; i < frames * CHANNELS; i++) {
		Float32 v = fabsf(s[i]);
		if (v > peak)
			peak = v;
	}
	frames_seen += frames;
	if (frames_seen - last_report >= (UInt64)RATE) {
		qlog("IO: %llu frames so far, peak %.3f in the last second", frames_seen, peak);
		last_report = frames_seen;
		peak = 0;
	}
	return noErr;
}

static OSStatus EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client,
			       UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *ci)
{
	return noErr;
}

static AudioServerPlugInDriverInterface iface = {
	NULL, QueryInterface, AddRef, Release,
	Initialize, CreateDevice, DestroyDevice, AddDeviceClient, RemoveDeviceClient,
	PerformDeviceConfigurationChange, AbortDeviceConfigurationChange,
	HasProperty, IsPropertySettable, GetPropertyDataSize, GetPropertyData, SetPropertyData,
	StartIO, StopIO, GetZeroTimeStamp, WillDoIOOperation, BeginIOOperation, DoIOOperation,
	EndIOOperation,
};

/* CFPlugIn factory named in Info.plist */
void *QEMUAudio_Create(CFAllocatorRef alloc, CFUUIDRef type)
{
	if (!CFEqual(type, kAudioServerPlugInTypeUUID))
		return NULL;
	qlog("factory called");
	return driver_ref;
}
