/*
 * Writes the test clips for VTTest (macOS): 60 frames 640x360 of a moving
 * gradient as h264.mov (avc1) and hevc.mov (hvc1).
 *   mkclips OUTDIR
 */
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>

static BOOL write_clip(NSString *path, AVVideoCodecType codec)
{
	[[NSFileManager defaultManager] removeItemAtPath:path error:nil];
	NSError *e = nil;
	AVAssetWriter *w = [AVAssetWriter assetWriterWithURL:[NSURL fileURLWithPath:path] fileType:AVFileTypeQuickTimeMovie error:&e];
	AVAssetWriterInput *in = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
	    outputSettings:@{ AVVideoCodecKey: codec, AVVideoWidthKey: @640, AVVideoHeightKey: @360 }];
	AVAssetWriterInputPixelBufferAdaptor *ad = [AVAssetWriterInputPixelBufferAdaptor
	    assetWriterInputPixelBufferAdaptorWithAssetWriterInput:in sourcePixelBufferAttributes:@{
		(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA), (id)kCVPixelBufferWidthKey: @640,
		(id)kCVPixelBufferHeightKey: @360 }];
	[w addInput:in];
	[w startWriting];
	[w startSessionAtSourceTime:kCMTimeZero];
	for (int f = 0; f < 60; f++) {
		while (!in.readyForMoreMediaData) {
			usleep(1000);
		}
		CVPixelBufferRef pb = NULL;
		CVPixelBufferPoolCreatePixelBuffer(NULL, ad.pixelBufferPool, &pb);
		CVPixelBufferLockBaseAddress(pb, 0);
		uint8_t *p = CVPixelBufferGetBaseAddress(pb);
		size_t bpr = CVPixelBufferGetBytesPerRow(pb);
		for (int y = 0; y < 360; y++) {
			for (int x = 0; x < 640; x++) {
				uint8_t *px = p + y * bpr + x * 4;
				px[0] = (uint8_t)(x + f * 4);
				px[1] = (uint8_t)(y * 2);
				px[2] = (uint8_t)(255 - x / 3);
				px[3] = 255;
			}
		}
		CVPixelBufferUnlockBaseAddress(pb, 0);
		[ad appendPixelBuffer:pb withPresentationTime:CMTimeMake(f, 30)];
		CVPixelBufferRelease(pb);
	}
	[in markAsFinished];
	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	[w finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(done); }];
	dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
	if (w.status != AVAssetWriterStatusCompleted) {
		fprintf(stderr, "%s: %s\n", path.UTF8String, w.error.localizedDescription.UTF8String);
		return NO;
	}
	return YES;
}

int main(int argc, char **argv)
{
	@autoreleasepool {
		NSString *dir = argc > 1 ? @(argv[1]) : @".";
		BOOL ok = write_clip([dir stringByAppendingPathComponent:@"h264.mov"], AVVideoCodecTypeH264) &&
		    write_clip([dir stringByAppendingPathComponent:@"hevc.mov"], AVVideoCodecTypeHEVC);
		return ok ? 0 : 1;
	}
}
