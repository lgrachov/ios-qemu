/*
 * QEMUAudio.driver: a CoreAudio HAL (AudioServerPlugIn) driver for the iOS
 * guest, loaded by mediaserverd from /System/Library/Audio/Plug-Ins/HAL.
 *
 * iOS routes all audio through VirtualAudio.plugin, which builds its virtual
 * devices (VirtualAudioDevice_Default, ...) out of the physical HAL devices
 * it recognises. It classifies a physical device by its UID alone
 * (DeviceManager -> factory comparing the UID with "Codec", "Speaker",
 * "USB Audio Output", ...), so this driver publishes devices with the UIDs of
 * the iPhone X topology: "Codec" (receiver, microphone) and "Speaker" (the
 * speaker amplifier, a device of its own).
 *
 * What VirtualAudio requires of them, found one boot at a time:
 *   - Codec: input streams (SubPortPolicy.cpp: "The HAL returned input
 *     stream size of %u"); input data sources ('ssc#', from a data source
 *     control) become microphone ports ('imic' -> "Built-In Microphone");
 *     output ports come from 'mute' controls on output elements (element 3:
 *     receiver, element 4: speaker); every port has its own volume; device
 *     volume and mute ('vold', 'mute') come from controls on element 0.
 *   - Speaker: output and telemetry data sources, a hardware volume range
 *     (Device_Speaker_Aspen.cpp).
 *
 * Step 1: the devices run on their own clock (host time at 48 kHz) and only
 * measure what they are given (peak level once a second in the log).
 *
 * VirtualAudio never routes to these devices (its routing database finds no
 * route, so everything plays into its Null_Device). QEMUAUDIO_TAP takes the
 * mix from VirtualAudio's IOProc on its "VAD Aggregate Device" instead, and
 * QEMUAUDIO_VSND writes it to the kernel's virtio-sound driver.
 *
 * Every property we do not answer is logged once, so the log shows what
 * VirtualAudio asks. Log: /private/var/tmp/QEMUAudio.log and os_log
 * ("QEMUAudio:").
 */
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <math.h>
#include <os/log.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>

#define RATE		48000.0
#define CHANNELS	2
#define PERIOD		16384		/* frames between zero time stamps */
#define MODEL_UID	"cx.lev.ios-qemu.QEMUAudio.model"
#define MIN_DB		-64.0f
/*
 * QEMUAUDIO_SPEAKER_DEVICE: the speaker port comes from a "Speaker" device
 * instead of output element 4 of the codec (2026-10-25: with the speaker on
 * the codec, every route change fails with 'nort' in VirtualAudio's routing
 * database; guess: the iPhone X database expects the separate amplifier).
 */
#define QEMUAUDIO_SPEAKER_DEVICE 1
/*
 * QEMUAUDIO_FAKE_VAD (audio-plugin.py setup --fake-vad): VirtualAudio.plugin
 * stays disabled and this driver publishes the device MediaExperience looks
 * up by UID, VirtualAudioDevice_Default, as a plain output device
 * (experiment: VirtualAudio's routing database finds no route to the codec
 * or speaker ports, 'nort').
 */
/*
 * QEMUAUDIO_HEADPHONES: the codec has a headphone jack (a jack control, which
 * the HAL turns into the device's 'jack' on the output scope: Device_Codec_Aspen
 * then makes a wired headphones port on output element 1)
 * that is plugged in a few seconds after start. VirtualAudio never re-routes
 * for new built-in ports ('ncru'), but a jack insertion is the ordinary way
 * an iPhone's route changes, so playback should follow it to our device.
 */
#define QEMUAUDIO_HEADPHONES 1
#ifndef QEMUAUDIO_FAKE_VAD
#define QEMUAUDIO_FAKE_VAD 0
#endif

/* ---- object model: one row per object, looked up by ID ---- */

enum kind { PLUGIN, DEVICE, STREAM, VOLUME, MUTE, SOURCE, JACK };

enum {
	kObjPlugIn = kAudioObjectPlugInObject,
	kObjCodec = 2, kObjCodecOut, kObjCodecIn, kObjCodecVolume, kObjCodecMute, kObjCodecInSource,
	kObjReceiverMute, kObjReceiverVolume, kObjCodecSpeakerMute, kObjCodecSpeakerVolume,
	kObjHeadphoneMute, kObjHeadphoneVolume, kObjCodecJack,
	kObjSpeaker = 20, kObjSpeakerOut, kObjSpeakerTelemetry, kObjSpeakerVolume, kObjSpeakerMute,
	kObjSpeakerOutSource, kObjSpeakerTelemetrySource,
};

struct object {
	AudioObjectID id;
	enum kind kind;
	AudioObjectID owner;
	Boolean input;			/* stream/control scope: input, else output */
	AudioObjectPropertyElement element;	/* controls */
	const char *name;		/* devices: the UID too */
	UInt32 terminal;		/* streams */
	UInt32 sources[4];		/* data sources (4cc) */
	UInt32 current[4], ncurrent;	/* state: the selected ones (all of them at first) */
	Float32 volume_db;		/* state: MIN_DB..0 */
	UInt32 muted;
};

static struct object objects[] = {
	{ kObjPlugIn, PLUGIN, kAudioObjectUnknown },
#if QEMUAUDIO_FAKE_VAD
	{ kObjCodec, DEVICE, kObjPlugIn, .name = "VirtualAudioDevice_Default" },
	{ kObjCodecOut, STREAM, kObjCodec, false, .name = "Output", .terminal = kAudioStreamTerminalTypeSpeaker },
	{ kObjCodecIn, STREAM, kObjCodec, true, .name = "Input", .terminal = kAudioStreamTerminalTypeMicrophone },
	{ kObjCodecVolume, VOLUME, kObjCodec, false, kAudioObjectPropertyElementMain },
	{ kObjCodecMute, MUTE, kObjCodec, false, kAudioObjectPropertyElementMain },
#else
	{ kObjCodec, DEVICE, kObjPlugIn, .name = "Codec" },
	{ kObjCodecOut, STREAM, kObjCodec, false, .name = "Codec Output", .terminal = kAudioStreamTerminalTypeReceiverSpeaker },
	{ kObjCodecIn, STREAM, kObjCodec, true, .name = "Codec Input", .terminal = kAudioStreamTerminalTypeMicrophone },
	{ kObjCodecVolume, VOLUME, kObjCodec, false, kAudioObjectPropertyElementMain },
	{ kObjCodecMute, MUTE, kObjCodec, false, kAudioObjectPropertyElementMain },
	{ kObjCodecInSource, SOURCE, kObjCodec, true, .sources = { 'imic' } },	/* built-in microphone */
	{ kObjReceiverMute, MUTE, kObjCodec, false, 3 },
	{ kObjReceiverVolume, VOLUME, kObjCodec, false, 3 },
#if QEMUAUDIO_HEADPHONES
	{ kObjHeadphoneMute, MUTE, kObjCodec, false, 1 },
	{ kObjHeadphoneVolume, VOLUME, kObjCodec, false, 1 },
	{ kObjCodecJack, JACK, kObjCodec, false, kAudioObjectPropertyElementMain },	/* the HAL's 'jack' */
#endif
#if !QEMUAUDIO_SPEAKER_DEVICE
	{ kObjCodecSpeakerMute, MUTE, kObjCodec, false, 4 },
	{ kObjCodecSpeakerVolume, VOLUME, kObjCodec, false, 4 },
#else
	{ kObjSpeaker, DEVICE, kObjPlugIn, .name = "Speaker" },
	{ kObjSpeakerOut, STREAM, kObjSpeaker, false, .name = "Speaker Output", .terminal = kAudioStreamTerminalTypeSpeaker },
	{ kObjSpeakerTelemetry, STREAM, kObjSpeaker, true, .name = "Speaker Telemetry", .terminal = kAudioStreamTerminalTypeLine },
	{ kObjSpeakerVolume, VOLUME, kObjSpeaker, false, kAudioObjectPropertyElementMain },
	{ kObjSpeakerMute, MUTE, kObjSpeaker, false, kAudioObjectPropertyElementMain },
	{ kObjSpeakerOutSource, SOURCE, kObjSpeaker, false, .sources = { 'spkr' } },
	/* voltage and current of the two speakers (VirtualAudio selects all four) */
	{ kObjSpeakerTelemetrySource, SOURCE, kObjSpeaker, true, .sources = { 'spV0', 'spI0', 'spV1', 'spI1' } },
#endif
#endif
};
#define NOBJECTS (sizeof(objects) / sizeof(objects[0]))

static struct object *find(AudioObjectID id)
{
	for (unsigned i = 0; i < NOBJECTS; i++)
		if (objects[i].id == id)
			return &objects[i];
	return NULL;
}

static unsigned nsources(const struct object *o)
{
	unsigned n = 0;
	while (n < 4 && o->sources[n])
		n++;
	return n;
}

static AudioServerPlugInHostRef host;
static UInt32 jack_connected;		/* QEMUAUDIO_HEADPHONES */
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static Float64 ticks_per_frame;

/* IO state per device */
struct io {
	UInt32 clients;
	UInt64 anchor_time, period_count;
	UInt32 seed;
	Float32 peak;
	UInt64 frames, last_report;
};
static struct io io_codec = { .seed = 1 }, io_speaker = { .seed = 1 };

static struct io *io_for(AudioObjectID dev)
{
	return dev == kObjSpeaker ? &io_speaker : &io_codec;
}

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

/*
 * Diagnostics (QEMUAUDIO_TRACE_VA): VirtualAudio.plugin's property reads of
 * our device fail inside the HAL without reaching us. Point VirtualAudio's
 * imports of the AudioObject* property calls at wrappers that log every
 * failure. The imports are in __got (arm64, iPhone X) or __auth_got (arm64e,
 * XS); the guest kernel keeps the PAC keys off, so both hold plain pointers.
 */
#define QEMUAUDIO_TRACE_VA 1
#if QEMUAUDIO_TRACE_VA
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <execinfo.h>

static OSStatus (*real_get)(AudioObjectID, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32 *, void *);
static OSStatus (*real_size)(AudioObjectID, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32 *);
static OSStatus (*real_set)(AudioObjectID, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32, const void *);
static Boolean (*real_has)(AudioObjectID, const AudioObjectPropertyAddress *);

static void va_fail(const char *call, AudioObjectID obj, const AudioObjectPropertyAddress *a, OSStatus err)
{
	char s[8], sc[8], e[8];
	qlog("VA %s(object %u, '%s', '%s', element %u) -> '%s' (%d)", call, obj, fourcc(a->mSelector, s),
	     fourcc(a->mScope, sc), a->mElement, fourcc((UInt32)err, e), (int)err);
}

static OSStatus va_get(AudioObjectID o, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 *sz, void *d)
{
	OSStatus err = real_get(o, a, qs, q, sz, d);
	if (err)
		va_fail("GetPropertyData", o, a, err);
	return err;
}

static OSStatus va_size(AudioObjectID o, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 *sz)
{
	OSStatus err = real_size(o, a, qs, q, sz);
	if (err)
		va_fail("GetPropertyDataSize", o, a, err);
	return err;
}

static OSStatus va_set(AudioObjectID o, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 sz, const void *d)
{
	OSStatus err = real_set(o, a, qs, q, sz, d);
	if (err)
		va_fail("SetPropertyData", o, a, err);
	return err;
}

static Boolean va_has(AudioObjectID o, const AudioObjectPropertyAddress *a)
{
	Boolean r = real_has(o, a);
	if (!r && o >= 50 && o < 100)	/* only physical devices and their objects */
		va_fail("HasProperty", o, a, 0);
	return r;
}

/* exceptions VirtualAudio throws: log the 4cc and a backtrace as offsets into VirtualAudio */
static void (*real_throw)(void *, void *, void (*)(void *));
static uintptr_t va_base;

static void va_throw(void *thrown, void *tinfo, void (*dest)(void *))
{
	UInt32 code = *(UInt32 *)((uint8_t *)thrown + 8);	/* CAException: vtable, OSStatus */
	char c[8], line[512];
	void *bt[16];
	int n = backtrace(bt, 16), off = 0;
	for (int i = 1; i < n && off < (int)sizeof(line) - 20; i++)
		off += snprintf(line + off, sizeof(line) - off, " %#lx", (uintptr_t)bt[i] - va_base);
	qlog("VA throws '%s' from:%s", fourcc(code, c), line);
	real_throw(thrown, tinfo, dest);
}

/*
 * QEMUAUDIO_TAP: VirtualAudio plays its default device through IOProcs it
 * creates on the physical device the route ends on (its imports of
 * AudioDeviceCreateIOProcID/Start/Stop). With no route but Null_Device that
 * IOProc is the only place the mix exists, so wrap it: once VirtualAudio's
 * proc has filled the output buffers, tap_output gets them (peak/RMS in the
 * log now; the next step copies them to the virtio-sound ring).
 */
#define QEMUAUDIO_TAP 1
#define TAP_REPORT	24000		/* frames between level lines */
#define TAP_SILENT	20		/* silent periods between "silent" lines */

/* AudioHardware.h (not in the iOS SDK) */
typedef OSStatus (*AudioDeviceIOProc)(AudioObjectID, const AudioTimeStamp *, const AudioBufferList *, const AudioTimeStamp *,
				      AudioBufferList *, const AudioTimeStamp *, void *);
typedef AudioDeviceIOProc AudioDeviceIOProcID;

struct tap {
	AudioDeviceIOProc proc;
	void *client;
	AudioObjectID dev;
	char name[64];
	AudioStreamBasicDescription fmt;	/* virtual format of the device's first output stream */
	UInt64 frames, calls;
	Float32 peak;
	double sumsq;
	UInt64 nsamples;
	UInt32 periods, silent;
};

/*
 * QEMUAUDIO_VSND: the tapped mix goes to the kernel's virtio-sound driver
 * (patch 0108, boot-arg sweetvsnd=1): /dev/qemuaudio takes S16 stereo at
 * 44100 Hz and never blocks (the kernel drops what does not fit), so the
 * write is safe on VirtualAudio's IO thread. Without the device (harness
 * --no-audio, kernel before 0108) open fails and is retried every ~2 s.
 */
#define QEMUAUDIO_VSND 1
#define VSND_PATH	"/dev/qemuaudio"
#define VSND_RATE	44100.0
#define VSND_FRAMES	1024		/* frames per write */

static void tap_play(struct tap *t, const AudioBufferList *out, UInt32 frames, Boolean is_float, UInt32 bits)
{
#if QEMUAUDIO_VSND
	static int fd = -1;
	static UInt64 next_open;
	static Boolean warned;
	if (t->fmt.mSampleRate && t->fmt.mSampleRate != VSND_RATE) {
		if (!warned)
			qlog("vsnd: %.0f Hz output, only %.0f Hz is played", t->fmt.mSampleRate, VSND_RATE);
		warned = true;
		return;
	}
	if (fd < 0) {
		if (t->frames < next_open)
			return;
		next_open = t->frames + 2 * (UInt64)VSND_RATE;
		fd = open(VSND_PATH, O_WRONLY | O_NONBLOCK);
		qlog("vsnd: open %s -> %d", VSND_PATH, fd);
		if (fd < 0)
			return;
	}
	/* interleaved (one buffer, 1-2 channels) or one buffer per channel */
	const AudioBuffer *l = &out->mBuffers[0];
	const AudioBuffer *r = out->mNumberBuffers > 1 ? &out->mBuffers[1] : l;
	UInt32 step = l->mNumberChannels ? l->mNumberChannels : 1, roff = r == l && step > 1 ? 1 : 0;
	if (r != l)
		step = 1;
	SInt16 pcm[VSND_FRAMES * 2];
	for (UInt32 done = 0; done < frames;) {
		UInt32 n = frames - done < VSND_FRAMES ? frames - done : VSND_FRAMES;
		for (UInt32 i = 0; i < 2 * n; i++) {
			const AudioBuffer *b = i & 1 ? r : l;
			UInt32 idx = (done + i / 2) * step + (i & 1 ? roff : 0);
			if (!b->mData || (idx + 1) * (bits / 8) > b->mDataByteSize) {
				pcm[i] = 0;
				continue;
			}
			float v = is_float ? ((const Float32 *)b->mData)[idx]
			        : bits == 16 ? ((const SInt16 *)b->mData)[idx] / 32768.0f
			        : ((const SInt32 *)b->mData)[idx] / 2147483648.0f;
			pcm[i] = v >= 1.0f ? 32767 : v <= -1.0f ? -32768 : (SInt16)lrintf(v * 32767.0f);
		}
		if (write(fd, pcm, n * 4) < 0) {
			qlog("vsnd: write failed (%d), reopening", errno);
			close(fd);
			fd = -1;
			return;
		}
		done += n;
	}
#endif
}

static void tap_output(struct tap *t, const AudioBufferList *out)
{
	UInt32 frames = 0;
	Boolean is_float = !t->fmt.mFormatID || (t->fmt.mFormatFlags & kAudioFormatFlagIsFloat);
	UInt32 bits = t->fmt.mBitsPerChannel ? t->fmt.mBitsPerChannel : 32;
	for (UInt32 b = 0; b < out->mNumberBuffers; b++) {
		const AudioBuffer *buf = &out->mBuffers[b];
		UInt32 n = buf->mDataByteSize / (bits / 8);
		if (!buf->mData || !n)
			continue;
		if (buf->mNumberChannels && n / buf->mNumberChannels > frames)
			frames = n / buf->mNumberChannels;
		for (UInt32 i = 0; i < n; i++) {
			float v = is_float ? ((const Float32 *)buf->mData)[i]
			        : bits == 16 ? ((const SInt16 *)buf->mData)[i] / 32768.0f
			        : ((const SInt32 *)buf->mData)[i] / 2147483648.0f;
			float a = fabsf(v);
			if (a > t->peak)
				t->peak = a;
			t->sumsq += (double)v * v;
		}
		t->nsamples += n;
	}
	t->frames += frames;
	t->calls++;
	tap_play(t, out, frames, is_float, bits);
	if (t->frames / TAP_REPORT == (t->frames - frames) / TAP_REPORT)
		return;
	if (t->peak > 0 || t->periods == 0 || ++t->silent >= TAP_SILENT) {
		qlog("tap: device %u (%s): %llu frames in %llu calls, %u buffers x %u ch, peak %.4f (%.1f dB), rms %.4f",
		     t->dev, t->name, t->frames, t->calls, out->mNumberBuffers, out->mNumberBuffers ? out->mBuffers[0].mNumberChannels : 0,
		     t->peak, t->peak > 0 ? 20 * log10f(t->peak) : -999.0f, t->nsamples ? sqrt(t->sumsq / t->nsamples) : 0);
		t->silent = 0;
	}
	t->periods++;
	t->peak = 0;
	t->sumsq = 0;
	t->nsamples = 0;
}

static OSStatus tap_ioproc(AudioObjectID dev, const AudioTimeStamp *now, const AudioBufferList *in, const AudioTimeStamp *in_time,
			   AudioBufferList *out, const AudioTimeStamp *out_time, void *client)
{
	struct tap *t = client;
	OSStatus r = t->proc(dev, now, in, in_time, out, out_time, t->client);
	if (out && out->mNumberBuffers)
		tap_output(t, out);
	return r;
}

static OSStatus (*real_create_ioproc)(AudioObjectID, AudioDeviceIOProc, void *, AudioDeviceIOProcID *);
static OSStatus (*real_start)(AudioObjectID, AudioDeviceIOProcID);
static OSStatus (*real_stop)(AudioObjectID, AudioDeviceIOProcID);

static OSStatus va_create_ioproc(AudioObjectID dev, AudioDeviceIOProc proc, void *client, AudioDeviceIOProcID *id)
{
	struct tap *t = proc ? calloc(1, sizeof(*t)) : NULL;
	if (!t)
		return real_create_ioproc(dev, proc, client, id);
	t->proc = proc;
	t->client = client;
	t->dev = dev;
	CFStringRef name = NULL;
	UInt32 size = sizeof(name);
	AudioObjectPropertyAddress a = { kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
	if (!real_get(dev, &a, 0, NULL, &size, &name) && name) {
		CFStringGetCString(name, t->name, sizeof(t->name), kCFStringEncodingUTF8);
		CFRelease(name);
	}
	AudioObjectID streams[8];
	size = sizeof(streams);
	a = (AudioObjectPropertyAddress){ kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
	if (!real_get(dev, &a, 0, NULL, &size, streams) && size >= sizeof(AudioObjectID)) {
		a = (AudioObjectPropertyAddress){ kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal,
						  kAudioObjectPropertyElementMain };
		size = sizeof(t->fmt);
		if (real_get(streams[0], &a, 0, NULL, &size, &t->fmt))
			memset(&t->fmt, 0, sizeof(t->fmt));
	}
	OSStatus err = real_create_ioproc(dev, tap_ioproc, t, id);
	char f[8];
	qlog("tap: VirtualAudio IOProc on device %u (%s) -> %d, id %p, format '%s' %.0f Hz %u ch %u bits flags %#x", dev, t->name,
	     (int)err, id ? (void *)*id : NULL, fourcc(t->fmt.mFormatID, f), t->fmt.mSampleRate, t->fmt.mChannelsPerFrame,
	     t->fmt.mBitsPerChannel, t->fmt.mFormatFlags);
	if (err)
		free(t);
	return err;
}

static OSStatus va_devstart(AudioObjectID dev, AudioDeviceIOProcID id)
{
	OSStatus err = real_start(dev, id);
	qlog("tap: AudioDeviceStart(%u, %p) -> %d", dev, (void *)id, (int)err);
	return err;
}

static OSStatus va_devstop(AudioObjectID dev, AudioDeviceIOProcID id)
{
	OSStatus err = real_stop(dev, id);
	qlog("tap: AudioDeviceStop(%u, %p) -> %d", dev, (void *)id, (int)err);
	return err;
}

#define NTRACE 8
static void *trace_fn[NTRACE], *trace_wrap[NTRACE] = { va_get, va_size, va_set, va_has, va_throw,
						       va_create_ioproc, va_devstart, va_devstop };

static void trace_image(const struct mach_header *mh, intptr_t slide)
{
	Dl_info info;
	if (!dladdr(mh, &info) || !info.dli_fname || !strstr(info.dli_fname, "/VirtualAudio.plugin/"))
		return;
	va_base = (uintptr_t)mh;
	/* which product VirtualAudio thinks it runs on (MobileGestalt's product
	 * type hash). No calls into VirtualAudio by offset: each iOS build and
	 * device has its own (an iPhone X offset crashed mediaserverd on the XS). */
	uint64_t (*mg_type)(void) = dlsym(RTLD_DEFAULT, "MGGetProductType");
	char model[64] = "";
	size_t msz = sizeof(model);
	sysctlbyname("hw.model", model, &msz, NULL, 0);
	qlog("trace: hw.model %s, MGGetProductType %#llx", model,
	     mg_type ? (unsigned long long)mg_type() : 0ULL);
	static const char *const sects[][2] = {
		{ "__DATA_CONST", "__got" }, { "__DATA", "__got" },
		{ "__DATA_CONST", "__auth_got" }, { "__AUTH_CONST", "__auth_got" }, { "__DATA", "__auth_got" },
	};
	int n = 0, found = 0;
	for (size_t i = 0; i < sizeof(sects) / sizeof(sects[0]); i++) {
		unsigned long size;
		uint8_t *got = getsectiondata((const struct mach_header_64 *)mh, sects[i][0], sects[i][1], &size);
		if (!got)
			continue;
		found++;
		vm_address_t page = (vm_address_t)got & ~(vm_page_size - 1);
		vm_size_t len = (vm_address_t)got + size - page;
		kern_return_t kr = vm_protect(mach_task_self(), page, len, false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
		for (void **p = (void **)got; kr == KERN_SUCCESS && (uint8_t *)p < got + size; p++)
			for (int k = 0; k < NTRACE; k++)
				if (trace_fn[k] && *p == trace_fn[k]) {
					*p = trace_wrap[k];
					n++;
				}
		vm_protect(mach_task_self(), page, len, false, VM_PROT_READ);
		qlog("trace: %s,%s: vm_protect %d", sects[i][0], sects[i][1], kr);
	}
	if (!found)
		qlog("trace: no __got/__auth_got in VirtualAudio");
	qlog("trace: %d VirtualAudio imports wrapped", n);
}

static void trace_va(void)
{
	trace_fn[0] = real_get = dlsym(RTLD_DEFAULT, "AudioObjectGetPropertyData");
	trace_fn[1] = real_size = dlsym(RTLD_DEFAULT, "AudioObjectGetPropertyDataSize");
	trace_fn[2] = real_set = dlsym(RTLD_DEFAULT, "AudioObjectSetPropertyData");
	trace_fn[3] = real_has = dlsym(RTLD_DEFAULT, "AudioObjectHasProperty");
	trace_fn[4] = real_throw = dlsym(RTLD_DEFAULT, "__cxa_throw");
#if QEMUAUDIO_TAP
	trace_fn[5] = real_create_ioproc = dlsym(RTLD_DEFAULT, "AudioDeviceCreateIOProcID");
	trace_fn[6] = real_start = dlsym(RTLD_DEFAULT, "AudioDeviceStart");
	trace_fn[7] = real_stop = dlsym(RTLD_DEFAULT, "AudioDeviceStop");
#endif
	_dyld_register_func_for_add_image(trace_image);	/* also runs for images already loaded */
}
#endif

/*
 * QEMUAUDIO_REROUTE: VirtualAudio computes the default device's first route
 * before it adds any other plugin's devices, so it routes playback to its
 * Null_Device, and new built-in ports never re-route ('ncru'). MediaExperience
 * re-routes only when an audio category changes (cmsmSetVADRouteConfiguration
 * -> vaemSetRouteConfigurationDictionaryOnVAD: property 'rtcf' on the VAD,
 * data { in: CFDictionary, out: CFDictionary } like AudioValueTranslation).
 * So once our devices are in, send the request MediaExperience would send for
 * playback: category 'csav', mode 'imdf'.
 */
#define QEMUAUDIO_REROUTE 0	/* 2026-10-25: accepted; at 5/15 s and at 45/60 s (ringer on, devices in) still pap -> pnul */
#if QEMUAUDIO_REROUTE
#include <dispatch/dispatch.h>
#include <errno.h>
#include <dlfcn.h>

static void reroute(void)
{
	OSStatus (*get)(AudioObjectID, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32 *, void *) =
	    dlsym(RTLD_DEFAULT, "AudioObjectGetPropertyData");
	OSStatus (*set)(AudioObjectID, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32, const void *) =
	    dlsym(RTLD_DEFAULT, "AudioObjectSetPropertyData");
	if (!get || !set)
		return;
	/* 'rtcf' is a property of VirtualAudio's plug-in object: find it by bundle ID */
	AudioObjectPropertyAddress list = { 'plg#', kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
	AudioObjectID ids[32], va = kAudioObjectUnknown;
	UInt32 size = sizeof(ids);
	OSStatus err = get(1 /* kAudioObjectSystemObject */, &list, 0, NULL, &size, ids);
	for (UInt32 i = 0; !err && i < size / sizeof(AudioObjectID); i++) {
		AudioObjectPropertyAddress ba = { kAudioPlugInPropertyBundleID, kAudioObjectPropertyScopeGlobal,
						  kAudioObjectPropertyElementMain };
		CFStringRef bundle = NULL;
		UInt32 bs = sizeof(bundle);
		if (get(ids[i], &ba, 0, NULL, &bs, &bundle) == noErr && bundle) {
			if (CFEqual(bundle, CFSTR("com.apple.audio.CoreAudio.VirtualAudio")))
				va = ids[i];
			CFRelease(bundle);
		}
	}
	if (err || va == kAudioObjectUnknown) {
		qlog("reroute: VirtualAudio plug-in not found among %u plug-ins (%d)", (unsigned)(size / sizeof(AudioObjectID)),
		     (int)err);
		return;
	}
	SInt32 category = 'csav', mode = 'imdf';
	CFNumberRef c = CFNumberCreate(NULL, kCFNumberSInt32Type, &category), m = CFNumberCreate(NULL, kCFNumberSInt32Type, &mode);
	const void *keys[] = { CFSTR("category"), CFSTR("mode") }, *vals[] = { c, m };
	CFDictionaryRef config = CFDictionaryCreate(NULL, keys, vals, 2, &kCFTypeDictionaryKeyCallBacks,
						    &kCFTypeDictionaryValueCallBacks);
	CFDictionaryRef result = NULL;
	struct { const void *in; UInt32 in_size; void *out; UInt32 out_size; } data = {
		config, sizeof(config), &result, sizeof(result) };
	AudioObjectPropertyAddress rtcf = { 'rtcf', kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
	err = set(va, &rtcf, 0, NULL, sizeof(data), &data);
	qlog("reroute: 'rtcf' csav/imdf on VirtualAudio %u -> %d, result %s", va, (int)err, result ? "yes" : "none");
	if (result)
		CFRelease(result);
	CFRelease(config);
	CFRelease(c);
	CFRelease(m);
}
#endif

/*
 * QEMUAUDIO_RINGER: VirtualAudio culls speaker routes while the ringer switch
 * is off ("Culling route connection because ringer switch is off", for the
 * categories that obey it, e.g. 'csav' system sounds and 'crng'). It reads the
 * switch from notify state com.apple.springboard.ringerstate, which SpringBoard
 * sets only ~37 s into boot, after the first routes were computed. Set it (1 =
 * ringer on) before VirtualAudio starts.
 */
#define QEMUAUDIO_RINGER 1
#define QEMUAUDIO_JACK_SECS 8	/* 50 tried: no route either */
#if QEMUAUDIO_RINGER
#include <notify.h>

static void ringer_on(void)
{
	int token;
	uint32_t st = notify_register_check("com.apple.springboard.ringerstate", &token);
	if (st == NOTIFY_STATUS_OK)
		st = notify_set_state(token, 1);
	if (st == NOTIFY_STATUS_OK)
		st = notify_post("com.apple.springboard.ringerstate");
	qlog("ringer state set to on: status %u", st);
}
#endif

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
	for (unsigned i = 0; i < NOBJECTS; i++)
		if (objects[i].kind == SOURCE) {
			objects[i].ncurrent = nsources(&objects[i]);
			memcpy(objects[i].current, objects[i].sources, sizeof(objects[i].current));
		}
	mach_timebase_info_data_t tb;
	mach_timebase_info(&tb);
	ticks_per_frame = 1e9 / RATE * tb.denom / tb.numer;
	qlog("initialized: %d ch, %.0f Hz, speaker device %d, fake VAD %d", CHANNELS, RATE, QEMUAUDIO_SPEAKER_DEVICE,
	     QEMUAUDIO_FAKE_VAD);
#if QEMUAUDIO_TRACE_VA
	trace_va();
#endif
#if QEMUAUDIO_RINGER
	ringer_on();
#endif
#if QEMUAUDIO_HEADPHONES && !QEMUAUDIO_FAKE_VAD
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, QEMUAUDIO_JACK_SECS * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
		jack_connected = 1;
		AudioObjectPropertyAddress ch = { 'jack', kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
		AudioObjectPropertyAddress val = { kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal,
						   kAudioObjectPropertyElementMain };
		host->PropertiesChanged(host, kObjCodecJack, 1, &val);
		host->PropertiesChanged(host, kObjCodec, 1, &ch);
		qlog("headphones plugged in");
	});
#endif
#if QEMUAUDIO_REROUTE && !QEMUAUDIO_FAKE_VAD
	for (int t = 45; t <= 60; t += 15)
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, t * NSEC_PER_SEC),
			       dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ reroute(); });
#endif
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

/*
 * One function drives HasProperty, GetPropertyDataSize and GetPropertyData:
 * get() writes the value into out (if size bytes fit) and returns the
 * value's size, 0 for "no such property" or EMPTY for an empty list.
 */
#define EMPTY 0x80000000u

/* the objects owned by o (streams and controls of a device), filtered by scope */
static UInt32 owned(const struct object *o, const AudioObjectPropertyAddress *a, AudioObjectID *ids)
{
	UInt32 n = 0;
	for (unsigned i = 0; i < NOBJECTS; i++) {
		const struct object *c = &objects[i];
		if (c->owner != o->id)
			continue;
		if (a->mSelector == kAudioPlugInPropertyDeviceList && c->kind != DEVICE)
			continue;
		if (a->mSelector == kAudioDevicePropertyStreams && c->kind != STREAM)
			continue;
		if (a->mSelector == kAudioObjectPropertyControlList && (c->kind == STREAM || c->kind == DEVICE))
			continue;
		if (o->kind == DEVICE && ((a->mScope == kAudioObjectPropertyScopeInput && !c->input) ||
					  (a->mScope == kAudioObjectPropertyScopeOutput && c->input)))
			continue;
		ids[n++] = c->id;
	}
	return n;
}

static UInt32 get(AudioObjectID id, const AudioObjectPropertyAddress *a, UInt32 size, void *out)
{
	const struct object *o = find(id);
	char buf[256];
	UInt32 n = 0;
#define VAL(T, v) do { T _v = (v); n = sizeof(T); memcpy(buf, &_v, n); } while (0)
#define STR(s) VAL(CFStringRef, CFStringCreateWithCString(NULL, (s), kCFStringEncodingUTF8))
	if (!o)
		return 0;
	/* common to every object */
	switch (a->mSelector) {
	case kAudioObjectPropertyOwner: VAL(AudioObjectID, o->owner); break;
	case kAudioObjectPropertyOwnedObjects:
	case kAudioPlugInPropertyDeviceList:
	case kAudioDevicePropertyStreams:
	case kAudioObjectPropertyControlList: {
		if (a->mSelector == kAudioPlugInPropertyDeviceList && o->kind != PLUGIN)
			break;
		if ((a->mSelector == kAudioDevicePropertyStreams || a->mSelector == kAudioObjectPropertyControlList) &&
		    o->kind != DEVICE)
			break;
		AudioObjectID ids[NOBJECTS];
		UInt32 count = owned(o, a, ids);
		n = count ? count * sizeof(AudioObjectID) : EMPTY;
		memcpy(buf, ids, count * sizeof(AudioObjectID));
		break;
	}
	}
	if (n)
		goto done;
	switch (o->kind) {
	case PLUGIN:
		switch (a->mSelector) {
		case kAudioObjectPropertyBaseClass: VAL(AudioClassID, kAudioObjectClassID); break;
		case kAudioObjectPropertyClass: VAL(AudioClassID, kAudioPlugInClassID); break;
		case kAudioObjectPropertyManufacturer: STR("ios-qemu"); break;
		case kAudioPlugInPropertyResourceBundle: STR(""); break;
		/* the qualifier (a CFString UID) is checked by the caller */
		case kAudioPlugInPropertyTranslateUIDToDevice: VAL(AudioObjectID, kAudioObjectUnknown); break;
		}
		break;
	case DEVICE:
		switch (a->mSelector) {
		case kAudioObjectPropertyBaseClass: VAL(AudioClassID, kAudioObjectClassID); break;
		case kAudioObjectPropertyClass: VAL(AudioClassID, kAudioDeviceClassID); break;
		case kAudioObjectPropertyName: STR(o->name); break;
		case kAudioObjectPropertyManufacturer: STR("ios-qemu"); break;
		case kAudioDevicePropertyDeviceUID: STR(o->name); break;
		case kAudioDevicePropertyModelUID: STR(MODEL_UID); break;
		case kAudioDevicePropertyTransportType: VAL(UInt32, kAudioDeviceTransportTypeBuiltIn); break;
		case kAudioDevicePropertyRelatedDevices: VAL(AudioObjectID, o->id); break;
		case kAudioDevicePropertyClockDomain: VAL(UInt32, 1); break;	/* one clock for both devices */
		case kAudioDevicePropertyDeviceIsAlive: VAL(UInt32, 1); break;
		case kAudioDevicePropertyDeviceIsRunning: VAL(UInt32, io_for(o->id)->clients > 0); break;
		case kAudioDevicePropertyDeviceCanBeDefaultDevice:
		case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: VAL(UInt32, 1); break;
		case kAudioDevicePropertyLatency:
		case kAudioDevicePropertySafetyOffset: VAL(UInt32, 0); break;
		case kAudioDevicePropertyNominalSampleRate: VAL(Float64, RATE); break;
		case kAudioDevicePropertyAvailableNominalSampleRates:
			VAL(AudioValueRange, ((AudioValueRange){ RATE, RATE }));
			break;
		case kAudioDevicePropertyIsHidden: VAL(UInt32, 0); break;
		case kAudioDevicePropertyZeroTimeStampPeriod: VAL(UInt32, PERIOD); break;
#if QEMUAUDIO_HEADPHONES
		/*
		 * 'head': what is plugged into the jack, a dictionary
		 * (HALJackStateHandler: without it "Unknown JackDescriptor").
		 * "earpiece design" 1..8 are Apple's wired earphone models;
		 * 1 makes the descriptor 'jb15'. A custom property, so the HAL
		 * only forwards it when it is in the custom property list.
		 */
		case kAudioObjectPropertyCustomPropertyInfoList:
			if (o->id == kObjCodec)
				VAL(AudioServerPlugInCustomPropertyInfo,
				    ((AudioServerPlugInCustomPropertyInfo){ 'head', kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,
									    kAudioServerPlugInCustomPropertyDataTypeNone }));
			break;
		case 'head':
			if (o->id == kObjCodec) {
				SInt32 design = 1;
				CFNumberRef d = CFNumberCreate(NULL, kCFNumberSInt32Type, &design);
				const void *k = CFSTR("earpiece design"), *v = d;
				VAL(CFDictionaryRef, CFDictionaryCreate(NULL, &k, &v, 1, &kCFTypeDictionaryKeyCallBacks,
								       &kCFTypeDictionaryValueCallBacks));
				CFRelease(d);
			}
			break;
#endif
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
	case STREAM:
		switch (a->mSelector) {
		case kAudioObjectPropertyBaseClass: VAL(AudioClassID, kAudioObjectClassID); break;
		case kAudioObjectPropertyClass: VAL(AudioClassID, kAudioStreamClassID); break;
		case kAudioObjectPropertyName: STR(o->name); break;
		case kAudioStreamPropertyIsActive: VAL(UInt32, 1); break;
		case kAudioStreamPropertyDirection: VAL(UInt32, o->input); break;	/* 1 = input */
		case kAudioStreamPropertyTerminalType: VAL(UInt32, o->terminal); break;
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
	case VOLUME:
	case MUTE:
	case SOURCE:
	case JACK:
		switch (a->mSelector) {
		case kAudioObjectPropertyBaseClass:
			VAL(AudioClassID, o->kind == VOLUME ? kAudioLevelControlClassID :
			    o->kind == SOURCE ? kAudioSelectorControlClassID : kAudioBooleanControlClassID);
			break;
		case kAudioObjectPropertyClass:
			VAL(AudioClassID, o->kind == VOLUME ? kAudioVolumeControlClassID : o->kind == MUTE ? kAudioMuteControlClassID :
			    o->kind == JACK ? kAudioJackControlClassID : kAudioDataSourceControlClassID);
			break;
		case kAudioControlPropertyScope:
			VAL(AudioObjectPropertyScope, o->input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput);
			break;
		case kAudioControlPropertyElement: VAL(AudioObjectPropertyElement, o->element); break;
		}
		if (n)
			break;
		if (o->kind == VOLUME)
			switch (a->mSelector) {
			case kAudioLevelControlPropertyScalarValue: VAL(Float32, 1.0f - o->volume_db / MIN_DB); break;
			case kAudioLevelControlPropertyDecibelValue: VAL(Float32, o->volume_db); break;
			case kAudioLevelControlPropertyDecibelRange:
				VAL(AudioValueRange, ((AudioValueRange){ MIN_DB, 0 }));
				break;
			/* the value to convert arrives in out; done by the caller */
			case kAudioLevelControlPropertyConvertScalarToDecibels:
			case kAudioLevelControlPropertyConvertDecibelsToScalar: VAL(Float32, 0); break;
			}
		else if (o->kind == MUTE && a->mSelector == kAudioBooleanControlPropertyValue)
			VAL(UInt32, o->muted);
		else if (o->kind == JACK && a->mSelector == kAudioBooleanControlPropertyValue)
			VAL(UInt32, jack_connected);
		else if (o->kind == SOURCE)
			switch (a->mSelector) {
			case kAudioSelectorControlPropertyCurrentItem:
				n = o->ncurrent ? o->ncurrent * sizeof(UInt32) : EMPTY;
				memcpy(buf, o->current, o->ncurrent * sizeof(UInt32));
				break;
			case kAudioSelectorControlPropertyAvailableItems:
				n = nsources(o) * sizeof(UInt32);
				memcpy(buf, o->sources, n);
				break;
			/* the item ID arrives as the qualifier; answered by the caller */
			case kAudioSelectorControlPropertyItemName: VAL(CFStringRef, NULL); break;
			}
		break;
	}
done:
#undef VAL
#undef STR
	if (n && n != EMPTY && out && size >= n)
		memcpy(out, buf, n);
	else if (n == sizeof(CFStringRef) && (a->mSelector == kAudioObjectPropertyName ||
					      a->mSelector == kAudioObjectPropertyManufacturer ||
					      a->mSelector == kAudioDevicePropertyDeviceUID ||
					      a->mSelector == kAudioDevicePropertyModelUID ||
					      a->mSelector == kAudioPlugInPropertyResourceBundle || a->mSelector == 'head'))
		CFRelease(*(CFTypeRef *)buf);	/* only the size was asked for */
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

static OSStatus IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid,
				   const AudioObjectPropertyAddress *a, Boolean *out)
{
	const struct object *o = find(obj);
	if (!HasProperty(d, obj, pid, a))
		return kAudioHardwareUnknownPropertyError;
	switch (o->kind) {
	case STREAM:
		*out = a->mSelector == kAudioStreamPropertyVirtualFormat ||
		       a->mSelector == kAudioStreamPropertyPhysicalFormat;
		break;
	case VOLUME:
		*out = a->mSelector == kAudioLevelControlPropertyScalarValue ||
		       a->mSelector == kAudioLevelControlPropertyDecibelValue;
		break;
	case MUTE:
		*out = a->mSelector == kAudioBooleanControlPropertyValue;
		break;
	case SOURCE:
		*out = a->mSelector == kAudioSelectorControlPropertyCurrentItem;
		break;
	default:
		*out = false;
	}
	return noErr;
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

static const char *source_name(UInt32 id)
{
	switch (id) {
	case 'imic': return "Microphone";
	case 'spkr': return "Speaker";
	case 'spV0': return "Speaker Voltage";
	case 'spI0': return "Speaker Current";
	}
	return NULL;
}

static OSStatus GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid,
				const AudioObjectPropertyAddress *a, UInt32 qsize, const void *q,
				UInt32 size, UInt32 *outsize, void *out)
{
	const struct object *o = find(obj);
	if (o && o->kind == PLUGIN && a->mSelector == kAudioPlugInPropertyTranslateUIDToDevice) {
		CFStringRef uid = qsize >= sizeof(CFStringRef) ? *(CFStringRef *)q : NULL;
		AudioObjectID dev = kAudioObjectUnknown;
		for (unsigned i = 0; uid && i < NOBJECTS; i++)
			if (objects[i].kind == DEVICE) {
				CFStringRef name = CFStringCreateWithCString(NULL, objects[i].name, kCFStringEncodingUTF8);
				if (CFEqual(uid, name))
					dev = objects[i].id;
				CFRelease(name);
			}
		if (size < sizeof(dev))
			return kAudioHardwareBadPropertySizeError;
		memcpy(out, &dev, sizeof(dev));
		*outsize = sizeof(dev);
		return noErr;
	}
	if (o && o->kind == SOURCE && a->mSelector == kAudioSelectorControlPropertyItemName) {
		const char *name = source_name(qsize >= sizeof(UInt32) ? *(const UInt32 *)q : 0);
		if (!name)
			return kAudioHardwareIllegalOperationError;
		if (size < sizeof(CFStringRef))
			return kAudioHardwareBadPropertySizeError;
		*(CFStringRef *)out = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
		*outsize = sizeof(CFStringRef);
		return noErr;
	}
	if (o && o->kind == VOLUME && (a->mSelector == kAudioLevelControlPropertyConvertScalarToDecibels ||
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
	UInt32 n = get(obj, a, size, out);	/* CF values in out are created for the caller */
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
	return noErr;
}

static OSStatus SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid,
				const AudioObjectPropertyAddress *a, UInt32 qsize, const void *q,
				UInt32 size, const void *data)
{
	struct object *o = find(obj);
	if (!o)
		return kAudioHardwareBadObjectError;
	if (o->kind == STREAM && (a->mSelector == kAudioStreamPropertyVirtualFormat ||
				  a->mSelector == kAudioStreamPropertyPhysicalFormat)) {
		/* only one format: accept it unchanged, refuse anything else */
		AudioStreamBasicDescription f = stream_format();
		if (size >= sizeof(f) && !memcmp(data, &f, sizeof(f)))
			return noErr;
		return kAudioDeviceUnsupportedFormatError;
	}
	if (o->kind == VOLUME && size >= sizeof(Float32) &&
	    (a->mSelector == kAudioLevelControlPropertyScalarValue ||
	     a->mSelector == kAudioLevelControlPropertyDecibelValue)) {
		Float32 v = *(const Float32 *)data;
		o->volume_db = a->mSelector == kAudioLevelControlPropertyDecibelValue ?
		    fminf(fmaxf(v, MIN_DB), 0) : (1.0f - fminf(fmaxf(v, 0), 1)) * MIN_DB;
		AudioObjectPropertyAddress ch[2] = {
			{ kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
			{ kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
		};
		host->PropertiesChanged(host, obj, 2, ch);
		qlog("volume %u = %.1f dB", obj, o->volume_db);
		return noErr;
	}
	if (o->kind == MUTE && size >= sizeof(UInt32) && a->mSelector == kAudioBooleanControlPropertyValue) {
		o->muted = *(const UInt32 *)data != 0;
		AudioObjectPropertyAddress ch = { kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal,
						  kAudioObjectPropertyElementMain };
		host->PropertiesChanged(host, obj, 1, &ch);
		qlog("mute %u = %u", obj, o->muted);
		return noErr;
	}
	if (o->kind == SOURCE && a->mSelector == kAudioSelectorControlPropertyCurrentItem) {
		/* any selection of our sources; VirtualAudio waits for the change notification */
		UInt32 count = size / sizeof(UInt32), sel[4];
		char c[8], line[64] = "";
		if (count > 4)
			return kAudioHardwareIllegalOperationError;
		for (UInt32 i = 0; i < count; i++) {
			sel[i] = ((const UInt32 *)data)[i];
			unsigned k = 0;
			while (k < nsources(o) && o->sources[k] != sel[i])
				k++;
			if (k == nsources(o))
				return kAudioHardwareIllegalOperationError;
			strlcat(line, " ", sizeof(line));
			strlcat(line, fourcc(sel[i], c), sizeof(line));
		}
		memcpy(o->current, sel, count * sizeof(UInt32));
		o->ncurrent = count;
		AudioObjectPropertyAddress ch = { kAudioSelectorControlPropertyCurrentItem, kAudioObjectPropertyScopeGlobal,
						  kAudioObjectPropertyElementMain };
		host->PropertiesChanged(host, obj, 1, &ch);
		qlog("source %u: selected%s", obj, line);
		return noErr;
	}
	unknown(obj, a, "SetPropertyData");
	return kAudioHardwareUnknownPropertyError;
}

/* ---- IO ---- */

static OSStatus StartIO(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client)
{
	struct io *io = io_for(dev);
	pthread_mutex_lock(&lock);
	if (io->clients++ == 0) {
		io->anchor_time = mach_absolute_time();
		io->period_count = 0;
		io->seed++;
		qlog("IO started on device %u", dev);
	}
	pthread_mutex_unlock(&lock);
	return noErr;
}

static OSStatus StopIO(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client)
{
	struct io *io = io_for(dev);
	pthread_mutex_lock(&lock);
	if (io->clients && --io->clients == 0)
		qlog("IO stopped on device %u after %llu frames", dev, io->frames);
	pthread_mutex_unlock(&lock);
	return noErr;
}

static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client,
				 Float64 *sample_time, UInt64 *host_time, UInt64 *out_seed)
{
	/* the latest period boundary at or before now, on a 48 kHz host-time clock */
	struct io *io = io_for(dev);
	UInt64 now = mach_absolute_time();
	Float64 ticks_per_period = ticks_per_frame * PERIOD;
	UInt64 next = io->anchor_time + (UInt64)((io->period_count + 1) * ticks_per_period);
	if (now >= next)
		io->period_count = (UInt64)((now - io->anchor_time) / ticks_per_period);
	*sample_time = (Float64)io->period_count * PERIOD;
	*host_time = io->anchor_time + (UInt64)(io->period_count * ticks_per_period);
	*out_seed = io->seed;
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
	struct io *io = io_for(dev);
	if (op == kAudioServerPlugInIOOperationReadInput) {
		memset(main_buf, 0, frames * CHANNELS * sizeof(Float32));	/* no microphone or telemetry yet */
		return noErr;
	}
	if (op != kAudioServerPlugInIOOperationWriteMix)
		return noErr;
	const Float32 *s = main_buf;
	for (UInt32 i = 0; i < frames * CHANNELS; i++) {
		Float32 v = fabsf(s[i]);
		if (v > io->peak)
			io->peak = v;
	}
	io->frames += frames;
	if (io->frames - io->last_report >= (UInt64)RATE) {
		qlog("IO on device %u: %llu frames so far, peak %.3f in the last second", dev, io->frames, io->peak);
		io->last_report = io->frames;
		io->peak = 0;
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
