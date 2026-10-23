/*
 * VTTest: which video decoders work in the guest (no hardware decoder).
 * Decodes the bundled h264.mov / hevc.mov four ways and shows the results;
 * also appends them to /private/var/tmp/vttest.log.
 *   tools/guest/vttest/build.sh -> research/guest/VTTest.ipa
 */
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#include <dlfcn.h>
#include <IOSurface/IOSurfaceRef.h>

/* private, exported by IOSurface.framework */
size_t IOSurfaceGetOffsetOfPlane(IOSurfaceRef buffer, size_t planeIndex);

static NSMutableString *report;
static UITextView *view;

static void out(NSString *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
	va_end(ap);
	NSLog(@"VTTest: %@", line);
	FILE *f = fopen("/private/var/tmp/vttest.log", "a");
	if (f) {
		fprintf(f, "%s\n", line.UTF8String);
		fclose(f);
	}
	dispatch_async(dispatch_get_main_queue(), ^{
		[report appendFormat:@"%@\n", line];
		view.text = report;
	});
}

static NSArray *samples_of(NSURL *url, CMFormatDescriptionRef *fmt)
{
	AVAsset *asset = [AVAsset assetWithURL:url];
	AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
	AVAssetReader *r = [AVAssetReader assetReaderWithAsset:asset error:nil];
	AVAssetReaderTrackOutput *o = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:nil];
	[r addOutput:o];
	[r startReading];
	NSMutableArray *list = [NSMutableArray array];
	CMSampleBufferRef sb;
	while ((sb = [o copyNextSampleBuffer])) {
		if (CMSampleBufferGetNumSamples(sb) > 0) {
			[list addObject:(__bridge id)sb];
		}
		CFRelease(sb);
	}
	*fmt = (__bridge CMFormatDescriptionRef)(__bridge id)CMSampleBufferGetFormatDescription((__bridge CMSampleBufferRef)list.firstObject);
	return list;
}

/* VTDecompressionSession with a decoder specification (nil = default) */
static void vt_decode(NSString *name, NSArray *samples, CMFormatDescriptionRef fmt, NSDictionary *spec, NSString *label)
{
	VTDecompressionSessionRef s = NULL;
	NSDictionary *attrs = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA) };
	CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
	OSStatus st = VTDecompressionSessionCreate(NULL, fmt, (__bridge CFDictionaryRef)spec, (__bridge CFDictionaryRef)attrs, NULL, &s);
	if (st != noErr) {
		out(@"%@ %@: VTDecompressionSessionCreate failed %d", name, label, (int)st);
		return;
	}
	CFBooleanRef hw = NULL;
	VTSessionCopyProperty(s, CFSTR("UsingHardwareAcceleratedVideoDecoder"), NULL, &hw);
	__block int ok = 0, bad = 0;
	__block OSStatus last = noErr;
	for (id sb in samples) {
		OSStatus ds = VTDecompressionSessionDecodeFrameWithOutputHandler(s, (__bridge CMSampleBufferRef)sb, 0, NULL,
		    ^(OSStatus status, VTDecodeInfoFlags flags, CVImageBufferRef image, CMTime pts, CMTime dur) {
			if (status == noErr && image) ok++; else { bad++; last = status; }
		});
		if (ds != noErr) {
			bad++;
			last = ds;
		}
	}
	VTDecompressionSessionWaitForAsynchronousFrames(s);
	double ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000;
	out(@"%@ %@: %d/%lu frames decoded, %d errors (last %d), hardware %@, %.0f ms (%.1f ms/frame)", name, label, ok,
	    (unsigned long)samples.count, bad, (int)last, hw ? (CFBooleanGetValue(hw) ? @"yes" : @"no") : @"?", ms, ms / MAX(samples.count, 1u));
	if (hw) CFRelease(hw);
	VTDecompressionSessionInvalidate(s);
	CFRelease(s);
}

/* AVAssetReader decoding to BGRA: the path AVFoundation players use */
static void reader_decode(NSString *name, NSURL *url)
{
	AVAsset *asset = [AVAsset assetWithURL:url];
	AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
	NSError *e = nil;
	AVAssetReader *r = [AVAssetReader assetReaderWithAsset:asset error:&e];
	AVAssetReaderTrackOutput *o = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track
	    outputSettings:@{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA) }];
	[r addOutput:o];
	[r startReading];
	int n = 0;
	CMSampleBufferRef sb;
	while ((sb = [o copyNextSampleBuffer])) {
		if (CMSampleBufferGetImageBuffer(sb)) n++;
		CFRelease(sb);
	}
	out(@"%@ AVAssetReader: %d frames, status %ld%@", name, n, (long)r.status,
	    r.error ? [@", error " stringByAppendingString:r.error.description] : @"");
}

/* a two-plane video surface: both planes need real addresses */
static void planar_check(void)
{
	CVPixelBufferRef pb = NULL;
	NSDictionary *attrs = @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
	CVReturn r = CVPixelBufferCreate(NULL, 640, 360, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
	    (__bridge CFDictionaryRef)attrs, &pb);
	if (r != kCVReturnSuccess) {
		out(@"420v pixel buffer: create failed %d", r);
		return;
	}
	IOSurfaceRef s = CVPixelBufferGetIOSurface(pb);
	CVPixelBufferLockBaseAddress(pb, 0);
	out(@"420v pixel buffer (IOSurface %u, %zu planes): plane 0 %p, plane 1 %p, offsets %zu / %zu, bytes per row %zu / %zu",
	    s ? IOSurfaceGetID(s) : 0, CVPixelBufferGetPlaneCount(pb), CVPixelBufferGetBaseAddressOfPlane(pb, 0),
	    CVPixelBufferGetBaseAddressOfPlane(pb, 1), s ? IOSurfaceGetOffsetOfPlane(s, 0) : 0, s ? IOSurfaceGetOffsetOfPlane(s, 1) : 0,
	    CVPixelBufferGetBytesPerRowOfPlane(pb, 0), CVPixelBufferGetBytesPerRowOfPlane(pb, 1));
	CVPixelBufferUnlockBaseAddress(pb, 0);
	CVPixelBufferRelease(pb);
}

static void run_tests(void)
{
	out(@"--- VTTest %@", [NSDate date]);
	planar_check();
	CMVideoCodecType codecs[] = { kCMVideoCodecType_H264, kCMVideoCodecType_HEVC, 'vp09', 'av01' };
	for (int i = 0; i < 4; i++) {
		uint32_t c = codecs[i];
		out(@"VTIsHardwareDecodeSupported('%c%c%c%c') = %d", c >> 24, c >> 16 & 0xff, c >> 8 & 0xff, c & 0xff,
		    VTIsHardwareDecodeSupported(c));
	}
	/* every registered decoder: VTCopyVideoDecoderList is macOS-only in the
	   SDK headers but exported by iOS 16's VideoToolbox */
	OSStatus (*copyList)(CFDictionaryRef, CFArrayRef *) = dlsym(RTLD_DEFAULT, "VTCopyVideoDecoderList");
	CFStringRef *kCodec = dlsym(RTLD_DEFAULT, "kVTVideoDecoderList_CodecType");
	CFStringRef *kID = dlsym(RTLD_DEFAULT, "kVTVideoDecoderList_DecoderID");
	CFStringRef *kName = dlsym(RTLD_DEFAULT, "kVTVideoDecoderList_DecoderName");
	CFArrayRef list = NULL;
	if (copyList && kCodec && kID && kName) {
		copyList(NULL, &list);
	} else {
		out(@"VTCopyVideoDecoderList not found");
	}
	NSMutableDictionary<NSNumber *, NSMutableArray *> *byCodec = [NSMutableDictionary dictionary];
	for (NSDictionary *d in (__bridge NSArray *)list) {
		uint32_t c = [d[(__bridge id)*kCodec] unsignedIntValue];
		out(@"decoder %@ '%c%c%c%c' %@", d[(__bridge id)*kID], c >> 24, c >> 16 & 0xff, c >> 8 & 0xff, c & 0xff,
		    d[(__bridge id)*kName]);
		if (!byCodec[@(c)]) byCodec[@(c)] = [NSMutableArray array];
		[byCodec[@(c)] addObject:d[(__bridge id)*kID]];
	}
	if (list) CFRelease(list);
	for (NSString *name in @[ @"h264", @"hevc" ]) {
		NSURL *url = [[NSBundle mainBundle] URLForResource:name withExtension:@"mov"];
		CMFormatDescriptionRef fmt = NULL;
		NSArray *samples = samples_of(url, &fmt);
		out(@"%@: %lu samples", name, (unsigned long)samples.count);
		if (!fmt) continue;
		vt_decode(name, samples, fmt, nil, @"default");
		vt_decode(name, samples, fmt, @{ @"EnableHardwareAcceleratedVideoDecoder": @NO }, @"no-hw");
		reader_decode(name, url);
		/* each decoder registered for this codec, forced by id; the software
		   (VCP) decoders' ids are known from macOS, where the list API exists */
		NSMutableArray *ids = [byCodec[@(CMFormatDescriptionGetMediaSubType(fmt))] mutableCopy] ?: [NSMutableArray array];
		NSString *vcp = [name isEqual:@"h264"] ? @"com.apple.videotoolbox.videodecoder.avc.vcp" : @"com.apple.videotoolbox.videodecoder.hevc.vcp";
		if (![ids containsObject:vcp]) {
			[ids addObject:vcp];
		}
		for (NSString *decoder in ids) {
			vt_decode(name, samples, fmt, @{ @"DecoderID": decoder }, decoder);
		}
	}
	out(@"--- done");
}

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options
{
	self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
	UIViewController *vc = [UIViewController new];
	view = [[UITextView alloc] initWithFrame:CGRectInset(self.window.bounds, 8, 50)];
	view.editable = NO;
	view.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
	report = [NSMutableString string];
	[vc.view addSubview:view];
	vc.view.backgroundColor = UIColor.whiteColor;
	self.window.rootViewController = vc;
	[self.window makeKeyAndVisible];
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ run_tests(); });
	return YES;
}
@end

int main(int argc, char *argv[])
{
	@autoreleasepool {
		return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
	}
}
