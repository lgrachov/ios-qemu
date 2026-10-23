/*
 * Host side of QEMU Metal remoting: replays the guest's Metal calls on the
 * host GPU.
 *
 *   qemu-metal-host FILE
 *
 * FILE is the file backing guest RAM that QEMU shares with this helper
 * (qemu-sweet.py --metal FILE; harness.sh --metal starts this helper); the
 * Metal region is at file offset QMTL_PA - QMTL_RAM_BASE. Layout and
 * protocol: tools/guest/qemu-metal/qmtl.h. The guest kernel hands each Metal
 * process a slot; this helper follows every open slot's command ring in
 * order and keeps one host object per guest object id. When a slot's
 * generation changes (process attached or exited) its objects are dropped.
 *
 * Per slot: one MTLCommandQueue (all guest queues map to it, which keeps
 * uploads and command buffers in the guest's order) and one MTLBuffer that
 * wraps the slot heap without copying: every guest buffer is an offset in
 * it. Command buffers complete through Metal's completed handler, which
 * copies IOSurface-backed render targets into staging for the guest and
 * then marks the serial done in the slot header.
 *
 * Built by harness.sh: clang -fobjc-arc -framework Foundation -framework Metal
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <fcntl.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include "../guest/qemu-metal/qmtl.h"

static volatile sig_atomic_t stop;
static id<MTLDevice> device;

static void on_signal(int sig)
{
	(void)sig;
	stop = 1;
}

static void hlog(const char *fmt, ...) __printflike(1, 2);
static void hlog(const char *fmt, ...)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	printf("[qemu-metal-host %5ld.%03ld] ", (long)ts.tv_sec % 100000, ts.tv_nsec / 1000000);
	va_list ap;
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	putchar('\n');
	fflush(stdout);
}

/* a guest buffer: a range of the slot heap */
@interface HBuffer : NSObject {
@public
	uint64_t off, length;
}
@end
@implementation HBuffer
@end

/* a linear texture the host GPU cannot alias in place (row pitch or offset
   not aligned for it): an ordinary texture refreshed from the guest buffer's
   bytes whenever it is bound */
@interface HLinear : NSObject {
@public
	uint64_t off, bpr;
	NSUInteger width, height;
}
@end
@implementation HLinear
@end

static const void *linear_key = &linear_key;

/* a guest command buffer and the IOSurface read-backs it asked for */
@interface HCommandBuffer : NSObject {
@public
	id<MTLCommandBuffer> cb;
}
@end
@implementation HCommandBuffer
@end

@interface Slot : NSObject {
@public
	int index;
	struct qmtl_slot *h;
	uint8_t *base;
	uint32_t generation;		/* served, 0 = none */
	uint64_t tail;
	id<MTLCommandQueue> queue;
	id<MTLBuffer> heap;
	NSMutableDictionary<NSNumber *, id> *objects;
	uint64_t ops, draws, commits;
	NSMutableSet<NSString *> *warned;
}
@end
@implementation Slot
@end

static void warn_once(Slot *s, NSString *what)
{
	if (![s->warned containsObject:what]) {
		[s->warned addObject:what];
		hlog("slot %d: %s", s->index, what.UTF8String);
	}
}

static id obj(Slot *s, uint32_t qid)
{
	return qid ? s->objects[@(qid)] : nil;
}

#define GET(type, var, s, qid, what) \
	type var = obj(s, qid); \
	if (qid && ![var isKindOfClass:[NSObject class]]) { \
		warn_once(s, [NSString stringWithFormat:@"%s: no object %u", what, qid]); \
	}

static void reply(Slot *s, int status, const void *data, uint32_t len)
{
	len = MIN(len, (uint32_t)QMTL_REPLY_SIZE);
	memcpy((void *)s->h->reply, data, len);
	s->h->reply_len = len;
	atomic_store_explicit((_Atomic int32_t *)&s->h->reply_status, status, memory_order_release);
}

static void reply_error(Slot *s, NSString *text)
{
	const char *t = text.UTF8String ?: "error";
	hlog("slot %d: %s", s->index, t);
	reply(s, 1, t, (uint32_t)strlen(t));
}

static void reply_ok(Slot *s)
{
	reply(s, 0, NULL, 0);
}

static void *heap_ptr(Slot *s, uint64_t off)
{
	return s->base + off;
}

/* heap offsets are slot offsets; the heap MTLBuffer starts at QMTL_HEAP_OFFSET */
static NSUInteger heap_rel(uint64_t off)
{
	return (NSUInteger)(off - QMTL_HEAP_OFFSET);
}

static bool in_heap(uint64_t off, uint64_t len)
{
	return off >= QMTL_HEAP_OFFSET && off <= QMTL_SLOT_SIZE && len <= QMTL_SLOT_SIZE - off;
}

static MTLRegion region_of(const struct qmtl_region *r)
{
	return MTLRegionMake3D(r->x, r->y, r->z, r->w, r->h, MAX(r->d, 1u));
}

static void drop_objects(Slot *s)
{
	for (id o in s->objects.allValues) {
		if ([o conformsToProtocol:@protocol(MTLCommandEncoder)]) {
			[(id<MTLCommandEncoder>)o endEncoding];
		}
	}
	[s->objects removeAllObjects];
}

/* ---- creation ops ---- */

static void op_texture_new(Slot *s, const struct qmtl_texture_new *c)
{
	MTLTextureDescriptor *d = [MTLTextureDescriptor new];
	d.textureType = c->desc.type;
	d.pixelFormat = c->desc.pixel_format;
	d.width = MAX(c->desc.width, 1u);
	d.height = MAX(c->desc.height, 1u);
	d.depth = MAX(c->desc.depth, 1u);
	d.mipmapLevelCount = MAX(c->desc.mipmap_levels, 1u);
	d.sampleCount = MAX(c->desc.sample_count, 1u);
	d.arrayLength = MAX(c->desc.array_length, 1u);
	d.usage = c->desc.usage | MTLTextureUsagePixelFormatView;
	d.storageMode = c->desc.storage_mode == MTLStorageModeMemoryless ? MTLStorageModePrivate : c->desc.storage_mode;
	uint32_t sw = c->desc.swizzle;
	if (sw) {
		d.swizzle = MTLTextureSwizzleChannelsMake(sw & 0xff, (sw >> 8) & 0xff, (sw >> 16) & 0xff, sw >> 24);
	}
	id<MTLTexture> t = nil;
	if (c->buffer) {
		GET(HBuffer *, b, s, c->buffer, "texture on buffer");
		if (b) {
			d.storageMode = MTLStorageModeShared;
			NSUInteger align = [device minimumLinearTextureAlignmentForPixelFormat:d.pixelFormat];
			uint64_t off = heap_rel(b->off) + c->buffer_offset;
			if (align && off % align == 0 && c->bytes_per_row % MAX(align, 16u) == 0) {
				t = [s->heap newTextureWithDescriptor:d offset:off bytesPerRow:c->bytes_per_row];
			} else if (in_heap(b->off + c->buffer_offset, c->bytes_per_row * d.height)) {
				t = [device newTextureWithDescriptor:d];
				HLinear *l = [HLinear new];
				l->off = b->off + c->buffer_offset;
				l->bpr = c->bytes_per_row;
				l->width = d.width;
				l->height = d.height;
				objc_setAssociatedObject(t, linear_key, l, OBJC_ASSOCIATION_RETAIN);
			}
		}
	} else {
		t = [device newTextureWithDescriptor:d];
	}
	if (!t) {
		hlog("slot %d: texture %u %ux%u format %u failed", s->index, c->id, c->desc.width, c->desc.height, c->desc.pixel_format);
		return;
	}
	if (c->init_off != ~0ULL && in_heap(c->init_off, c->init_bpi)) {
		if (t.storageMode == MTLStorageModeShared) {
			[t replaceRegion:MTLRegionMake2D(0, 0, d.width, d.height) mipmapLevel:0 slice:0
			    withBytes:heap_ptr(s, c->init_off) bytesPerRow:c->init_bpr bytesPerImage:c->init_bpi];
		} else {
			warn_once(s, @"initial contents for a private texture ignored");
		}
	}
	s->objects[@(c->id)] = t;
}

static void op_texture_io(Slot *s, const struct qmtl_texture_io *c, bool read)
{
	GET(id<MTLTexture>, t, s, c->id, read ? "texture read" : "texture replace");
	NSUInteger rows = MAX(c->region.h, 1u) * MAX(c->region.d, 1u);
	if (!t || !in_heap(c->staging_off, c->bytes_per_row * rows)) {
		if (read) {
			reply_error(s, @"texture read: bad texture or staging");
		}
		return;
	}
	MTLRegion r = region_of(&c->region);
	if (t.storageMode == MTLStorageModeShared) {
		if (read) {
			[t getBytes:heap_ptr(s, c->staging_off) bytesPerRow:c->bytes_per_row bytesPerImage:c->bytes_per_image
			    fromRegion:r mipmapLevel:c->level slice:c->slice];
		} else {
			[t replaceRegion:r mipmapLevel:c->level slice:c->slice withBytes:heap_ptr(s, c->staging_off)
			    bytesPerRow:c->bytes_per_row bytesPerImage:c->bytes_per_image];
		}
	} else {
		/* private: go through a blit on the slot's queue */
		id<MTLCommandBuffer> cb = [s->queue commandBuffer];
		id<MTLBlitCommandEncoder> e = [cb blitCommandEncoder];
		if (read) {
			[e copyFromTexture:t sourceSlice:c->slice sourceLevel:c->level sourceOrigin:r.origin sourceSize:r.size
			    toBuffer:s->heap destinationOffset:heap_rel(c->staging_off) destinationBytesPerRow:c->bytes_per_row
			    destinationBytesPerImage:c->bytes_per_row * MAX(c->region.h, 1u)];
		} else {
			[e copyFromBuffer:s->heap sourceOffset:heap_rel(c->staging_off) sourceBytesPerRow:c->bytes_per_row
			    sourceBytesPerImage:c->bytes_per_row * MAX(c->region.h, 1u) sourceSize:r.size toTexture:t
			    destinationSlice:c->slice destinationLevel:c->level destinationOrigin:r.origin];
		}
		[e endEncoding];
		[cb commit];
		if (read) {
			[cb waitUntilCompleted];
		}
	}
	if (read) {
		reply_ok(s);
	}
}

static void op_library_new(Slot *s, const struct qmtl_library_new *c)
{
	if (!in_heap(c->staging_off, c->length)) {
		reply_error(s, @"library: bad staging range");
		return;
	}
	dispatch_data_t data = dispatch_data_create(heap_ptr(s, c->staging_off), c->length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
	NSError *error = nil;
	id<MTLLibrary> lib = [device newLibraryWithData:data error:&error];
	if (!lib) {
		reply_error(s, [NSString stringWithFormat:@"library: %@", error.localizedDescription]);
		return;
	}
	NSMutableString *list = [NSMutableString string];
	for (NSString *name in lib.functionNames) {
		id<MTLFunction> f = [lib newFunctionWithName:name];
		[list appendFormat:@"%@\t%lu\n", name, (unsigned long)(f ? f.functionType : 0)];
	}
	s->objects[@(c->id)] = lib;
	/* the list goes over the (now consumed) library bytes in staging */
	NSData *d = [list dataUsingEncoding:NSUTF8StringEncoding];
	uint64_t len = MIN((uint64_t)d.length, c->length);
	if (len < d.length) {
		hlog("slot %d: library %u: function list truncated (%lu bytes)", s->index, c->id, (unsigned long)d.length);
	}
	memcpy(heap_ptr(s, c->staging_off), d.bytes, len);
	hlog("slot %d: library %u: %lu functions", s->index, c->id, (unsigned long)lib.functionNames.count);
	reply(s, 0, &len, sizeof(len));
}

static void op_function_new(Slot *s, const struct qmtl_function_new *c)
{
	GET(id<MTLLibrary>, lib, s, c->library, "function");
	if (!lib || c->hdr.size < sizeof(*c) + c->nconstants * sizeof(struct qmtl_constant)) {
		reply_error(s, @"function: bad library or record");
		return;
	}
	NSString *name = [[NSString alloc] initWithBytes:c->name length:strnlen(c->name, sizeof(c->name)) encoding:NSUTF8StringEncoding];
	NSError *error = nil;
	id<MTLFunction> f;
	if (c->nconstants == 0) {
		f = [lib newFunctionWithName:name];
		/* Metal asserts (aborts) when a pipeline uses an unspecialised function */
		for (MTLFunctionConstant *k in f.functionConstantsDictionary.allValues) {
			if (k.required) {
				reply_error(s, [NSString stringWithFormat:@"function %@: constant %@ required but none given", name, k.name]);
				return;
			}
		}
	} else {
		MTLFunctionConstantValues *v = [MTLFunctionConstantValues new];
		for (uint32_t i = 0; i < c->nconstants; i++) {
			const struct qmtl_constant *k = &c->constants[i];
			if (k->index == ~0u) {
				NSString *n = [[NSString alloc] initWithBytes:k->name length:strnlen(k->name, sizeof(k->name)) encoding:NSUTF8StringEncoding];
				[v setConstantValue:k->value type:k->type withName:n];
			} else {
				[v setConstantValue:k->value type:k->type atIndex:k->index];
			}
		}
		f = [lib newFunctionWithName:name constantValues:v error:&error];
	}
	if (!f) {
		reply_error(s, [NSString stringWithFormat:@"function %@: %@", name, error.localizedDescription ?: @"not found"]);
		return;
	}
	s->objects[@(c->id)] = f;
	reply_ok(s);
}

static void op_render_pipeline_new(Slot *s, const struct qmtl_render_pipeline_new *c)
{
	MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
	GET(id<MTLFunction>, vf, s, c->vertex_fn, "pipeline vertex function");
	GET(id<MTLFunction>, ff, s, c->fragment_fn, "pipeline fragment function");
	d.vertexFunction = vf;
	d.fragmentFunction = ff;
	d.depthAttachmentPixelFormat = c->depth_format;
	d.stencilAttachmentPixelFormat = c->stencil_format;
	d.rasterSampleCount = MAX(c->sample_count, 1u);
	d.alphaToCoverageEnabled = c->alpha_to_coverage;
	d.rasterizationEnabled = c->rasterization_enabled;
	d.inputPrimitiveTopology = c->topology_class;
	for (int i = 0; i < 8; i++) {
		const struct qmtl_color_attachment *a = &c->color[i];
		MTLRenderPipelineColorAttachmentDescriptor *o = d.colorAttachments[i];
		o.pixelFormat = a->pixel_format;
		o.writeMask = a->write_mask;
		o.blendingEnabled = a->blending;
		o.rgbBlendOperation = a->rgb_op;
		o.alphaBlendOperation = a->alpha_op;
		o.sourceRGBBlendFactor = a->src_rgb;
		o.destinationRGBBlendFactor = a->dst_rgb;
		o.sourceAlphaBlendFactor = a->src_alpha;
		o.destinationAlphaBlendFactor = a->dst_alpha;
	}
	if (c->has_vertex_desc) {
		MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
		for (int i = 0; i < 16; i++) {
			vd.attributes[i].format = c->attrs[i].format;
			vd.attributes[i].offset = c->attrs[i].offset;
			vd.attributes[i].bufferIndex = c->attrs[i].buffer_index;
		}
		for (int i = 0; i < 8; i++) {
			if (c->layouts[i].stride) {
				vd.layouts[i].stride = c->layouts[i].stride;
				vd.layouts[i].stepFunction = c->layouts[i].step_function;
				vd.layouts[i].stepRate = c->layouts[i].step_rate;
			}
		}
		d.vertexDescriptor = vd;
	}
	if (c->label[0]) {
		d.label = [NSString stringWithUTF8String:c->label];
	}
	NSError *error = nil;
	id<MTLRenderPipelineState> p = [device newRenderPipelineStateWithDescriptor:d error:&error];
	if (!p) {
		reply_error(s, [NSString stringWithFormat:@"render pipeline %s (%@ / %@): %@", c->label, vf.name, ff.name,
		    error.localizedDescription]);
		return;
	}
	s->objects[@(c->id)] = p;
	reply_ok(s);
}

static void op_compute_pipeline_new(Slot *s, const struct qmtl_compute_pipeline_new *c)
{
	GET(id<MTLFunction>, f, s, c->function, "compute pipeline function");
	NSError *error = nil;
	id<MTLComputePipelineState> p = f ? [device newComputePipelineStateWithFunction:f error:&error] : nil;
	if (!p) {
		reply_error(s, [NSString stringWithFormat:@"compute pipeline %@: %@", f.name, error.localizedDescription]);
		return;
	}
	s->objects[@(c->id)] = p;
	uint32_t info[2] = { (uint32_t)p.maxTotalThreadsPerThreadgroup, (uint32_t)p.threadExecutionWidth };
	reply(s, 0, info, sizeof(info));
}

static MTLStencilDescriptor *stencil_of(const struct qmtl_stencil *st)
{
	MTLStencilDescriptor *d = [MTLStencilDescriptor new];
	d.stencilFailureOperation = st->fail;
	d.depthFailureOperation = st->depth_fail;
	d.depthStencilPassOperation = st->pass;
	d.stencilCompareFunction = st->compare;
	d.readMask = st->read_mask;
	d.writeMask = st->write_mask;
	return d;
}

static void op_depth_stencil_new(Slot *s, const struct qmtl_depth_stencil_new *c)
{
	MTLDepthStencilDescriptor *d = [MTLDepthStencilDescriptor new];
	d.depthCompareFunction = c->depth_compare;
	d.depthWriteEnabled = c->depth_write;
	if (c->has_front) {
		d.frontFaceStencil = stencil_of(&c->front);
	}
	if (c->has_back) {
		d.backFaceStencil = stencil_of(&c->back);
	}
	id st = [device newDepthStencilStateWithDescriptor:d];
	if (st) {
		s->objects[@(c->id)] = st;
	}
}

static void op_sampler_new(Slot *s, const struct qmtl_sampler_new *c)
{
	MTLSamplerDescriptor *d = [MTLSamplerDescriptor new];
	d.minFilter = c->min_filter;
	d.magFilter = c->mag_filter;
	d.mipFilter = c->mip_filter;
	d.sAddressMode = c->s_address;
	d.tAddressMode = c->t_address;
	d.rAddressMode = c->r_address;
	d.normalizedCoordinates = c->normalized;
	d.maxAnisotropy = MAX(c->max_anisotropy, 1u);
	d.compareFunction = c->compare;
	d.borderColor = c->border;
	d.lodMinClamp = c->lod_min;
	d.lodMaxClamp = c->lod_max;
	id st = [device newSamplerStateWithDescriptor:d];
	if (st) {
		s->objects[@(c->id)] = st;
	}
}

/* ---- command buffers and encoders ---- */

static void op_cb_commit(Slot *s, const struct qmtl_cb_commit *c)
{
	GET(HCommandBuffer *, hcb, s, c->id, "commit");
	struct qmtl_slot *h = s->h;
	uint32_t gen = s->generation;
	uint64_t serial = c->serial;
	uint32_t n = c->nreadback;
	if (c->hdr.size < sizeof(*c) + n * sizeof(struct qmtl_readback)) {
		n = 0;
	}
	NSMutableArray *reads = [NSMutableArray array];	/* @[texture, off, bpr] */
	for (uint32_t i = 0; i < n; i++) {
		id<MTLTexture> t = obj(s, c->readback[i].texture);
		if (t && in_heap(c->readback[i].staging_off, c->readback[i].bytes_per_row * t.height)) {
			[reads addObject:@[ t, @(c->readback[i].staging_off), @(c->readback[i].bytes_per_row) ]];
		}
	}
	uint8_t *base = s->base;
	void (^done)(uint32_t) = ^(uint32_t error) {
		if (h->generation != gen) {
			return;	/* the process is gone */
		}
		for (NSArray *r in reads) {
			id<MTLTexture> t = r[0];
			[t getBytes:base + [r[1] unsignedLongLongValue] bytesPerRow:[r[2] unsignedLongLongValue]
			    fromRegion:MTLRegionMake2D(0, 0, t.width, t.height) mipmapLevel:0];
		}
		h->cb_error[serial % QMTL_CB_WINDOW] = error;
		atomic_store_explicit((_Atomic uint64_t *)&h->cb_done[serial % QMTL_CB_WINDOW], serial, memory_order_release);
	};
	s->commits++;
	if (!hcb || !hcb->cb) {
		warn_once(s, @"commit of an unknown command buffer");
		done(MTLCommandBufferErrorInternal);
		return;
	}
	[hcb->cb addCompletedHandler:^(id<MTLCommandBuffer> cb) {
		uint32_t error = cb.status == MTLCommandBufferStatusError ? (uint32_t)(cb.error.code ?: 1) : 0;
		if (error) {
			hlog("command buffer %llu: %s", serial, cb.error.localizedDescription.UTF8String);
		}
		done(error);
	}];
	[hcb->cb commit];
	hcb->cb = nil;
}

static void set_attachment(Slot *s, MTLRenderPassAttachmentDescriptor *o, const struct qmtl_attachment *a)
{
	o.texture = obj(s, a->texture);
	o.level = a->level;
	o.slice = a->slice;
	o.depthPlane = a->depth_plane;
	o.loadAction = a->load;
	o.storeAction = a->store;
	if (a->resolve_texture) {
		o.resolveTexture = obj(s, a->resolve_texture);
		o.resolveLevel = a->resolve_level;
		o.resolveSlice = a->resolve_slice;
	}
}

static void op_render_encoder_new(Slot *s, const struct qmtl_render_encoder_new *c)
{
	GET(HCommandBuffer *, hcb, s, c->cb, "render encoder");
	if (!hcb || !hcb->cb) {
		return;
	}
	MTLRenderPassDescriptor *d = [MTLRenderPassDescriptor renderPassDescriptor];
	for (int i = 0; i < 8; i++) {
		if (c->color[i].texture) {
			set_attachment(s, d.colorAttachments[i], &c->color[i]);
			d.colorAttachments[i].clearColor = MTLClearColorMake(c->color[i].clear[0], c->color[i].clear[1],
			    c->color[i].clear[2], c->color[i].clear[3]);
		}
	}
	if (c->depth.texture) {
		set_attachment(s, d.depthAttachment, &c->depth);
		d.depthAttachment.clearDepth = c->depth.clear[0];
	}
	if (c->stencil.texture) {
		set_attachment(s, d.stencilAttachment, &c->stencil);
		d.stencilAttachment.clearStencil = (uint32_t)c->stencil.clear[1];
	}
	if (c->width && c->height) {
		d.renderTargetWidth = c->width;
		d.renderTargetHeight = c->height;
	}
	if (c->layers) {
		d.renderTargetArrayLength = c->layers;
	}
	if (c->samples) {
		d.defaultRasterSampleCount = c->samples;
	}
	id<MTLRenderCommandEncoder> e = [hcb->cb renderCommandEncoderWithDescriptor:d];
	if (e) {
		s->objects[@(c->id)] = e;
	}
}

static void op_set_buffer(Slot *s, const struct qmtl_set_buffer *c)
{
	id e = obj(s, c->enc);
	HBuffer *b = obj(s, c->buffer);
	id<MTLBuffer> buf = b ? s->heap : nil;
	NSUInteger off = b ? heap_rel(b->off) + c->offset : 0;
	switch (c->stage) {
	case QMTL_STAGE_VERTEX: [(id<MTLRenderCommandEncoder>)e setVertexBuffer:buf offset:off atIndex:c->index]; break;
	case QMTL_STAGE_FRAGMENT: [(id<MTLRenderCommandEncoder>)e setFragmentBuffer:buf offset:off atIndex:c->index]; break;
	case QMTL_STAGE_COMPUTE: [(id<MTLComputeCommandEncoder>)e setBuffer:buf offset:off atIndex:c->index]; break;
	}
}

static void op_set_bytes(Slot *s, const struct qmtl_set_bytes *c)
{
	id e = obj(s, c->enc);
	if (c->hdr.size < sizeof(*c) + c->length) {
		return;
	}
	switch (c->stage) {
	case QMTL_STAGE_VERTEX: [(id<MTLRenderCommandEncoder>)e setVertexBytes:c->bytes length:c->length atIndex:c->index]; break;
	case QMTL_STAGE_FRAGMENT: [(id<MTLRenderCommandEncoder>)e setFragmentBytes:c->bytes length:c->length atIndex:c->index]; break;
	case QMTL_STAGE_COMPUTE: [(id<MTLComputeCommandEncoder>)e setBytes:c->bytes length:c->length atIndex:c->index]; break;
	}
}

static void op_set_texture(Slot *s, const struct qmtl_set_texture *c)
{
	id e = obj(s, c->enc);
	id<MTLTexture> t = obj(s, c->texture);
	HLinear *l = t ? objc_getAssociatedObject(t, linear_key) : nil;
	if (l) {
		[t replaceRegion:MTLRegionMake2D(0, 0, l->width, l->height) mipmapLevel:0 withBytes:heap_ptr(s, l->off) bytesPerRow:l->bpr];
	}
	switch (c->stage) {
	case QMTL_STAGE_VERTEX: [(id<MTLRenderCommandEncoder>)e setVertexTexture:t atIndex:c->index]; break;
	case QMTL_STAGE_FRAGMENT: [(id<MTLRenderCommandEncoder>)e setFragmentTexture:t atIndex:c->index]; break;
	case QMTL_STAGE_COMPUTE: [(id<MTLComputeCommandEncoder>)e setTexture:t atIndex:c->index]; break;
	}
}

static void op_set_sampler(Slot *s, const struct qmtl_set_sampler *c)
{
	id e = obj(s, c->enc);
	id<MTLSamplerState> st = obj(s, c->sampler);
	switch (c->stage) {
	case QMTL_STAGE_VERTEX: [(id<MTLRenderCommandEncoder>)e setVertexSamplerState:st atIndex:c->index]; break;
	case QMTL_STAGE_FRAGMENT:
		if (c->has_lod) {
			[(id<MTLRenderCommandEncoder>)e setFragmentSamplerState:st lodMinClamp:c->lod_min lodMaxClamp:c->lod_max atIndex:c->index];
		} else {
			[(id<MTLRenderCommandEncoder>)e setFragmentSamplerState:st atIndex:c->index];
		}
		break;
	case QMTL_STAGE_COMPUTE: [(id<MTLComputeCommandEncoder>)e setSamplerState:st atIndex:c->index]; break;
	}
}

/* Run one ring record; returns false on a malformed record. */
static bool run_cmd(Slot *s, const struct qmtl_cmd *cmd)
{
	static const uint32_t min_size[QMTL_OP_COUNT] = {
		[QMTL_OP_HELLO] = sizeof(struct qmtl_hello), [QMTL_OP_SYNC] = sizeof(struct qmtl_sync),
		[QMTL_OP_FREE] = sizeof(struct qmtl_id), [QMTL_OP_QUEUE_NEW] = sizeof(struct qmtl_id),
		[QMTL_OP_BUFFER_NEW] = sizeof(struct qmtl_buffer_new), [QMTL_OP_TEXTURE_NEW] = sizeof(struct qmtl_texture_new),
		[QMTL_OP_TEXTURE_VIEW] = sizeof(struct qmtl_texture_view), [QMTL_OP_TEXTURE_REPLACE] = sizeof(struct qmtl_texture_io),
		[QMTL_OP_TEXTURE_READ] = sizeof(struct qmtl_texture_io), [QMTL_OP_LIBRARY_NEW] = sizeof(struct qmtl_library_new),
		[QMTL_OP_FUNCTION_NEW] = sizeof(struct qmtl_function_new),
		[QMTL_OP_RENDER_PIPELINE_NEW] = sizeof(struct qmtl_render_pipeline_new),
		[QMTL_OP_COMPUTE_PIPELINE_NEW] = sizeof(struct qmtl_compute_pipeline_new),
		[QMTL_OP_DEPTH_STENCIL_NEW] = sizeof(struct qmtl_depth_stencil_new), [QMTL_OP_SAMPLER_NEW] = sizeof(struct qmtl_sampler_new),
		[QMTL_OP_CB_NEW] = sizeof(struct qmtl_cb_new), [QMTL_OP_CB_COMMIT] = sizeof(struct qmtl_cb_commit),
		[QMTL_OP_RENDER_ENCODER_NEW] = sizeof(struct qmtl_render_encoder_new),
		[QMTL_OP_BLIT_ENCODER_NEW] = sizeof(struct qmtl_encoder_new), [QMTL_OP_COMPUTE_ENCODER_NEW] = sizeof(struct qmtl_encoder_new),
		[QMTL_OP_ENC_END] = sizeof(struct qmtl_id), [QMTL_OP_SET_RENDER_PIPELINE] = sizeof(struct qmtl_enc_obj),
		[QMTL_OP_SET_DEPTH_STENCIL] = sizeof(struct qmtl_enc_obj), [QMTL_OP_SET_VIEWPORT] = sizeof(struct qmtl_viewport),
		[QMTL_OP_SET_SCISSOR] = sizeof(struct qmtl_scissor), [QMTL_OP_SET_RASTER] = sizeof(struct qmtl_raster),
		[QMTL_OP_SET_BLEND_COLOR] = sizeof(struct qmtl_blend_color), [QMTL_OP_SET_STENCIL_REF] = sizeof(struct qmtl_stencil_ref),
		[QMTL_OP_SET_BUFFER] = sizeof(struct qmtl_set_buffer), [QMTL_OP_SET_BYTES] = sizeof(struct qmtl_set_bytes),
		[QMTL_OP_SET_TEXTURE] = sizeof(struct qmtl_set_texture), [QMTL_OP_SET_SAMPLER] = sizeof(struct qmtl_set_sampler),
		[QMTL_OP_DRAW] = sizeof(struct qmtl_draw), [QMTL_OP_DRAW_INDEXED] = sizeof(struct qmtl_draw_indexed),
		[QMTL_OP_SET_COMPUTE_PIPELINE] = sizeof(struct qmtl_enc_obj), [QMTL_OP_DISPATCH] = sizeof(struct qmtl_dispatch),
		[QMTL_OP_COPY_TEX_TEX] = sizeof(struct qmtl_copy_tex_tex), [QMTL_OP_COPY_BUF_BUF] = sizeof(struct qmtl_copy_buf_buf),
		[QMTL_OP_COPY_BUF_TEX] = sizeof(struct qmtl_copy_buf_tex), [QMTL_OP_COPY_TEX_BUF] = sizeof(struct qmtl_copy_buf_tex),
		[QMTL_OP_GEN_MIPMAPS] = sizeof(struct qmtl_gen_mipmaps), [QMTL_OP_FILL_BUF] = sizeof(struct qmtl_fill_buf),
		[QMTL_OP_SET_THREADGROUP_MEMORY] = sizeof(struct qmtl_set_buffer),
	};
	if (cmd->op >= QMTL_OP_COUNT || cmd->size < min_size[cmd->op]) {
		hlog("slot %d: bad record op %u size %u", s->index, cmd->op, cmd->size);
		return false;
	}
	s->ops++;
	const void *p = cmd;

	switch (cmd->op) {
	case QMTL_OP_HELLO:
		hlog("slot %d: hello from %.*s[%d]", s->index, (int)sizeof(s->h->name), s->h->name, ((const struct qmtl_hello *)p)->pid);
		break;
	case QMTL_OP_SYNC:
		atomic_store_explicit((_Atomic uint64_t *)&s->h->completed, ((const struct qmtl_sync *)p)->serial, memory_order_release);
		break;
	case QMTL_OP_FREE: {
		uint32_t oid = ((const struct qmtl_id *)p)->id;
		id o = obj(s, oid);
		if ([o conformsToProtocol:@protocol(MTLCommandEncoder)]) {
			[(id<MTLCommandEncoder>)o endEncoding];
		}
		[s->objects removeObjectForKey:@(oid)];
		break;
	}
	case QMTL_OP_QUEUE_NEW:
		break;	/* all guest queues share the slot's queue */
	case QMTL_OP_BUFFER_NEW: {
		const struct qmtl_buffer_new *c = p;
		if (!in_heap(c->heap_off, c->length)) {
			hlog("slot %d: buffer %u outside the heap", s->index, c->id);
			break;
		}
		HBuffer *b = [HBuffer new];
		b->off = c->heap_off;
		b->length = c->length;
		s->objects[@(c->id)] = b;
		break;
	}
	case QMTL_OP_TEXTURE_NEW: op_texture_new(s, p); break;
	case QMTL_OP_TEXTURE_VIEW: {
		const struct qmtl_texture_view *c = p;
		GET(id<MTLTexture>, parent, s, c->parent, "texture view");
		id<MTLTexture> v = [parent newTextureViewWithPixelFormat:c->pixel_format];
		if (v) {
			s->objects[@(c->id)] = v;
		}
		break;
	}
	case QMTL_OP_TEXTURE_REPLACE: op_texture_io(s, p, false); break;
	case QMTL_OP_TEXTURE_READ: op_texture_io(s, p, true); break;
	case QMTL_OP_LIBRARY_NEW: op_library_new(s, p); break;
	case QMTL_OP_FUNCTION_NEW: op_function_new(s, p); break;
	case QMTL_OP_RENDER_PIPELINE_NEW: op_render_pipeline_new(s, p); break;
	case QMTL_OP_COMPUTE_PIPELINE_NEW: op_compute_pipeline_new(s, p); break;
	case QMTL_OP_DEPTH_STENCIL_NEW: op_depth_stencil_new(s, p); break;
	case QMTL_OP_SAMPLER_NEW: op_sampler_new(s, p); break;
	case QMTL_OP_CB_NEW: {
		const struct qmtl_cb_new *c = p;
		HCommandBuffer *h = [HCommandBuffer new];
		h->cb = [s->queue commandBuffer];
		s->objects[@(c->id)] = h;
		break;
	}
	case QMTL_OP_CB_COMMIT: op_cb_commit(s, p); break;
	case QMTL_OP_RENDER_ENCODER_NEW: op_render_encoder_new(s, p); break;
	case QMTL_OP_BLIT_ENCODER_NEW:
	case QMTL_OP_COMPUTE_ENCODER_NEW: {
		const struct qmtl_encoder_new *c = p;
		GET(HCommandBuffer *, hcb, s, c->cb, "encoder");
		id e = cmd->op == QMTL_OP_BLIT_ENCODER_NEW ? (id)[hcb->cb blitCommandEncoder] : (id)[hcb->cb computeCommandEncoder];
		if (e) {
			s->objects[@(c->id)] = e;
		}
		break;
	}
	case QMTL_OP_ENC_END: {
		uint32_t oid = ((const struct qmtl_id *)p)->id;
		[(id<MTLCommandEncoder>)obj(s, oid) endEncoding];
		[s->objects removeObjectForKey:@(oid)];
		break;
	}
	case QMTL_OP_SET_RENDER_PIPELINE: {
		const struct qmtl_enc_obj *c = p;
		[(id<MTLRenderCommandEncoder>)obj(s, c->enc) setRenderPipelineState:obj(s, c->obj)];
		break;
	}
	case QMTL_OP_SET_DEPTH_STENCIL: {
		const struct qmtl_enc_obj *c = p;
		[(id<MTLRenderCommandEncoder>)obj(s, c->enc) setDepthStencilState:obj(s, c->obj)];
		break;
	}
	case QMTL_OP_SET_VIEWPORT: {
		const struct qmtl_viewport *c = p;
		[(id<MTLRenderCommandEncoder>)obj(s, c->enc) setViewport:(MTLViewport){ c->x, c->y, c->w, c->h, c->znear, c->zfar }];
		break;
	}
	case QMTL_OP_SET_SCISSOR: {
		const struct qmtl_scissor *c = p;
		[(id<MTLRenderCommandEncoder>)obj(s, c->enc) setScissorRect:(MTLScissorRect){ c->x, c->y, c->w, c->h }];
		break;
	}
	case QMTL_OP_SET_RASTER: {
		const struct qmtl_raster *c = p;
		id<MTLRenderCommandEncoder> e = obj(s, c->enc);
		[e setCullMode:c->cull];
		[e setFrontFacingWinding:c->winding];
		[e setTriangleFillMode:c->fill];
		[e setDepthBias:c->depth_bias slopeScale:c->slope_scale clamp:c->clamp];
		break;
	}
	case QMTL_OP_SET_BLEND_COLOR: {
		const struct qmtl_blend_color *c = p;
		[(id<MTLRenderCommandEncoder>)obj(s, c->enc) setBlendColorRed:c->rgba[0] green:c->rgba[1] blue:c->rgba[2] alpha:c->rgba[3]];
		break;
	}
	case QMTL_OP_SET_STENCIL_REF: {
		const struct qmtl_stencil_ref *c = p;
		[(id<MTLRenderCommandEncoder>)obj(s, c->enc) setStencilFrontReferenceValue:c->front backReferenceValue:c->back];
		break;
	}
	case QMTL_OP_SET_BUFFER: op_set_buffer(s, p); break;
	case QMTL_OP_SET_BYTES: op_set_bytes(s, p); break;
	case QMTL_OP_SET_TEXTURE: op_set_texture(s, p); break;
	case QMTL_OP_SET_SAMPLER: op_set_sampler(s, p); break;
	case QMTL_OP_DRAW: {
		const struct qmtl_draw *c = p;
		s->draws++;
		[(id<MTLRenderCommandEncoder>)obj(s, c->enc) drawPrimitives:c->primitive vertexStart:c->start vertexCount:c->count
		    instanceCount:c->instances baseInstance:c->base_instance];
		break;
	}
	case QMTL_OP_DRAW_INDEXED: {
		const struct qmtl_draw_indexed *c = p;
		HBuffer *b = obj(s, c->index_buffer);
		s->draws++;
		if (b) {
			[(id<MTLRenderCommandEncoder>)obj(s, c->enc) drawIndexedPrimitives:c->primitive indexCount:c->index_count
			    indexType:c->index_type indexBuffer:s->heap indexBufferOffset:heap_rel(b->off) + c->index_offset
			    instanceCount:c->instances baseVertex:c->base_vertex baseInstance:c->base_instance];
		}
		break;
	}
	case QMTL_OP_SET_COMPUTE_PIPELINE: {
		const struct qmtl_enc_obj *c = p;
		[(id<MTLComputeCommandEncoder>)obj(s, c->enc) setComputePipelineState:obj(s, c->obj)];
		break;
	}
	case QMTL_OP_SET_THREADGROUP_MEMORY: {
		const struct qmtl_set_buffer *c = p;
		[(id<MTLComputeCommandEncoder>)obj(s, c->enc) setThreadgroupMemoryLength:c->offset atIndex:c->index];
		break;
	}
	case QMTL_OP_DISPATCH: {
		const struct qmtl_dispatch *c = p;
		id<MTLComputeCommandEncoder> e = obj(s, c->enc);
		MTLSize grid = MTLSizeMake(c->grid[0], c->grid[1], c->grid[2]), group = MTLSizeMake(c->group[0], c->group[1], c->group[2]);
		if (c->per_thread) {
			[e dispatchThreads:grid threadsPerThreadgroup:group];
		} else {
			[e dispatchThreadgroups:grid threadsPerThreadgroup:group];
		}
		break;
	}
	case QMTL_OP_COPY_TEX_TEX: {
		const struct qmtl_copy_tex_tex *c = p;
		id<MTLBlitCommandEncoder> e = obj(s, c->enc);
		id<MTLTexture> src = obj(s, c->src), dst = obj(s, c->dst);
		if (c->whole) {
			[e copyFromTexture:src toTexture:dst];
		} else {
			[e copyFromTexture:src sourceSlice:c->src_slice sourceLevel:c->src_level
			    sourceOrigin:MTLOriginMake(c->src_origin[0], c->src_origin[1], c->src_origin[2])
			    sourceSize:MTLSizeMake(c->size[0], c->size[1], c->size[2]) toTexture:dst
			    destinationSlice:c->dst_slice destinationLevel:c->dst_level
			    destinationOrigin:MTLOriginMake(c->dst_origin[0], c->dst_origin[1], c->dst_origin[2])];
		}
		break;
	}
	case QMTL_OP_COPY_BUF_BUF: {
		const struct qmtl_copy_buf_buf *c = p;
		HBuffer *src = obj(s, c->src), *dst = obj(s, c->dst);
		if (src && dst) {
			[(id<MTLBlitCommandEncoder>)obj(s, c->enc) copyFromBuffer:s->heap sourceOffset:heap_rel(src->off) + c->src_off
			    toBuffer:s->heap destinationOffset:heap_rel(dst->off) + c->dst_off size:c->size];
		}
		break;
	}
	case QMTL_OP_COPY_BUF_TEX:
	case QMTL_OP_COPY_TEX_BUF: {
		const struct qmtl_copy_buf_tex *c = p;
		HBuffer *b = obj(s, c->buffer);
		id<MTLTexture> t = obj(s, c->texture);
		id<MTLBlitCommandEncoder> e = obj(s, c->enc);
		if (!b || !t) {
			break;
		}
		MTLOrigin o = MTLOriginMake(c->origin[0], c->origin[1], c->origin[2]);
		MTLSize sz = MTLSizeMake(c->size[0], c->size[1], c->size[2]);
		if (cmd->op == QMTL_OP_COPY_BUF_TEX) {
			[e copyFromBuffer:s->heap sourceOffset:heap_rel(b->off) + c->buffer_off sourceBytesPerRow:c->bytes_per_row
			    sourceBytesPerImage:c->bytes_per_image sourceSize:sz toTexture:t destinationSlice:c->slice
			    destinationLevel:c->level destinationOrigin:o];
		} else {
			[e copyFromTexture:t sourceSlice:c->slice sourceLevel:c->level sourceOrigin:o sourceSize:sz
			    toBuffer:s->heap destinationOffset:heap_rel(b->off) + c->buffer_off destinationBytesPerRow:c->bytes_per_row
			    destinationBytesPerImage:c->bytes_per_image];
		}
		break;
	}
	case QMTL_OP_GEN_MIPMAPS: {
		const struct qmtl_gen_mipmaps *c = p;
		[(id<MTLBlitCommandEncoder>)obj(s, c->enc) generateMipmapsForTexture:obj(s, c->texture)];
		break;
	}
	case QMTL_OP_FILL_BUF: {
		const struct qmtl_fill_buf *c = p;
		HBuffer *b = obj(s, c->buffer);
		if (b) {
			[(id<MTLBlitCommandEncoder>)obj(s, c->enc) fillBuffer:s->heap range:NSMakeRange(heap_rel(b->off) + c->offset, c->length)
			    value:(uint8_t)c->value];
		}
		break;
	}
	default:
		warn_once(s, [NSString stringWithFormat:@"op %u not handled", cmd->op]);
		break;
	}
	return true;
}

/* Consume everything the guest has written; returns whether there was work. */
static bool serve(Slot *s)
{
	struct qmtl_slot *h = s->h;
	uint8_t *ring = (uint8_t *)h + QMTL_HEADER_SIZE;
	uint64_t head = atomic_load_explicit((_Atomic uint64_t *)&h->head, memory_order_acquire);
	bool worked = s->tail != head;

	while (s->tail != head) {
		uint64_t off = s->tail % QMTL_RING_SIZE;
		const struct qmtl_cmd *cmd = (const void *)(ring + off);
		if (head - s->tail < sizeof(*cmd) || cmd->size < sizeof(*cmd) || (cmd->size & 7) ||
		    cmd->size > QMTL_RING_SIZE - off || cmd->size > head - s->tail) {
			hlog("slot %d: corrupt ring at %llu (op %u size %u head %llu); dropping the slot",
			    s->index, s->tail, cmd->op, cmd->size, head);
			s->tail = head;
			s->generation = 0;
			drop_objects(s);
			break;
		}
		if (cmd->op == QMTL_OP_PAD) {
			s->tail += QMTL_RING_SIZE - off;
			continue;
		}
		@autoreleasepool {
			@try {
				run_cmd(s, cmd);
			} @catch (NSException *e) {
				hlog("slot %d: op %u raised %s: %s", s->index, cmd->op, e.name.UTF8String, e.reason.UTF8String);
			}
		}
		s->tail += cmd->size;
		/* let the guest reuse ring space early during long batches */
		atomic_store_explicit((_Atomic uint64_t *)&h->tail, s->tail, memory_order_release);
	}
	atomic_store_explicit((_Atomic uint64_t *)&h->tail, s->tail, memory_order_release);
	return worked;
}

static uint8_t *map_shared(const char *path)
{
	/* QEMU creates and sizes the file; wait for it */
	for (int i = 0; !stop; i++) {
		struct stat st;
		if (stat(path, &st) == 0 && (uint64_t)st.st_size >= QMTL_PA - QMTL_RAM_BASE + QMTL_SIZE) {
			int fd = open(path, O_RDWR);
			if (fd < 0) {
				break;
			}
			void *p = mmap(NULL, QMTL_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, QMTL_PA - QMTL_RAM_BASE);
			close(fd);
			return p == MAP_FAILED ? NULL : p;
		}
		if (i == 0) {
			hlog("waiting for %s", path);
		}
		usleep(100000);
	}
	return NULL;
}

int main(int argc, char **argv)
{
	if (argc != 2) {
		fprintf(stderr, "usage: %s SHARED_FILE\n", argv[0]);
		return 2;
	}
	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);
	setvbuf(stdout, NULL, _IOLBF, 0);

	device = MTLCreateSystemDefaultDevice();
	if (!device) {
		hlog("no Metal device on the host");
		return 1;
	}
	hlog("host GPU: %s", device.name.UTF8String);
	uint8_t *shm = map_shared(argv[1]);
	if (shm == NULL) {
		if (!stop) {
			hlog("cannot map %s", argv[1]);
		}
		return 1;
	}
	hlog("mapped %s (%d slots of %llu MiB)", argv[1], QMTL_SLOTS, QMTL_SLOT_SIZE >> 20);

	NSMutableArray<Slot *> *slots = [NSMutableArray array];
	for (int i = 0; i < QMTL_SLOTS; i++) {
		Slot *s = [Slot new];
		s->index = i;
		s->base = shm + i * QMTL_SLOT_SIZE;
		s->h = (struct qmtl_slot *)s->base;
		s->objects = [NSMutableDictionary dictionary];
		s->warned = [NSMutableSet set];
		[slots addObject:s];
	}

	uint64_t beat = 0;
	time_t last_stats = time(NULL);
	while (!stop) {
		bool worked = false;
		beat++;
		for (Slot *s in slots) {
			struct qmtl_slot *h = s->h;
			uint32_t state = atomic_load_explicit((_Atomic uint32_t *)&h->state, memory_order_acquire);
			uint32_t gen = h->generation;

			if (h->magic != QMTL_MAGIC || state != QMTL_SLOT_OPEN) {
				if (s->generation != 0) {
					hlog("slot %d: closed (%llu ops, %llu draws, %llu commits)", s->index, s->ops, s->draws, s->commits);
					s->generation = 0;
					drop_objects(s);
				}
				continue;
			}
			if (gen != s->generation) {
				if (s->generation != 0) {
					hlog("slot %d: closed (reopened)", s->index);
					drop_objects(s);
				}
				@autoreleasepool {
					s->generation = gen;
					s->tail = 0;
					s->ops = s->draws = s->commits = 0;
					[s->warned removeAllObjects];
					s->queue = [device newCommandQueueWithMaxCommandBufferCount:QMTL_CB_WINDOW / 2];
					s->heap = [device newBufferWithBytesNoCopy:s->base + QMTL_HEAP_OFFSET
					    length:QMTL_SLOT_SIZE - QMTL_HEAP_OFFSET options:MTLResourceStorageModeShared deallocator:nil];
				}
				if (!s->heap) {
					hlog("slot %d: cannot wrap the heap", s->index);
				}
				hlog("slot %d: opened by %.*s[%d] (generation %u)", s->index, (int)sizeof(h->name), h->name, h->pid, gen);
				h->host_version = QMTL_VERSION;
				atomic_store_explicit((_Atomic uint32_t *)&h->host_generation, gen, memory_order_release);
			}
			h->host_heartbeat = beat;
			worked |= serve(s);
		}
		if (time(NULL) - last_stats >= 10) {
			last_stats = time(NULL);
			for (Slot *s in slots) {
				if (s->generation && s->ops) {
					hlog("slot %d (%.*s): %llu ops, %llu draws, %llu commits, %lu objects", s->index,
					    (int)sizeof(s->h->name), s->h->name, s->ops, s->draws, s->commits, (unsigned long)s->objects.count);
				}
			}
		}
		if (!worked) {
			usleep(200);
		}
	}
	hlog("stopped");
	return 0;
}
