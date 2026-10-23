/*
 * End-to-end test of Metal remoting on the Mac, without the VM: the guest
 * bundle's code (built for macOS with -DQMTL_HOST_TEST) talks to the real
 * host helper through a file laid out like guest RAM.
 *
 *   tools/host/qmtl-selftest.sh
 *
 * Clears an IOSurface-backed texture to red through QEMUMTLDevice and, with
 * a shader library (needs Xcode's Metal toolchain to build), draws a green
 * triangle over it (vertex positions from a heap buffer, colour from
 * setFragmentBytes:); checks the pixels copied back into the surface. Also
 * blits between two heap buffers.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <IOSurface/IOSurfaceRef.h>
#import "../guest/qemu-metal/qmtl_guest.h"

static uint32_t pixel(IOSurfaceRef s, int x, int y)
{
	return ((uint32_t *)IOSurfaceGetBaseAddress(s))[y * IOSurfaceGetBytesPerRow(s) / 4 + x];
}

int main(int argc, char **argv)
{
	@autoreleasepool {
		id<MTLDevice> dev = (id)[[QEMUMTLDevice alloc] initWithAcceleratorPort:0];
		if (!dev) {
			printf("FAIL: no device (host helper running?)\n");
			return 1;
		}
		NSError *error = nil;
		id<MTLRenderPipelineState> pipe = nil;
		if (argc > 1) {
			id<MTLLibrary> lib = [dev newLibraryWithURL:[NSURL fileURLWithPath:@(argv[1])] error:&error];
			MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
			pd.vertexFunction = [lib newFunctionWithName:@"st_vertex"];
			pd.fragmentFunction = [lib newFunctionWithName:@"st_fragment"];
			pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
			pipe = [dev newRenderPipelineStateWithDescriptor:pd error:&error];
			if (!pipe) {
				printf("FAIL: pipeline: %s\n", error.localizedDescription.UTF8String);
				return 1;
			}
		}

		IOSurfaceRef surf = IOSurfaceCreate((__bridge CFDictionaryRef)@{
			(id)kIOSurfaceWidth: @64, (id)kIOSurfaceHeight: @64, (id)kIOSurfaceBytesPerElement: @4,
			(id)kIOSurfacePixelFormat: @(0x42475241) });	/* 'BGRA' */
		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
		    width:64 height:64 mipmapped:NO];
		td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
		id<MTLTexture> tex = [dev newTextureWithDescriptor:td iosurface:surf plane:0];

		float tri[] = { -1, -1, 1, -1, 0, 1 };
		id<MTLBuffer> vb = [dev newBufferWithBytes:tri length:sizeof(tri) options:MTLResourceStorageModeShared];
		id<MTLBuffer> copy = [dev newBufferWithLength:sizeof(tri) options:MTLResourceStorageModeShared];
		float green[4] = { 0, 1, 0, 1 };

		id<MTLCommandQueue> q = [dev newCommandQueue];
		id<MTLCommandBuffer> cb = [q commandBuffer];
		MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
		rp.colorAttachments[0].texture = tex;
		rp.colorAttachments[0].loadAction = MTLLoadActionClear;
		rp.colorAttachments[0].storeAction = MTLStoreActionStore;
		rp.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 0, 1);
		id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
		if (pipe) {
			[e setRenderPipelineState:pipe];
			[e setVertexBuffer:vb offset:0 atIndex:0];
			[e setFragmentBytes:green length:sizeof(green) atIndex:0];
			[e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
		}
		[e endEncoding];
		id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
		[b copyFromBuffer:vb sourceOffset:0 toBuffer:copy destinationOffset:0 size:sizeof(tri)];
		[b endEncoding];
		__block bool handler = false;
		[cb addCompletedHandler:^(id<MTLCommandBuffer> b) { handler = true; }];
		[cb commit];
		[cb waitUntilCompleted];
		for (int i = 0; i < 100 && !handler; i++) {
			usleep(1000);
		}

		IOSurfaceLock(surf, kIOSurfaceLockReadOnly, NULL);
		uint32_t corner = pixel(surf, 0, 0), center = pixel(surf, 32, 40);
		IOSurfaceUnlock(surf, kIOSurfaceLockReadOnly, NULL);
		uint32_t want_center = pipe ? 0xff00ff00 : 0xffff0000;
		bool blit = memcmp(copy.contents, tri, sizeof(tri)) == 0;
		bool ok = corner == 0xffff0000 && center == want_center && blit && handler && cb.status == MTLCommandBufferStatusCompleted;
		printf("%s: corner %08x (want ffff0000 red), center %08x (want %08x%s), blit %s, handler %d, status %lu\n",
		    ok ? "PASS" : "FAIL", corner, center, want_center, pipe ? " green" : ", no shaders: clear only",
		    blit ? "ok" : "wrong", handler, (unsigned long)cb.status);
		return ok ? 0 : 1;
	}
}
