/*
 * Metal objects of QEMUMetal.bundle. Each one has a guest-chosen id; creating
 * it and every call that changes GPU state is recorded into the slot's ring
 * (qmtl.h) for tools/host/qemu-metal-host.m, which keeps the matching host
 * object. Freed with QMTL_OP_FREE when the guest object goes away.
 *
 * Memory: buffer contents are in the slot heap, which the host sees in place
 * (zero copy). Textures live on the host. IOSurface-backed textures are
 * uploaded when created and again before a command buffer that samples them
 * if the surface changed (IOSurface seed); a command buffer that renders into
 * one waits for completion and copies the result back into the surface.
 *
 * Methods we do not implement are logged once and return nil/0
 * (forwardInvocation:), so a boot shows what is still missing.
 */
#import <objc/runtime.h>
#include <pthread.h>
#import "qmtl_guest.h"

/* the classes adopt the Metal protocols but implement only what CoreAnimation
   needs; the rest goes through forwardInvocation: (logged) */
#pragma clang diagnostic ignored "-Wprotocol"
#pragma clang diagnostic ignored "-Wobjc-protocol-property-synthesis"
/* encoders, buffer textures and device methods live in categories */
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@class QMTLCommandBuffer, QMTLTexture, QMTLBuffer;

/* ---- common base ---- */

@interface QMTLObject : NSObject {
@public
	uint32_t _qid;
}
@property (copy, atomic) NSString *label;
@end

@implementation QMTLObject

- (instancetype)initNew
{
	if ((self = [super init])) {
		_qid = qmtl_new_id();
	}
	return self;
}

- (id<MTLDevice>)device
{
	return qmtl_device;
}

- (void)dealloc
{
	if (_qid != 0) {
		struct qmtl_id c = { { QMTL_OP_FREE, sizeof(c) }, _qid, 0 };
		qmtl_send(&c, sizeof(c));
	}
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel
{
	return [super methodSignatureForSelector:sel] ?: qmtl_signature([self class], sel);
}

- (void)forwardInvocation:(NSInvocation *)inv
{
	qmtl_log_selector("missing", self, inv.selector);
}

- (void)pushDebugGroup:(NSString *)name { }
- (void)popDebugGroup { }
- (void)insertDebugSignpost:(NSString *)name { }

@end

static uint32_t qid(id obj)
{
	return [obj isKindOfClass:[QMTLObject class]] ? ((QMTLObject *)obj)->_qid : 0;
}

#define ADOPT(...) do { static const char *const p[] = { __VA_ARGS__, NULL }; qmtl_adopt(self, p); } while (0)

/* ---- states, functions, pipelines ---- */

@interface QMTLDepthStencilState : QMTLObject <MTLDepthStencilState> @end
@implementation QMTLDepthStencilState
+ (void)load { ADOPT("MTLDepthStencilState", "MTLDepthStencilStateSPI"); }
@end

@interface QMTLSamplerState : QMTLObject <MTLSamplerState> @end
@implementation QMTLSamplerState
+ (void)load { ADOPT("MTLSamplerState", "MTLSamplerStateSPI"); }
@end

@interface QMTLFunction : QMTLObject <MTLFunction>
@property (strong, nonatomic) NSString *name;
@property (nonatomic) MTLFunctionType functionType;
@end
@implementation QMTLFunction
+ (void)load { ADOPT("MTLFunction", "MTLFunctionSPI"); }
- (NSDictionary *)functionConstantsDictionary { return @{}; }
- (MTLFunctionOptions)options { return MTLFunctionOptionNone; }
- (NSArray *)vertexAttributes { return @[]; }
- (NSArray *)stageInputAttributes { return @[]; }
- (MTLPatchType)patchType { return MTLPatchTypeNone; }
- (NSInteger)patchControlPointCount { return -1; }
@end

@interface QMTLLibrary : QMTLObject <MTLLibrary> {
@public
	NSDictionary<NSString *, NSNumber *> *_types;
}
@end

@implementation QMTLLibrary
+ (void)load { ADOPT("MTLLibrary", "MTLLibrarySPI"); }

- (NSArray<NSString *> *)functionNames
{
	return _types.allKeys;
}

- (MTLLibraryType)type
{
	return MTLLibraryTypeExecutable;
}

- (id<MTLFunction>)makeFunction:(NSString *)name constants:(MTLFunctionConstantValues *)values error:(NSError **)error
{
	if (name == nil || _types[name] == nil) {
		qlog("library %u has no function %s (%lu functions)", _qid, name.UTF8String ?: "(nil)", (unsigned long)_types.count);
		return nil;
	}
	NSArray<NSData *> *constants = qmtl_constants_of(values);
	if (values && constants.count == 0) {
		qlog("function %s: constant values object %s recorded nothing", name.UTF8String, object_getClassName(values));
	}
	uint32_t size = qmtl_size((uint32_t)(sizeof(struct qmtl_function_new) + constants.count * sizeof(struct qmtl_constant)));
	struct qmtl_function_new *c = calloc(1, size);
	QMTLFunction *f = [[QMTLFunction alloc] initNew];
	c->hdr = (struct qmtl_cmd){ QMTL_OP_FUNCTION_NEW, size };
	c->id = f->_qid;
	c->library = _qid;
	strlcpy(c->name, name.UTF8String, sizeof(c->name));
	c->nconstants = (uint32_t)constants.count;
	for (NSUInteger i = 0; i < constants.count; i++) {
		memcpy(&c->constants[i], constants[i].bytes, sizeof(struct qmtl_constant));
	}
	NSData *reply = nil;
	bool ok = qmtl_call(c, size, &reply);
	free(c);
	if (!ok) {
		if (error) {
			*error = qmtl_error([NSString stringWithFormat:@"function %@", name], reply);
		}
		f->_qid = 0;	/* host has none */
		return nil;
	}
	f.name = name;
	f.functionType = (MTLFunctionType)_types[name].unsignedIntegerValue;
	return f;
}

- (id<MTLFunction>)newFunctionWithName:(NSString *)name
{
	return [self makeFunction:name constants:nil error:NULL];
}

- (id<MTLFunction>)newFunctionWithName:(NSString *)name constantValues:(MTLFunctionConstantValues *)values error:(NSError **)error
{
	return [self makeFunction:name constants:values error:error];
}

- (void)newFunctionWithName:(NSString *)name constantValues:(MTLFunctionConstantValues *)values
    completionHandler:(void (^)(id<MTLFunction>, NSError *))handler
{
	NSError *error = nil;
	id<MTLFunction> f = [self makeFunction:name constants:values error:&error];
	handler(f, error);
}

- (id<MTLFunction>)newFunctionWithDescriptor:(MTLFunctionDescriptor *)desc error:(NSError **)error
{
	return [self makeFunction:desc.name constants:desc.constantValues error:error];
}

@end

@interface QMTLRenderPipelineState : QMTLObject <MTLRenderPipelineState> @end
@implementation QMTLRenderPipelineState
+ (void)load { ADOPT("MTLRenderPipelineState", "MTLRenderPipelineStateSPI"); }
- (NSUInteger)maxTotalThreadsPerThreadgroup { return 1024; }
- (BOOL)threadgroupSizeMatchesTileSize { return NO; }
- (NSUInteger)imageblockSampleLength { return 0; }
- (BOOL)supportIndirectCommandBuffers { return NO; }
@end

@interface QMTLComputePipelineState : QMTLObject <MTLComputePipelineState> {
@public
	uint32_t _maxThreads, _width;
}
@end
@implementation QMTLComputePipelineState
+ (void)load { ADOPT("MTLComputePipelineState", "MTLComputePipelineStateSPI"); }
- (NSUInteger)maxTotalThreadsPerThreadgroup { return _maxThreads; }
- (NSUInteger)threadExecutionWidth { return _width; }
- (NSUInteger)staticThreadgroupMemoryLength { return 0; }
- (BOOL)supportIndirectCommandBuffers { return NO; }
@end

/* ---- buffers ---- */

@interface QMTLBuffer : QMTLObject <MTLBuffer> {
@public
	int64_t _off;			/* in the slot heap */
	NSUInteger _length;
	MTLResourceOptions _options;
	void *_noCopy;			/* newBufferWithBytesNoCopy: copied in at commit */
	void (^_deallocator)(void *, NSUInteger);
}
- (void)syncIn;
@end

@implementation QMTLBuffer
+ (void)load { ADOPT("MTLBuffer", "MTLBufferSPI"); }

+ (instancetype)bufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options
{
	int64_t off = qmtl_heap_alloc(MAX(length, 1));
	if (off < 0) {
		return nil;
	}
	QMTLBuffer *b = [[QMTLBuffer alloc] initNew];
	b->_off = off;
	b->_length = length;
	b->_options = options;
	memset(qmtl_heap_ptr(off), 0, length);
	struct qmtl_buffer_new c = { { QMTL_OP_BUFFER_NEW, sizeof(c) }, b->_qid, 0, (uint64_t)off, length, options };
	qmtl_send(&c, sizeof(c));
	return b;
}

- (void)dealloc
{
	if (_deallocator) {
		_deallocator(_noCopy, _length);
	}
	qmtl_heap_free_later(_off);
}

- (void *)contents { return _noCopy ?: qmtl_heap_ptr(_off); }
- (NSUInteger)length { return _length; }
- (NSUInteger)allocatedSize { return _length; }
- (MTLResourceOptions)resourceOptions { return _options; }
- (MTLStorageMode)storageMode { return (MTLStorageMode)((_options & MTLResourceStorageModeMask) >> MTLResourceStorageModeShift); }
- (MTLCPUCacheMode)cpuCacheMode { return (MTLCPUCacheMode)(_options & MTLResourceCPUCacheModeMask); }
- (MTLHazardTrackingMode)hazardTrackingMode { return MTLHazardTrackingModeTracked; }
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)state { return MTLPurgeableStateNonVolatile; }
- (id<MTLHeap>)heap { return nil; }
- (NSUInteger)heapOffset { return 0; }
- (void)didModifyRange:(NSRange)range { }
- (BOOL)isAliasable { return NO; }
- (void)makeAliasable { }
- (uint64_t)gpuAddress { return 0; }

/* newBufferWithBytesNoCopy: the caller may keep writing its memory */
- (void)syncIn
{
	if (_noCopy) {
		memcpy(qmtl_heap_ptr(_off), _noCopy, _length);
	}
}

@end

/* ---- textures ---- */

@interface QMTLTexture : QMTLObject <MTLTexture> {
@public
	struct qmtl_texture_desc _d;
	IOSurfaceRef _surface;
	NSUInteger _plane;
	uint32_t _seed;			/* surface seed of the last upload */
	QMTLBuffer *_buffer;
	NSUInteger _bufferOffset, _bufferBytesPerRow;
	QMTLTexture *_parent;
	BOOL _pooled;			/* surface in the pool: the host uses it in place */
}
@end

static void fill_desc(struct qmtl_texture_desc *d, MTLTextureDescriptor *desc)
{
	d->type = (uint32_t)desc.textureType;
	d->pixel_format = (uint32_t)desc.pixelFormat;
	d->width = (uint32_t)desc.width;
	d->height = (uint32_t)desc.height;
	d->depth = (uint32_t)desc.depth;
	d->mipmap_levels = (uint32_t)desc.mipmapLevelCount;
	d->sample_count = (uint32_t)desc.sampleCount;
	d->array_length = (uint32_t)desc.arrayLength;
	d->usage = (uint32_t)desc.usage;
	d->storage_mode = (uint32_t)desc.storageMode;
	MTLTextureSwizzleChannels s = desc.swizzle;
	d->swizzle = s.red | s.green << 8 | s.blue << 16 | (uint32_t)s.alpha << 24;
}

@implementation QMTLTexture
+ (void)load { ADOPT("MTLTexture", "MTLTextureSPI"); }

- (void)dealloc
{
	if (_surface) {
		CFRelease(_surface);
	}
}

- (MTLTextureType)textureType { return (MTLTextureType)_d.type; }
- (MTLPixelFormat)pixelFormat { return (MTLPixelFormat)_d.pixel_format; }
- (NSUInteger)width { return _d.width; }
- (NSUInteger)height { return _d.height; }
- (NSUInteger)depth { return _d.depth; }
- (NSUInteger)mipmapLevelCount { return _d.mipmap_levels; }
- (NSUInteger)sampleCount { return _d.sample_count; }
- (NSUInteger)arrayLength { return _d.array_length; }
- (MTLTextureUsage)usage { return (MTLTextureUsage)_d.usage; }
- (MTLStorageMode)storageMode { return (MTLStorageMode)_d.storage_mode; }
- (MTLCPUCacheMode)cpuCacheMode { return MTLCPUCacheModeDefaultCache; }
- (MTLHazardTrackingMode)hazardTrackingMode { return MTLHazardTrackingModeTracked; }
- (MTLResourceOptions)resourceOptions { return (MTLResourceOptions)_d.storage_mode << MTLResourceStorageModeShift; }
- (IOSurfaceRef)iosurface { return _surface; }
- (NSUInteger)iosurfacePlane { return _plane; }
- (id<MTLBuffer>)buffer { return _buffer; }
- (NSUInteger)bufferOffset { return _bufferOffset; }
- (NSUInteger)bufferBytesPerRow { return _bufferBytesPerRow; }
- (id<MTLTexture>)parentTexture { return _parent; }
- (id<MTLTexture>)rootResource { return _parent ?: self; }
- (NSUInteger)parentRelativeLevel { return 0; }
- (NSUInteger)parentRelativeSlice { return 0; }
- (BOOL)isFramebufferOnly { return NO; }
- (BOOL)allowGPUOptimizedContents { return YES; }
- (BOOL)isShareable { return NO; }
- (BOOL)isAliasable { return NO; }
- (BOOL)isSparse { return NO; }
- (NSUInteger)allocatedSize { return (NSUInteger)_d.width * _d.height * 4; }
- (NSUInteger)rotation { return 0; }
- (NSUInteger)protectionOptions { return 0; }
- (id<MTLHeap>)heap { return nil; }
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)state { return MTLPurgeableStateNonVolatile; }
- (MTLTextureSwizzleChannels)swizzle
{
	return MTLTextureSwizzleChannelsMake(_d.swizzle & 0xff, (_d.swizzle >> 8) & 0xff, (_d.swizzle >> 16) & 0xff, _d.swizzle >> 24);
}

/* the surface's bytes, sent with op: TEXTURE_NEW initial contents or TEXTURE_REPLACE */
- (int64_t)stageSurface:(uint64_t *)bprOut
{
	size_t bpr = IOSurfaceGetBytesPerRowOfPlane(_surface, _plane);
	size_t h = IOSurfaceGetHeightOfPlane(_surface, _plane);
	int64_t off = qmtl_heap_alloc(bpr * h);
	if (off < 0) {
		return -1;
	}
	IOSurfaceLock(_surface, kIOSurfaceLockReadOnly, NULL);
	memcpy(qmtl_heap_ptr(off), IOSurfaceGetBaseAddressOfPlane(_surface, _plane), bpr * h);
	IOSurfaceUnlock(_surface, kIOSurfaceLockReadOnly, NULL);
	_seed = IOSurfaceGetSeed(_surface);
	*bprOut = bpr;
	return off;
}

/* before a command buffer that samples it: upload if the CPU changed it */
- (void)uploadIfChanged
{
	if (!_surface || IOSurfaceGetSeed(_surface) == _seed) {
		return;
	}
	uint64_t bpr = 0;
	int64_t off = [self stageSurface:&bpr];
	if (off < 0) {
		return;
	}
	struct qmtl_texture_io c = { { QMTL_OP_TEXTURE_REPLACE, sizeof(c) }, _qid, 0, 0, 0,
		{ 0, 0, 0, _d.width, _d.height, 1 }, (uint64_t)off, bpr, bpr * _d.height };
	qmtl_send(&c, sizeof(c));
	qmtl_heap_free_later(off);
}

/* after a command buffer rendered into it: staging -> surface */
- (void)copyBackFrom:(int64_t)off bytesPerRow:(uint64_t)bpr
{
	size_t h = IOSurfaceGetHeightOfPlane(_surface, _plane);
	IOSurfaceLock(_surface, 0, NULL);
	memcpy(IOSurfaceGetBaseAddressOfPlane(_surface, _plane), qmtl_heap_ptr(off), bpr * h);
	IOSurfaceUnlock(_surface, 0, NULL);
	_seed = IOSurfaceGetSeed(_surface);
}

- (void)replaceRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level slice:(NSUInteger)slice
    withBytes:(const void *)bytes bytesPerRow:(NSUInteger)bpr bytesPerImage:(NSUInteger)bpi
{
	NSUInteger rows = region.size.height * MAX(region.size.depth, 1u);
	int64_t off = qmtl_heap_alloc(bpr * rows);
	if (off < 0) {
		return;
	}
	memcpy(qmtl_heap_ptr(off), bytes, bpr * rows);
	struct qmtl_texture_io c = { { QMTL_OP_TEXTURE_REPLACE, sizeof(c) }, _qid, (uint32_t)level, (uint32_t)slice, 0,
		{ (uint32_t)region.origin.x, (uint32_t)region.origin.y, (uint32_t)region.origin.z,
		  (uint32_t)region.size.width, (uint32_t)region.size.height, (uint32_t)region.size.depth },
		(uint64_t)off, bpr, bpi };
	qmtl_send(&c, sizeof(c));
	qmtl_heap_free_later(off);
}

- (void)replaceRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level withBytes:(const void *)bytes bytesPerRow:(NSUInteger)bpr
{
	[self replaceRegion:region mipmapLevel:level slice:0 withBytes:bytes bytesPerRow:bpr bytesPerImage:0];
}

- (void)getBytes:(void *)bytes bytesPerRow:(NSUInteger)bpr bytesPerImage:(NSUInteger)bpi
    fromRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level slice:(NSUInteger)slice
{
	NSUInteger rows = region.size.height * MAX(region.size.depth, 1u);
	int64_t off = qmtl_heap_alloc(bpr * rows);
	if (off < 0) {
		return;
	}
	struct qmtl_texture_io c = { { QMTL_OP_TEXTURE_READ, sizeof(c) }, _qid, (uint32_t)level, (uint32_t)slice, 0,
		{ (uint32_t)region.origin.x, (uint32_t)region.origin.y, (uint32_t)region.origin.z,
		  (uint32_t)region.size.width, (uint32_t)region.size.height, (uint32_t)region.size.depth },
		(uint64_t)off, bpr, bpi };
	if (qmtl_call(&c, sizeof(c), NULL)) {
		memcpy(bytes, qmtl_heap_ptr(off), bpr * rows);
	}
	qmtl_heap_free_later(off);
}

- (void)getBytes:(void *)bytes bytesPerRow:(NSUInteger)bpr fromRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level
{
	[self getBytes:bytes bytesPerRow:bpr bytesPerImage:0 fromRegion:region mipmapLevel:level slice:0];
}

- (id<MTLTexture>)newTextureViewWithPixelFormat:(MTLPixelFormat)format
{
	QMTLTexture *t = [[QMTLTexture alloc] initNew];
	t->_d = _d;
	t->_d.pixel_format = (uint32_t)format;
	t->_parent = self;
	t->_pooled = _pooled;
	if (_surface) {
		t->_surface = (IOSurfaceRef)CFRetain(_surface);
		t->_plane = _plane;
		t->_seed = _seed;
	}
	struct qmtl_texture_view c = { { QMTL_OP_TEXTURE_VIEW, sizeof(c) }, t->_qid, _qid, (uint32_t)format, 0 };
	qmtl_send(&c, sizeof(c));
	return t;
}

- (id<MTLTexture>)newTextureViewWithPixelFormat:(MTLPixelFormat)format textureType:(MTLTextureType)type
    levels:(NSRange)levels slices:(NSRange)slices
{
	return [self newTextureViewWithPixelFormat:format];
}

@end

/* bytes per pixel of the plain formats the pool path supports, else 0 */
static uint32_t format_bpp(MTLPixelFormat f)
{
	switch (f) {
	case MTLPixelFormatR8Unorm: case MTLPixelFormatA8Unorm: return 1;
	case MTLPixelFormatRG8Unorm: case MTLPixelFormatR16Float: return 2;
	case MTLPixelFormatBGRA8Unorm: case MTLPixelFormatBGRA8Unorm_sRGB:
	case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatRGBA8Unorm_sRGB:
	case MTLPixelFormatRGB10A2Unorm: case MTLPixelFormatBGR10A2Unorm: case MTLPixelFormatR32Float: return 4;
	case MTLPixelFormatRGBA16Float: return 8;
	default: return 0;
	}
}

/*
 * The host aliases a pooled surface as a linear texture: only for a single
 * plane whose rows hold the whole texture at the texture's pixel size
 * (planar video formats and odd layouts keep the copy path).
 */
static bool pool_compatible(MTLTextureDescriptor *desc, IOSurfaceRef s, NSUInteger plane)
{
	uint32_t bpp = format_bpp(desc.pixelFormat);
	size_t planes = IOSurfaceGetPlaneCount(s);
	return bpp != 0 && plane == 0 && planes <= 1 && desc.textureType == MTLTextureType2D &&
	    desc.mipmapLevelCount <= 1 && desc.sampleCount <= 1 &&
	    IOSurfaceGetBytesPerElement(s) == bpp && IOSurfaceGetElementWidth(s) == 1 && IOSurfaceGetElementHeight(s) == 1 &&
	    desc.width <= IOSurfaceGetWidth(s) && desc.height <= IOSurfaceGetHeight(s) &&
	    desc.width * bpp <= IOSurfaceGetBytesPerRow(s);
}

static QMTLTexture *new_texture(MTLTextureDescriptor *desc, IOSurfaceRef surface, NSUInteger plane,
    QMTLBuffer *buffer, NSUInteger offset, NSUInteger bpr)
{
	QMTLTexture *t = [[QMTLTexture alloc] initNew];
	struct qmtl_texture_new c = { { QMTL_OP_TEXTURE_NEW, sizeof(c) }, t->_qid };
	fill_desc(&t->_d, desc);
	c.init_off = ~0ULL;
	c.pool_off = ~0ULL;
	if (surface) {
		t->_surface = (IOSurfaceRef)CFRetain(surface);
		t->_plane = plane;
		if (pool_compatible(desc, surface, plane) && qmtl_surface_pool(surface, plane, &c.pool_off, &c.pool_bpr)) {
			t->_pooled = YES;
		} else {
			uint32_t fmt = IOSurfaceGetPixelFormat(surface);
			qmtl_log_once([NSString stringWithFormat:@"copied surface: %c%c%c%c planes %zu bpe %zu texture format %lu",
			    fmt >> 24, fmt >> 16 & 0xff, fmt >> 8 & 0xff, fmt & 0xff, IOSurfaceGetPlaneCount(surface),
			    IOSurfaceGetBytesPerElement(surface), (unsigned long)desc.pixelFormat]);
			uint64_t sbpr = 0;
			int64_t off = [t stageSurface:&sbpr];
			if (off >= 0) {
				c.init_off = (uint64_t)off;
				c.init_bpr = sbpr;
				c.init_bpi = sbpr * t->_d.height;
			}
		}
		c.iosurface = IOSurfaceGetID(surface);
		/* a surface is CPU-visible: keep the host copy readable */
		if (t->_d.storage_mode == MTLStorageModePrivate) {
			t->_d.storage_mode = MTLStorageModeShared;
		}
	}
	if (buffer) {
		t->_buffer = buffer;
		t->_bufferOffset = offset;
		t->_bufferBytesPerRow = bpr;
		c.buffer = buffer->_qid;
		c.buffer_offset = offset;
		c.bytes_per_row = bpr;
	}
	c.desc = t->_d;
	qmtl_send(&c, sizeof(c));
	if (c.init_off != ~0ULL) {
		qmtl_heap_free_later((int64_t)c.init_off);
	}
	return t;
}

@implementation QMTLBuffer (Textures)
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)desc offset:(NSUInteger)offset bytesPerRow:(NSUInteger)bpr
{
	return new_texture(desc, NULL, 0, self, offset, bpr);
}

- (id<MTLTexture>)newLinearTextureWithDescriptor:(MTLTextureDescriptor *)desc offset:(NSUInteger)offset
    bytesPerRow:(NSUInteger)bpr bytesPerImage:(NSUInteger)bpi
{
	return new_texture(desc, NULL, 0, self, offset, bpr);
}
@end

/* ---- command queue and command buffer ---- */

@interface QMTLCommandQueue : QMTLObject <MTLCommandQueue> @end

@interface QMTLCommandBuffer : QMTLObject <MTLCommandBuffer> {
@public
	QMTLCommandQueue *_queue;
	uint64_t _serial;
	MTLCommandBufferStatus _status;
	NSError *_error;
	NSMutableArray *_scheduled, *_completed;
	NSMutableSet<QMTLTexture *> *_sampledSurfaces, *_renderedSurfaces;
	NSMutableSet<QMTLBuffer *> *_noCopyBuffers;
	BOOL _rendersPooledSurface;
	pthread_mutex_t _lock;
	pthread_cond_t _cond;
}
- (void)useTexture:(id)t rendered:(BOOL)rendered;
- (void)useBuffer:(id)b;
@end

@implementation QMTLCommandQueue
+ (void)load { ADOPT("MTLCommandQueue", "MTLCommandQueueSPI"); }

- (instancetype)initNew
{
	if ((self = [super initNew])) {
		struct qmtl_id c = { { QMTL_OP_QUEUE_NEW, sizeof(c) }, _qid, 0 };
		qmtl_send(&c, sizeof(c));
	}
	return self;
}

- (id<MTLCommandBuffer>)commandBuffer
{
	QMTLCommandBuffer *cb = [[QMTLCommandBuffer alloc] initNew];
	cb->_queue = self;
	struct qmtl_cb_new c = { { QMTL_OP_CB_NEW, sizeof(c) }, cb->_qid, _qid };
	qmtl_send(&c, sizeof(c));
	return cb;
}

- (id<MTLCommandBuffer>)commandBufferWithUnretainedReferences { return [self commandBuffer]; }
- (id<MTLCommandBuffer>)commandBufferWithDescriptor:(MTLCommandBufferDescriptor *)d { return [self commandBuffer]; }
- (void)setGPUPriority:(NSUInteger)p { }
- (void)setBackgroundGPUPriority:(NSUInteger)p { }
- (void)setCompletionQueue:(dispatch_queue_t)q { }
- (void)setSubmissionQueue:(dispatch_queue_t)q { }
- (void)insertDebugCaptureBoundary { }
@end

@implementation QMTLCommandBuffer
+ (void)load { ADOPT("MTLCommandBuffer", "MTLCommandBufferSPI"); }

- (instancetype)initNew
{
	if ((self = [super initNew])) {
		_status = MTLCommandBufferStatusNotEnqueued;
		_scheduled = [NSMutableArray array];
		_completed = [NSMutableArray array];
		_sampledSurfaces = [NSMutableSet set];
		_renderedSurfaces = [NSMutableSet set];
		_noCopyBuffers = [NSMutableSet set];
		pthread_mutex_init(&_lock, NULL);
		pthread_cond_init(&_cond, NULL);
	}
	return self;
}

- (void)dealloc
{
	pthread_mutex_destroy(&_lock);
	pthread_cond_destroy(&_cond);
}

- (id<MTLCommandQueue>)commandQueue { return _queue; }
- (MTLCommandBufferStatus)status { return _status; }
- (NSError *)error { return _error; }
- (BOOL)retainedReferences { return YES; }
- (MTLCommandBufferErrorOption)errorOptions { return MTLCommandBufferErrorOptionNone; }
- (CFTimeInterval)GPUStartTime { return 0; }
- (CFTimeInterval)GPUEndTime { return 0; }
- (CFTimeInterval)kernelStartTime { return 0; }
- (CFTimeInterval)kernelEndTime { return 0; }
- (NSUInteger)protectionOptions { return 0; }
- (void)setProtectionOptions:(NSUInteger)o { }
- (void)encodeCacheHintTag:(id)tag resourceGroups:(id)groups count:(NSUInteger)n { }
- (void)encodeCacheHintFinalize:(id)tag resourceGroups:(id)groups count:(NSUInteger)n { }
- (void)enqueue { if (_status == MTLCommandBufferStatusNotEnqueued) _status = MTLCommandBufferStatusEnqueued; }

- (void)useTexture:(id)obj rendered:(BOOL)rendered
{
	QMTLTexture *t = [obj isKindOfClass:[QMTLTexture class]] ? obj : nil;
	if (t && t->_pooled) {
		_rendersPooledSurface |= rendered;
	} else if (t && t->_surface) {
		[(rendered ? _renderedSurfaces : _sampledSurfaces) addObject:t];
	}
}

- (void)useBuffer:(id)obj
{
	QMTLBuffer *b = [obj isKindOfClass:[QMTLBuffer class]] ? obj : nil;
	if (b && b->_noCopy) {
		[_noCopyBuffers addObject:b];
	}
}

- (void)addScheduledHandler:(MTLCommandBufferHandler)block
{
	[_scheduled addObject:[block copy]];
}

- (void)addCompletedHandler:(MTLCommandBufferHandler)block
{
	@synchronized (self) {
		if (_status == MTLCommandBufferStatusCompleted || _status == MTLCommandBufferStatusError) {
			block(self);
			return;
		}
		[_completed addObject:[block copy]];
	}
}

- (void)finishWithError:(uint32_t)error
{
	NSArray *handlers;
	@synchronized (self) {
		if (error) {
			_error = [NSError errorWithDomain:MTLCommandBufferErrorDomain code:error userInfo:nil];
			qlog("command buffer %llu failed on the host: %u", _serial, error);
		}
		pthread_mutex_lock(&_lock);
		_status = error ? MTLCommandBufferStatusError : MTLCommandBufferStatusCompleted;
		pthread_cond_broadcast(&_cond);
		pthread_mutex_unlock(&_lock);
		handlers = [_completed copy];
		[_completed removeAllObjects];
	}
	for (MTLCommandBufferHandler h in handlers) {
		h(self);
	}
}

- (void)commit
{
	if (_status >= MTLCommandBufferStatusCommitted) {
		return;
	}
	for (QMTLTexture *t in _sampledSurfaces) {
		[t uploadIfChanged];
	}
	for (QMTLBuffer *b in _noCopyBuffers) {
		[b syncIn];
	}
	NSArray<QMTLTexture *> *rendered = _renderedSurfaces.allObjects;
	uint32_t size = qmtl_size((uint32_t)(sizeof(struct qmtl_cb_commit) + rendered.count * sizeof(struct qmtl_readback)));
	struct qmtl_cb_commit *c = calloc(1, size);
	int64_t *staging = calloc(rendered.count + 1, sizeof(int64_t));
	uint32_t n = 0;
	for (QMTLTexture *t in rendered) {
		uint64_t bpr = IOSurfaceGetBytesPerRowOfPlane(t->_surface, t->_plane);
		int64_t off = qmtl_heap_alloc(bpr * IOSurfaceGetHeightOfPlane(t->_surface, t->_plane));
		if (off >= 0) {
			staging[n] = off;
			c->readback[n++] = (struct qmtl_readback){ t->_qid, 0, (uint64_t)off, bpr };
		}
	}
	_serial = qmtl_cb_next_serial();
	c->hdr = (struct qmtl_cmd){ QMTL_OP_CB_COMMIT, size };
	c->id = _qid;
	c->nreadback = n;
	c->serial = _serial;
	qmtl_send(c, size);
	qmtl_cb_committed(_serial);
	free(c);

	_status = MTLCommandBufferStatusScheduled;
	for (MTLCommandBufferHandler h in _scheduled) {
		h(self);
	}
	[_scheduled removeAllObjects];

	if (n > 0) {
		/* the display (or another reader) uses the surface right after this:
		   copy the result back before returning */
		qmtl_cb_wait(_serial);
		uint32_t error = 0;
		qmtl_cb_done(_serial, &error);
		for (uint32_t i = 0; i < n; i++) {
			QMTLTexture *t = rendered[i];
			if (!error) {
				[t copyBackFrom:staging[i] bytesPerRow:IOSurfaceGetBytesPerRowOfPlane(t->_surface, t->_plane)];
			}
			qmtl_heap_free_later(staging[i]);
		}
		free(staging);
		QMTLCommandBuffer *me = self;
		qmtl_cb_notify(_serial, ^(uint32_t e) { [me finishWithError:e]; });
		return;
	}
	free(staging);
	struct timespec t0, t1;
	clock_gettime(CLOCK_MONOTONIC, &t0);
	if (_rendersPooledSurface) {
		/* the display copies the surface right after this: let the GPU finish */
		qmtl_cb_wait(_serial);
	}
	clock_gettime(CLOCK_MONOTONIC, &t1);
	qmtl_note_commit((uint64_t)((t1.tv_sec - t0.tv_sec) * 1000000 + (t1.tv_nsec - t0.tv_nsec) / 1000));
	QMTLCommandBuffer *me = self;
	qmtl_cb_notify(_serial, ^(uint32_t e) { [me finishWithError:e]; });
}

- (void)commitAndWaitUntilSubmitted
{
	[self commit];
}

- (void)waitUntilScheduled { }

- (void)waitUntilCompleted
{
	pthread_mutex_lock(&_lock);
	while (_status != MTLCommandBufferStatusCompleted && _status != MTLCommandBufferStatusError) {
		if (_status < MTLCommandBufferStatusCommitted && _serial == 0) {
			break;	/* never committed */
		}
		pthread_cond_wait(&_cond, &_lock);
	}
	pthread_mutex_unlock(&_lock);
}

- (void)presentDrawable:(id<MTLDrawable>)drawable { qmtl_log_selector("missing", self, _cmd); }

@end

/* ---- encoders ---- */

@interface QMTLEncoder : QMTLObject {
@public
	QMTLCommandBuffer *_cb;
	QMTLBuffer *_buffers[4][32];	/* per stage, for set*BufferOffset: */
}
@end

@implementation QMTLEncoder
- (void)endEncoding
{
	struct qmtl_id c = { { QMTL_OP_ENC_END, sizeof(c) }, _qid, 0 };
	qmtl_send(&c, sizeof(c));
	_qid = 0;	/* the host drops it at ENC_END */
}

- (void)setBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset index:(NSUInteger)index stage:(uint32_t)stage
{
	if (index < 32) {
		_buffers[stage][index] = (QMTLBuffer *)buffer;
	}
	[_cb useBuffer:buffer];
	struct qmtl_set_buffer c = { { QMTL_OP_SET_BUFFER, sizeof(c) }, _qid, stage, qid(buffer), (uint32_t)index, offset };
	qmtl_send(&c, sizeof(c));
}

- (void)setBufferOffset:(NSUInteger)offset index:(NSUInteger)index stage:(uint32_t)stage
{
	[self setBuffer:index < 32 ? _buffers[stage][index] : nil offset:offset index:index stage:stage];
}

- (void)setBytes:(const void *)bytes length:(NSUInteger)length index:(NSUInteger)index stage:(uint32_t)stage
{
	uint32_t size = qmtl_size((uint32_t)(sizeof(struct qmtl_set_bytes) + length));
	struct qmtl_set_bytes *c = alloca(size);
	c->hdr = (struct qmtl_cmd){ QMTL_OP_SET_BYTES, size };
	c->enc = _qid;
	c->stage = stage;
	c->index = (uint32_t)index;
	c->length = (uint32_t)length;
	memcpy(c->bytes, bytes, length);
	qmtl_send(c, size);
}

- (void)setTexture:(id<MTLTexture>)texture index:(NSUInteger)index stage:(uint32_t)stage
{
	[_cb useTexture:texture rendered:stage == QMTL_STAGE_COMPUTE];
	[_cb useTexture:texture rendered:NO];
	struct qmtl_set_texture c = { { QMTL_OP_SET_TEXTURE, sizeof(c) }, _qid, stage, qid(texture), (uint32_t)index };
	qmtl_send(&c, sizeof(c));
}

- (void)setSampler:(id<MTLSamplerState>)sampler index:(NSUInteger)index stage:(uint32_t)stage
{
	struct qmtl_set_sampler c = { { QMTL_OP_SET_SAMPLER, sizeof(c) }, _qid, stage, qid(sampler), (uint32_t)index };
	qmtl_send(&c, sizeof(c));
}

- (void)setSampler:(id<MTLSamplerState>)sampler lodMin:(float)lmin lodMax:(float)lmax index:(NSUInteger)index stage:(uint32_t)stage
{
	struct qmtl_set_sampler c = { { QMTL_OP_SET_SAMPLER, sizeof(c) }, _qid, stage, qid(sampler), (uint32_t)index, lmin, lmax, 1 };
	qmtl_send(&c, sizeof(c));
}

- (void)useResource:(id)r usage:(MTLResourceUsage)u { }
- (void)useResource:(id)r usage:(MTLResourceUsage)u stages:(MTLRenderStages)s { }
- (void)useResources:(const id *)r count:(NSUInteger)n usage:(MTLResourceUsage)u { }
- (void)useHeap:(id)h { }
- (void)useHeap:(id)h stages:(MTLRenderStages)s { }
- (void)memoryBarrierWithScope:(MTLBarrierScope)s { }
- (void)memoryBarrierWithScope:(MTLBarrierScope)s afterStages:(MTLRenderStages)a beforeStages:(MTLRenderStages)b { }
- (void)textureBarrier { }
- (void)updateFence:(id)f { }
- (void)waitForFence:(id)f { }
- (void)updateFence:(id)f afterStages:(MTLRenderStages)s { }
- (void)waitForFence:(id)f beforeStages:(MTLRenderStages)s { }
@end

@interface QMTLRenderCommandEncoder : QMTLEncoder <MTLRenderCommandEncoder> @end

@implementation QMTLRenderCommandEncoder
+ (void)load { ADOPT("MTLRenderCommandEncoder", "MTLRenderCommandEncoderSPI"); }

- (void)setRenderPipelineState:(id<MTLRenderPipelineState>)state
{
	struct qmtl_enc_obj c = { { QMTL_OP_SET_RENDER_PIPELINE, sizeof(c) }, _qid, qid(state) };
	qmtl_send(&c, sizeof(c));
}

- (void)setDepthStencilState:(id<MTLDepthStencilState>)state
{
	struct qmtl_enc_obj c = { { QMTL_OP_SET_DEPTH_STENCIL, sizeof(c) }, _qid, qid(state) };
	qmtl_send(&c, sizeof(c));
}

- (void)setViewport:(MTLViewport)v
{
	struct qmtl_viewport c = { { QMTL_OP_SET_VIEWPORT, sizeof(c) }, _qid, 0, v.originX, v.originY, v.width, v.height, v.znear, v.zfar };
	qmtl_send(&c, sizeof(c));
}

- (void)setViewports:(const MTLViewport *)v count:(NSUInteger)n
{
	if (n > 0) {
		[self setViewport:v[0]];
	}
}

- (void)setScissorRect:(MTLScissorRect)r
{
	struct qmtl_scissor c = { { QMTL_OP_SET_SCISSOR, sizeof(c) }, _qid, 0, r.x, r.y, r.width, r.height };
	qmtl_send(&c, sizeof(c));
}

- (void)setScissorRects:(const MTLScissorRect *)r count:(NSUInteger)n
{
	if (n > 0) {
		[self setScissorRect:r[0]];
	}
}

/* cull, winding, fill and depth bias travel together */
static void send_raster(QMTLRenderCommandEncoder *e, struct qmtl_raster *r)
{
	r->hdr = (struct qmtl_cmd){ QMTL_OP_SET_RASTER, sizeof(*r) };
	r->enc = e->_qid;
	qmtl_send(r, sizeof(*r));
}

static struct qmtl_raster *raster_of(QMTLRenderCommandEncoder *e)
{
	static const void *key = &key;
	NSMutableData *d = objc_getAssociatedObject(e, key);
	if (!d) {
		d = [NSMutableData dataWithLength:sizeof(struct qmtl_raster)];
		objc_setAssociatedObject(e, key, d, OBJC_ASSOCIATION_RETAIN);
	}
	return d.mutableBytes;
}

- (void)setCullMode:(MTLCullMode)m { struct qmtl_raster *r = raster_of(self); r->cull = (uint32_t)m; send_raster(self, r); }
- (void)setFrontFacingWinding:(MTLWinding)w { struct qmtl_raster *r = raster_of(self); r->winding = (uint32_t)w; send_raster(self, r); }
- (void)setTriangleFillMode:(MTLTriangleFillMode)f { struct qmtl_raster *r = raster_of(self); r->fill = (uint32_t)f; send_raster(self, r); }
- (void)setDepthBias:(float)b slopeScale:(float)s clamp:(float)c
{
	struct qmtl_raster *r = raster_of(self);
	r->depth_bias = b;
	r->slope_scale = s;
	r->clamp = c;
	send_raster(self, r);
}
- (void)setDepthClipMode:(MTLDepthClipMode)m { }

- (void)setBlendColorRed:(float)r green:(float)g blue:(float)b alpha:(float)a
{
	struct qmtl_blend_color c = { { QMTL_OP_SET_BLEND_COLOR, sizeof(c) }, _qid, 0, { r, g, b, a } };
	qmtl_send(&c, sizeof(c));
}

- (void)setStencilFrontReferenceValue:(uint32_t)f backReferenceValue:(uint32_t)b
{
	struct qmtl_stencil_ref c = { { QMTL_OP_SET_STENCIL_REF, sizeof(c) }, _qid, f, b };
	qmtl_send(&c, sizeof(c));
}

- (void)setStencilReferenceValue:(uint32_t)v
{
	[self setStencilFrontReferenceValue:v backReferenceValue:v];
}

- (void)setVisibilityResultMode:(MTLVisibilityResultMode)m offset:(NSUInteger)o { }

- (void)setVertexBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i { [self setBuffer:b offset:o index:i stage:QMTL_STAGE_VERTEX]; }
- (void)setVertexBufferOffset:(NSUInteger)o atIndex:(NSUInteger)i { [self setBufferOffset:o index:i stage:QMTL_STAGE_VERTEX]; }
- (void)setVertexBytes:(const void *)p length:(NSUInteger)l atIndex:(NSUInteger)i { [self setBytes:p length:l index:i stage:QMTL_STAGE_VERTEX]; }
- (void)setVertexTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i { [self setTexture:t index:i stage:QMTL_STAGE_VERTEX]; }
- (void)setVertexSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)i { [self setSampler:s index:i stage:QMTL_STAGE_VERTEX]; }
- (void)setVertexBuffers:(const id<MTLBuffer> __unsafe_unretained *)b offsets:(const NSUInteger *)o withRange:(NSRange)r
{
	for (NSUInteger k = 0; k < r.length; k++) {
		[self setBuffer:b[k] offset:o[k] index:r.location + k stage:QMTL_STAGE_VERTEX];
	}
}

- (void)setFragmentBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i { [self setBuffer:b offset:o index:i stage:QMTL_STAGE_FRAGMENT]; }
- (void)setFragmentBufferOffset:(NSUInteger)o atIndex:(NSUInteger)i { [self setBufferOffset:o index:i stage:QMTL_STAGE_FRAGMENT]; }
- (void)setFragmentBytes:(const void *)p length:(NSUInteger)l atIndex:(NSUInteger)i { [self setBytes:p length:l index:i stage:QMTL_STAGE_FRAGMENT]; }
- (void)setFragmentTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i { [self setTexture:t index:i stage:QMTL_STAGE_FRAGMENT]; }
- (void)setFragmentSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)i { [self setSampler:s index:i stage:QMTL_STAGE_FRAGMENT]; }
- (void)setFragmentSamplerState:(id<MTLSamplerState>)s lodMinClamp:(float)a lodMaxClamp:(float)b atIndex:(NSUInteger)i
{
	[self setSampler:s lodMin:a lodMax:b index:i stage:QMTL_STAGE_FRAGMENT];
}
- (void)setFragmentTexture:(id<MTLTexture>)t atTextureIndex:(NSUInteger)ti samplerState:(id<MTLSamplerState>)s atSamplerIndex:(NSUInteger)si
{
	[self setTexture:t index:ti stage:QMTL_STAGE_FRAGMENT];
	[self setSampler:s index:si stage:QMTL_STAGE_FRAGMENT];
}
- (void)setFragmentTextures:(const id<MTLTexture> __unsafe_unretained *)t withRange:(NSRange)r
{
	for (NSUInteger k = 0; k < r.length; k++) {
		[self setTexture:t[k] index:r.location + k stage:QMTL_STAGE_FRAGMENT];
	}
}
- (void)setFragmentSamplerStates:(const id<MTLSamplerState> __unsafe_unretained *)s withRange:(NSRange)r
{
	for (NSUInteger k = 0; k < r.length; k++) {
		[self setSampler:s[k] index:r.location + k stage:QMTL_STAGE_FRAGMENT];
	}
}
- (void)setFragmentBuffers:(const id<MTLBuffer> __unsafe_unretained *)b offsets:(const NSUInteger *)o withRange:(NSRange)r
{
	for (NSUInteger k = 0; k < r.length; k++) {
		[self setBuffer:b[k] offset:o[k] index:r.location + k stage:QMTL_STAGE_FRAGMENT];
	}
}

- (void)drawPrimitives:(MTLPrimitiveType)p vertexStart:(NSUInteger)s vertexCount:(NSUInteger)n
    instanceCount:(NSUInteger)i baseInstance:(NSUInteger)b
{
	struct qmtl_draw c = { { QMTL_OP_DRAW, sizeof(c) }, _qid, (uint32_t)p, s, n, i, b };
	qmtl_send(&c, sizeof(c));
}
- (void)drawPrimitives:(MTLPrimitiveType)p vertexStart:(NSUInteger)s vertexCount:(NSUInteger)n instanceCount:(NSUInteger)i
{
	[self drawPrimitives:p vertexStart:s vertexCount:n instanceCount:i baseInstance:0];
}
- (void)drawPrimitives:(MTLPrimitiveType)p vertexStart:(NSUInteger)s vertexCount:(NSUInteger)n
{
	[self drawPrimitives:p vertexStart:s vertexCount:n instanceCount:1 baseInstance:0];
}

- (void)drawIndexedPrimitives:(MTLPrimitiveType)p indexCount:(NSUInteger)n indexType:(MTLIndexType)t
    indexBuffer:(id<MTLBuffer>)b indexBufferOffset:(NSUInteger)o instanceCount:(NSUInteger)i
    baseVertex:(NSInteger)bv baseInstance:(NSUInteger)bi
{
	[_cb useBuffer:b];
	struct qmtl_draw_indexed c = { { QMTL_OP_DRAW_INDEXED, sizeof(c) }, _qid, (uint32_t)p, (uint32_t)t, qid(b), n, o, i, bv, bi };
	qmtl_send(&c, sizeof(c));
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)p indexCount:(NSUInteger)n indexType:(MTLIndexType)t
    indexBuffer:(id<MTLBuffer>)b indexBufferOffset:(NSUInteger)o instanceCount:(NSUInteger)i
{
	[self drawIndexedPrimitives:p indexCount:n indexType:t indexBuffer:b indexBufferOffset:o instanceCount:i baseVertex:0 baseInstance:0];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)p indexCount:(NSUInteger)n indexType:(MTLIndexType)t
    indexBuffer:(id<MTLBuffer>)b indexBufferOffset:(NSUInteger)o
{
	[self drawIndexedPrimitives:p indexCount:n indexType:t indexBuffer:b indexBufferOffset:o instanceCount:1 baseVertex:0 baseInstance:0];
}
@end

@interface QMTLBlitCommandEncoder : QMTLEncoder <MTLBlitCommandEncoder> @end

@implementation QMTLBlitCommandEncoder
+ (void)load { ADOPT("MTLBlitCommandEncoder", "MTLBlitCommandEncoderSPI"); }

- (void)copyFromTexture:(id<MTLTexture>)src sourceSlice:(NSUInteger)ss sourceLevel:(NSUInteger)sl
    sourceOrigin:(MTLOrigin)so sourceSize:(MTLSize)sz toTexture:(id<MTLTexture>)dst
    destinationSlice:(NSUInteger)ds destinationLevel:(NSUInteger)dl destinationOrigin:(MTLOrigin)dorg
{
	[_cb useTexture:src rendered:NO];
	[_cb useTexture:dst rendered:YES];
	struct qmtl_copy_tex_tex c = { { QMTL_OP_COPY_TEX_TEX, sizeof(c) }, _qid, qid(src), qid(dst), 0,
		(uint32_t)ss, (uint32_t)sl, (uint32_t)ds, (uint32_t)dl,
		{ (uint32_t)so.x, (uint32_t)so.y, (uint32_t)so.z }, { (uint32_t)sz.width, (uint32_t)sz.height, (uint32_t)sz.depth },
		{ (uint32_t)dorg.x, (uint32_t)dorg.y, (uint32_t)dorg.z }, 0 };
	qmtl_send(&c, sizeof(c));
}

- (void)copyFromTexture:(id<MTLTexture>)src toTexture:(id<MTLTexture>)dst
{
	[_cb useTexture:src rendered:NO];
	[_cb useTexture:dst rendered:YES];
	struct qmtl_copy_tex_tex c = { { QMTL_OP_COPY_TEX_TEX, sizeof(c) }, _qid, qid(src), qid(dst) };
	c.whole = 1;
	qmtl_send(&c, sizeof(c));
}

- (void)copyFromBuffer:(id<MTLBuffer>)src sourceOffset:(NSUInteger)so toBuffer:(id<MTLBuffer>)dst
    destinationOffset:(NSUInteger)doff size:(NSUInteger)size
{
	[_cb useBuffer:src];
	struct qmtl_copy_buf_buf c = { { QMTL_OP_COPY_BUF_BUF, sizeof(c) }, _qid, qid(src), qid(dst), 0, so, doff, size };
	qmtl_send(&c, sizeof(c));
}

- (void)copyFromBuffer:(id<MTLBuffer>)src sourceOffset:(NSUInteger)so sourceBytesPerRow:(NSUInteger)bpr
    sourceBytesPerImage:(NSUInteger)bpi sourceSize:(MTLSize)sz toTexture:(id<MTLTexture>)dst
    destinationSlice:(NSUInteger)ds destinationLevel:(NSUInteger)dl destinationOrigin:(MTLOrigin)o
{
	[_cb useBuffer:src];
	[_cb useTexture:dst rendered:YES];
	struct qmtl_copy_buf_tex c = { { QMTL_OP_COPY_BUF_TEX, sizeof(c) }, _qid, qid(src), qid(dst), 0, so, bpr, bpi,
		(uint32_t)ds, (uint32_t)dl, { (uint32_t)o.x, (uint32_t)o.y, (uint32_t)o.z },
		{ (uint32_t)sz.width, (uint32_t)sz.height, (uint32_t)sz.depth } };
	qmtl_send(&c, sizeof(c));
}

- (void)copyFromTexture:(id<MTLTexture>)src sourceSlice:(NSUInteger)ss sourceLevel:(NSUInteger)sl
    sourceOrigin:(MTLOrigin)o sourceSize:(MTLSize)sz toBuffer:(id<MTLBuffer>)dst
    destinationOffset:(NSUInteger)doff destinationBytesPerRow:(NSUInteger)bpr destinationBytesPerImage:(NSUInteger)bpi
{
	[_cb useTexture:src rendered:NO];
	struct qmtl_copy_buf_tex c = { { QMTL_OP_COPY_TEX_BUF, sizeof(c) }, _qid, qid(dst), qid(src), 0, doff, bpr, bpi,
		(uint32_t)ss, (uint32_t)sl, { (uint32_t)o.x, (uint32_t)o.y, (uint32_t)o.z },
		{ (uint32_t)sz.width, (uint32_t)sz.height, (uint32_t)sz.depth } };
	qmtl_send(&c, sizeof(c));
}

- (void)generateMipmapsForTexture:(id<MTLTexture>)t
{
	struct qmtl_gen_mipmaps c = { { QMTL_OP_GEN_MIPMAPS, sizeof(c) }, _qid, qid(t) };
	qmtl_send(&c, sizeof(c));
}

- (void)fillBuffer:(id<MTLBuffer>)b range:(NSRange)r value:(uint8_t)v
{
	struct qmtl_fill_buf c = { { QMTL_OP_FILL_BUF, sizeof(c) }, _qid, qid(b), r.location, r.length, v };
	qmtl_send(&c, sizeof(c));
}

- (void)synchronizeResource:(id)r { }
- (void)synchronizeTexture:(id)t slice:(NSUInteger)s level:(NSUInteger)l { }
- (void)optimizeContentsForGPUAccess:(id)t { }
- (void)optimizeContentsForCPUAccess:(id)t { }
@end

@interface QMTLComputeCommandEncoder : QMTLEncoder <MTLComputeCommandEncoder> @end

@implementation QMTLComputeCommandEncoder
+ (void)load { ADOPT("MTLComputeCommandEncoder", "MTLComputeCommandEncoderSPI"); }

- (MTLDispatchType)dispatchType { return MTLDispatchTypeSerial; }

- (void)setComputePipelineState:(id<MTLComputePipelineState>)state
{
	struct qmtl_enc_obj c = { { QMTL_OP_SET_COMPUTE_PIPELINE, sizeof(c) }, _qid, qid(state) };
	qmtl_send(&c, sizeof(c));
}

- (void)setBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i { [self setBuffer:b offset:o index:i stage:QMTL_STAGE_COMPUTE]; }
- (void)setBufferOffset:(NSUInteger)o atIndex:(NSUInteger)i { [self setBufferOffset:o index:i stage:QMTL_STAGE_COMPUTE]; }
- (void)setBytes:(const void *)p length:(NSUInteger)l atIndex:(NSUInteger)i { [self setBytes:p length:l index:i stage:QMTL_STAGE_COMPUTE]; }
- (void)setTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i { [self setTexture:t index:i stage:QMTL_STAGE_COMPUTE]; }
- (void)setSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)i { [self setSampler:s index:i stage:QMTL_STAGE_COMPUTE]; }

- (void)setThreadgroupMemoryLength:(NSUInteger)length atIndex:(NSUInteger)index
{
	struct qmtl_set_buffer c = { { QMTL_OP_SET_THREADGROUP_MEMORY, sizeof(c) }, _qid, QMTL_STAGE_COMPUTE, 0, (uint32_t)index, length };
	qmtl_send(&c, sizeof(c));
}

- (void)dispatch:(MTLSize)grid group:(MTLSize)group perThread:(uint32_t)perThread
{
	struct qmtl_dispatch c = { { QMTL_OP_DISPATCH, sizeof(c) }, _qid, perThread,
		{ grid.width, grid.height, grid.depth }, { group.width, group.height, group.depth } };
	qmtl_send(&c, sizeof(c));
}

- (void)dispatchThreadgroups:(MTLSize)g threadsPerThreadgroup:(MTLSize)t { [self dispatch:g group:t perThread:0]; }
- (void)dispatchThreads:(MTLSize)g threadsPerThreadgroup:(MTLSize)t { [self dispatch:g group:t perThread:1]; }
@end

static uint32_t tex_id(MTLRenderPassAttachmentDescriptor *a, QMTLCommandBuffer *cb, BOOL stored)
{
	if (a.texture == nil) {
		return 0;
	}
	[cb useTexture:a.texture rendered:stored];
	return qid(a.texture);
}

static void fill_attachment(struct qmtl_attachment *o, MTLRenderPassAttachmentDescriptor *a, QMTLCommandBuffer *cb)
{
	BOOL stored = a.storeAction != MTLStoreActionDontCare;
	o->texture = tex_id(a, cb, stored);
	o->level = (uint32_t)a.level;
	o->slice = (uint32_t)a.slice;
	o->depth_plane = (uint32_t)a.depthPlane;
	o->load = (uint32_t)a.loadAction;
	o->store = (uint32_t)a.storeAction;
	if (a.resolveTexture) {
		[cb useTexture:a.resolveTexture rendered:YES];
		o->resolve_texture = qid(a.resolveTexture);
		o->resolve_level = (uint32_t)a.resolveLevel;
		o->resolve_slice = (uint32_t)a.resolveSlice;
	}
}

@implementation QMTLCommandBuffer (Encoders)

- (id<MTLRenderCommandEncoder>)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)desc
{
	QMTLRenderCommandEncoder *e = [[QMTLRenderCommandEncoder alloc] initNew];
	e->_cb = self;
	struct qmtl_render_encoder_new c = { { QMTL_OP_RENDER_ENCODER_NEW, sizeof(c) }, _qid, e->_qid };
	for (int i = 0; i < 8; i++) {
		MTLRenderPassColorAttachmentDescriptor *a = desc.colorAttachments[i];
		fill_attachment(&c.color[i], a, self);
		MTLClearColor cc = a.clearColor;
		c.color[i].clear[0] = cc.red;
		c.color[i].clear[1] = cc.green;
		c.color[i].clear[2] = cc.blue;
		c.color[i].clear[3] = cc.alpha;
	}
	fill_attachment(&c.depth, desc.depthAttachment, self);
	c.depth.clear[0] = desc.depthAttachment.clearDepth;
	fill_attachment(&c.stencil, desc.stencilAttachment, self);
	c.stencil.clear[1] = desc.stencilAttachment.clearStencil;
	c.width = (uint32_t)desc.renderTargetWidth;
	c.height = (uint32_t)desc.renderTargetHeight;
	c.layers = (uint32_t)desc.renderTargetArrayLength;
	c.samples = (uint32_t)desc.defaultRasterSampleCount;
	qmtl_send(&c, sizeof(c));
	return e;
}

- (id<MTLBlitCommandEncoder>)blitCommandEncoder
{
	QMTLBlitCommandEncoder *e = [[QMTLBlitCommandEncoder alloc] initNew];
	e->_cb = self;
	struct qmtl_encoder_new c = { { QMTL_OP_BLIT_ENCODER_NEW, sizeof(c) }, _qid, e->_qid };
	qmtl_send(&c, sizeof(c));
	return e;
}

- (id<MTLComputeCommandEncoder>)computeCommandEncoder
{
	QMTLComputeCommandEncoder *e = [[QMTLComputeCommandEncoder alloc] initNew];
	e->_cb = self;
	struct qmtl_encoder_new c = { { QMTL_OP_COMPUTE_ENCODER_NEW, sizeof(c) }, _qid, e->_qid };
	qmtl_send(&c, sizeof(c));
	return e;
}

- (id<MTLComputeCommandEncoder>)computeCommandEncoderWithDispatchType:(MTLDispatchType)t
{
	return [self computeCommandEncoder];
}

- (id<MTLBlitCommandEncoder>)blitCommandEncoderWithDescriptor:(id)d { return [self blitCommandEncoder]; }
- (id<MTLComputeCommandEncoder>)computeCommandEncoderWithDescriptor:(id)d { return [self computeCommandEncoder]; }
@end

/* ---- heaps: placement is not modelled, each resource stands alone ---- */

@interface QMTLHeap : NSObject <MTLHeap> {
@public
	NSUInteger _size, _used;
	MTLStorageMode _storage;
	MTLCPUCacheMode _cpuCache;
}
@property (copy, atomic) NSString *label;
@end

@implementation QMTLHeap
+ (void)load { ADOPT("MTLHeap", "MTLHeapSPI"); }
- (id<MTLDevice>)device { return qmtl_device; }
- (MTLStorageMode)storageMode { return _storage; }
- (MTLCPUCacheMode)cpuCacheMode { return _cpuCache; }
- (MTLHazardTrackingMode)hazardTrackingMode { return MTLHazardTrackingModeTracked; }
- (MTLResourceOptions)resourceOptions { return (MTLResourceOptions)_storage << MTLResourceStorageModeShift | _cpuCache; }
- (MTLHeapType)type { return MTLHeapTypeAutomatic; }
- (NSUInteger)size { return _size; }
- (NSUInteger)usedSize { return MIN(_used, _size); }
- (NSUInteger)currentAllocatedSize { return _size; }
- (NSUInteger)maxAvailableSizeWithAlignment:(NSUInteger)alignment { return _size > _used ? _size - _used : 0; }
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)state { return MTLPurgeableStateNonVolatile; }

- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options
{
	_used += length;
	return [qmtl_device newBufferWithLength:length options:options];
}

- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)desc
{
	_used += desc.width * desc.height * 4;
	return [qmtl_device newTextureWithDescriptor:desc];
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel
{
	return [super methodSignatureForSelector:sel] ?: qmtl_signature([self class], sel);
}

- (void)forwardInvocation:(NSInvocation *)inv
{
	qmtl_log_selector("missing", self, inv.selector);
}
@end

/* ---- device: object creation ---- */

static NSData *read_library(NSURL *url, NSError **error)
{
	NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:error];
	if (!data) {
		qlog("cannot read library %s", url.path.UTF8String);
	}
	return data;
}

static id<MTLLibrary> new_library(NSData *data, NSString *what, NSError **error)
{
	int64_t off = data ? qmtl_heap_alloc(data.length) : -1;
	if (off < 0) {
		if (error && !*error) {
			*error = qmtl_error(what, [@"no room for the library" dataUsingEncoding:NSUTF8StringEncoding]);
		}
		return nil;
	}
	memcpy(qmtl_heap_ptr(off), data.bytes, data.length);
	QMTLLibrary *lib = [[QMTLLibrary alloc] initNew];
	struct qmtl_library_new c = { { QMTL_OP_LIBRARY_NEW, sizeof(c) }, lib->_qid, 0, (uint64_t)off, data.length };
	NSData *reply = nil;
	bool ok = qmtl_call(&c, sizeof(c), &reply);
	if (!ok || reply.length < 8) {
		qmtl_heap_free_later(off);
		if (error) {
			*error = qmtl_error(what, reply);
		}
		lib->_qid = 0;
		return nil;
	}
	/* the host wrote "name\ttype\n" per function over the staging bytes */
	uint64_t len = 0;
	memcpy(&len, reply.bytes, 8);
	NSString *text = [[NSString alloc] initWithBytes:qmtl_heap_ptr(off) length:MIN(len, (uint64_t)data.length)
	    encoding:NSUTF8StringEncoding];
	qmtl_heap_free_later(off);
	NSMutableDictionary *types = [NSMutableDictionary dictionary];
	for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
		NSArray *f = [line componentsSeparatedByString:@"\t"];
		if (f.count == 2) {
			types[f[0]] = @([f[1] integerValue]);
		}
	}
	lib->_types = types;
	return lib;
}

static void fill_color(struct qmtl_color_attachment *o, MTLRenderPipelineColorAttachmentDescriptor *a)
{
	o->pixel_format = (uint32_t)a.pixelFormat;
	o->write_mask = (uint32_t)a.writeMask;
	o->blending = a.blendingEnabled;
	o->rgb_op = (uint32_t)a.rgbBlendOperation;
	o->alpha_op = (uint32_t)a.alphaBlendOperation;
	o->src_rgb = (uint32_t)a.sourceRGBBlendFactor;
	o->dst_rgb = (uint32_t)a.destinationRGBBlendFactor;
	o->src_alpha = (uint32_t)a.sourceAlphaBlendFactor;
	o->dst_alpha = (uint32_t)a.destinationAlphaBlendFactor;
}

static void fill_stencil(struct qmtl_stencil *o, MTLStencilDescriptor *s)
{
	o->fail = (uint32_t)s.stencilFailureOperation;
	o->depth_fail = (uint32_t)s.depthFailureOperation;
	o->pass = (uint32_t)s.depthStencilPassOperation;
	o->compare = (uint32_t)s.stencilCompareFunction;
	o->read_mask = s.readMask;
	o->write_mask = s.writeMask;
}

@implementation QEMUMTLDevice (Objects)

- (id<MTLCommandQueue>)newCommandQueue
{
	return [[QMTLCommandQueue alloc] initNew];
}

- (id<MTLCommandQueue>)newCommandQueueWithMaxCommandBufferCount:(NSUInteger)n
{
	return [self newCommandQueue];
}

- (id<MTLCommandQueue>)newCommandQueueWithDescriptor:(id)d
{
	return [self newCommandQueue];
}

- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options
{
	return [QMTLBuffer bufferWithLength:length options:options];
}

- (id<MTLBuffer>)newBufferWithBytes:(const void *)bytes length:(NSUInteger)length options:(MTLResourceOptions)options
{
	QMTLBuffer *b = [QMTLBuffer bufferWithLength:length options:options];
	if (b) {
		memcpy(b.contents, bytes, length);
	}
	return b;
}

- (id<MTLBuffer>)newBufferWithBytesNoCopy:(void *)p length:(NSUInteger)length options:(MTLResourceOptions)options
    deallocator:(void (^)(void *, NSUInteger))deallocator
{
	QMTLBuffer *b = [QMTLBuffer bufferWithLength:length options:options];
	if (b) {
		b->_noCopy = p;
		b->_deallocator = [deallocator copy];
		[b syncIn];
	}
	return b;
}

- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)desc
{
	return new_texture(desc, NULL, 0, nil, 0, 0);
}

- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)desc iosurface:(IOSurfaceRef)surface plane:(NSUInteger)plane
{
	if (!surface) {
		return nil;
	}
	return new_texture(desc, surface, plane, nil, 0, 0);
}

- (id<MTLTexture>)newTextureWithBytesNoCopy:(void *)p length:(NSUInteger)length descriptor:(MTLTextureDescriptor *)desc
    deallocator:(void (^)(void *, NSUInteger))deallocator
{
	QMTLBuffer *b = (QMTLBuffer *)[self newBufferWithBytesNoCopy:p length:length options:0 deallocator:deallocator];
	return b ? new_texture(desc, NULL, 0, b, 0, length / MAX(desc.height, 1u)) : nil;
}

- (id<MTLSamplerState>)newSamplerStateWithDescriptor:(MTLSamplerDescriptor *)d
{
	QMTLSamplerState *s = [[QMTLSamplerState alloc] initNew];
	struct qmtl_sampler_new c = { { QMTL_OP_SAMPLER_NEW, sizeof(c) }, s->_qid,
		(uint32_t)d.minFilter, (uint32_t)d.magFilter, (uint32_t)d.mipFilter,
		(uint32_t)d.sAddressMode, (uint32_t)d.tAddressMode, (uint32_t)d.rAddressMode,
		d.normalizedCoordinates, (uint32_t)d.maxAnisotropy, (uint32_t)d.compareFunction, (uint32_t)d.borderColor,
		d.lodMinClamp, d.lodMaxClamp };
	qmtl_send(&c, sizeof(c));
	s.label = d.label;
	return s;
}

- (id<MTLDepthStencilState>)newDepthStencilStateWithDescriptor:(MTLDepthStencilDescriptor *)d
{
	QMTLDepthStencilState *s = [[QMTLDepthStencilState alloc] initNew];
	struct qmtl_depth_stencil_new c = { { QMTL_OP_DEPTH_STENCIL_NEW, sizeof(c) }, s->_qid,
		(uint32_t)d.depthCompareFunction, d.depthWriteEnabled, d.frontFaceStencil != nil, d.backFaceStencil != nil };
	if (d.frontFaceStencil) {
		fill_stencil(&c.front, d.frontFaceStencil);
	}
	if (d.backFaceStencil) {
		fill_stencil(&c.back, d.backFaceStencil);
	}
	qmtl_send(&c, sizeof(c));
	s.label = d.label;
	return s;
}

- (id<MTLLibrary>)newLibraryWithURL:(NSURL *)url error:(NSError **)error
{
	return new_library(read_library(url, error), url.lastPathComponent, error);
}

- (id<MTLLibrary>)newLibraryWithFile:(NSString *)path error:(NSError **)error
{
	return [self newLibraryWithURL:[NSURL fileURLWithPath:path] error:error];
}

- (id<MTLLibrary>)newLibraryWithData:(dispatch_data_t)data error:(NSError **)error
{
	NSMutableData *d = [NSMutableData data];
	dispatch_data_apply(data, ^bool(dispatch_data_t r, size_t o, const void *p, size_t n) {
		[d appendBytes:p length:n];
		return true;
	});
	return new_library(d, @"library data", error);
}

- (id<MTLLibrary>)newDefaultLibraryWithBundle:(NSBundle *)bundle error:(NSError **)error
{
	NSURL *url = [bundle URLForResource:@"default" withExtension:@"metallib"];
	if (!url) {
		if (error) {
			*error = qmtl_error(@"default library", [bundle.bundlePath dataUsingEncoding:NSUTF8StringEncoding]);
		}
		return nil;
	}
	return [self newLibraryWithURL:url error:error];
}

- (id<MTLLibrary>)newDefaultLibrary
{
	return [self newDefaultLibraryWithBundle:[NSBundle mainBundle] error:NULL];
}

- (id<MTLRenderPipelineState>)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)d
    options:(MTLPipelineOption)options reflection:(MTLAutoreleasedRenderPipelineReflection *)reflection error:(NSError **)error
{
	if (reflection) {
		*reflection = nil;
	}
	QMTLRenderPipelineState *p = [[QMTLRenderPipelineState alloc] initNew];
	struct qmtl_render_pipeline_new c = { { QMTL_OP_RENDER_PIPELINE_NEW, sizeof(c) }, p->_qid,
		qid(d.vertexFunction), qid(d.fragmentFunction),
		(uint32_t)d.depthAttachmentPixelFormat, (uint32_t)d.stencilAttachmentPixelFormat,
		(uint32_t)d.rasterSampleCount, d.alphaToCoverageEnabled, d.rasterizationEnabled,
		(uint32_t)d.inputPrimitiveTopology };
	for (int i = 0; i < 8; i++) {
		fill_color(&c.color[i], d.colorAttachments[i]);
	}
	MTLVertexDescriptor *vd = d.vertexDescriptor;
	for (int i = 0; vd && i < 16; i++) {
		MTLVertexAttributeDescriptor *a = vd.attributes[i];
		c.attrs[i] = (struct qmtl_vertex_attr){ (uint32_t)a.format, (uint32_t)a.offset, (uint32_t)a.bufferIndex };
		c.has_vertex_desc |= a.format != MTLVertexFormatInvalid;
	}
	for (int i = 0; vd && i < 8; i++) {
		MTLVertexBufferLayoutDescriptor *l = vd.layouts[i];
		c.layouts[i] = (struct qmtl_vertex_layout){ (uint32_t)l.stride, (uint32_t)l.stepFunction, (uint32_t)l.stepRate };
	}
	if (d.label) {
		strlcpy(c.label, d.label.UTF8String, sizeof(c.label));
	}
	NSData *reply = nil;
	if (!qmtl_call(&c, sizeof(c), &reply)) {
		if (error) {
			*error = qmtl_error([NSString stringWithFormat:@"render pipeline %@", d.label ?: @""], reply);
		}
		p->_qid = 0;
		return nil;
	}
	p.label = d.label;
	return p;
}

- (id<MTLRenderPipelineState>)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)d error:(NSError **)error
{
	return [self newRenderPipelineStateWithDescriptor:d options:MTLPipelineOptionNone reflection:NULL error:error];
}

- (void)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)d
    completionHandler:(MTLNewRenderPipelineStateCompletionHandler)handler
{
	NSError *error = nil;
	id<MTLRenderPipelineState> p = [self newRenderPipelineStateWithDescriptor:d error:&error];
	handler(p, error);
}

- (void)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)d options:(MTLPipelineOption)o
    completionHandler:(MTLNewRenderPipelineStateWithReflectionCompletionHandler)handler
{
	NSError *error = nil;
	id<MTLRenderPipelineState> p = [self newRenderPipelineStateWithDescriptor:d error:&error];
	handler(p, nil, error);
}

- (id<MTLRenderPipelineState>)newRenderPipelineStateWithTileDescriptor:(id)d options:(MTLPipelineOption)o
    reflection:(MTLAutoreleasedRenderPipelineReflection *)r error:(NSError **)error
{
	if (error) {
		*error = qmtl_error(@"tile pipeline", [@"tile shaders are not supported" dataUsingEncoding:NSUTF8StringEncoding]);
	}
	return nil;
}

- (id<MTLComputePipelineState>)newComputePipelineStateWithFunction:(id<MTLFunction>)f
    options:(MTLPipelineOption)o reflection:(MTLAutoreleasedComputePipelineReflection *)r error:(NSError **)error
{
	if (r) {
		*r = nil;
	}
	QMTLComputePipelineState *p = [[QMTLComputePipelineState alloc] initNew];
	struct qmtl_compute_pipeline_new c = { { QMTL_OP_COMPUTE_PIPELINE_NEW, sizeof(c) }, p->_qid, qid(f) };
	NSData *reply = nil;
	if (!qmtl_call(&c, sizeof(c), &reply) || reply.length < 8) {
		if (error) {
			*error = qmtl_error([NSString stringWithFormat:@"compute pipeline %@", f.name], reply);
		}
		p->_qid = 0;
		return nil;
	}
	memcpy(&p->_maxThreads, reply.bytes, 4);
	memcpy(&p->_width, (const uint8_t *)reply.bytes + 4, 4);
	return p;
}

- (id<MTLComputePipelineState>)newComputePipelineStateWithFunction:(id<MTLFunction>)f error:(NSError **)error
{
	return [self newComputePipelineStateWithFunction:f options:MTLPipelineOptionNone reflection:NULL error:error];
}

- (void)newComputePipelineStateWithFunction:(id<MTLFunction>)f completionHandler:(MTLNewComputePipelineStateCompletionHandler)handler
{
	NSError *error = nil;
	id<MTLComputePipelineState> p = [self newComputePipelineStateWithFunction:f error:&error];
	handler(p, error);
}

- (id)newPipelineLibraryWithFilePath:(NSString *)path error:(NSError **)error
{
	if (error) {
		*error = [NSError errorWithDomain:@"QEMUMetal" code:2 userInfo:@{ NSLocalizedDescriptionKey: @"no pipeline libraries" }];
	}
	return nil;
}

- (id<MTLHeap>)newHeapWithDescriptor:(MTLHeapDescriptor *)d
{
	QMTLHeap *h = [QMTLHeap new];
	h->_size = d.size;
	h->_storage = d.storageMode;
	h->_cpuCache = d.cpuCacheMode;
	return h;
}

- (MTLSizeAndAlign)heapBufferSizeAndAlignWithLength:(NSUInteger)length options:(MTLResourceOptions)options
{
	return (MTLSizeAndAlign){ (length + 255) & ~255ul, 256 };
}

- (MTLSizeAndAlign)heapTextureSizeAndAlignWithDescriptor:(MTLTextureDescriptor *)d
{
	NSUInteger size = d.width * d.height * MAX(d.depth, 1u) * MAX(d.arrayLength, 1u) * 16;
	return (MTLSizeAndAlign){ (size + 16383) & ~16383ul, 16384 };
}

- (BOOL)supportsVertexAmplificationCount:(NSUInteger)count
{
	return count == 1;
}

- (id)newResourceGroupFromResources:(const id *)r count:(NSUInteger)n
{
	return nil;
}

@end
