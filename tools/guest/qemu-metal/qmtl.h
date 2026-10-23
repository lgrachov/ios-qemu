/*
 * QEMU Metal remoting: memory layout and ring protocol shared by the guest
 * bundle (tools/guest/qemu-metal), the host helper (tools/host) and, for
 * the slot header, kernel patch 0104 (iokit/Kernel/arm/SweetMetal.cpp keeps
 * its own copy of the constants; keep them in sync).
 *
 * The shared region is guest RAM at QMTL_PA (boot-arg sweetmetal_pa), below
 * the kernel's phys_base so the kernel never uses it for anything else.
 * QEMU backs guest RAM with a shared file (qemu-sweet.py --metal) that the
 * host helper maps too: guest PA QMTL_RAM_BASE = file offset 0. The region
 * is split into QMTL_SLOTS slots; the kernel gives each process that opens the
 * IOAcceleratorES user client one slot and maps it into the process.
 *
 * Slot: [0, QMTL_HEADER_SIZE) header, [QMTL_HEADER_SIZE, +QMTL_RING_SIZE)
 * command ring (guest writes, host reads), rest = heap the guest manages
 * (buffer contents and staging the host reads/writes in place).
 */
#ifndef QMTL_H
#define QMTL_H

#include <stdint.h>

#define QMTL_RAM_BASE		0x40000000ULL	/* virt RAM start */
#define QMTL_PA			0xa0000000ULL
#define QMTL_SIZE		0x10000000ULL	/* 256 MiB */
#define QMTL_SLOTS		8
#define QMTL_SLOT_SIZE		(QMTL_SIZE / QMTL_SLOTS)	/* 32 MiB */
#define QMTL_HEADER_SIZE	0x4000ULL
#define QMTL_RING_SIZE		0x400000ULL	/* 4 MiB */
#define QMTL_HEAP_OFFSET	(QMTL_HEADER_SIZE + QMTL_RING_SIZE)

/* IOSurface pool (kernel patch 0105, SweetSurface.cpp): with sweetmetal=1
   surfaces live here and the host renders into / samples them in place */
#define QMTL_POOL_PA		0xb0000000ULL
#define QMTL_POOL_SIZE		0x50000000ULL	/* 1.25 GiB, up to phys_base */

#define QMTL_MAGIC		0x4c544d51	/* 'QMTL' */
#define QMTL_VERSION		1

/* state, written by the kernel */
#define QMTL_SLOT_FREE		0
#define QMTL_SLOT_OPEN		1

#define QMTL_CB_WINDOW		512	/* command buffers in flight per slot */
#define QMTL_REPLY_SIZE		8192

struct qmtl_slot {
	/* kernel: set on open/close */
	uint32_t magic;
	uint32_t version;
	uint32_t state;
	uint32_t generation;		/* +1 on every open and close */
	int32_t pid;
	char name[36];
	/* guest */
	volatile uint64_t head;		/* ring bytes written (monotonic) */
	volatile uint64_t submitted;	/* last serial sent */
	/* host */
	volatile uint64_t tail;		/* ring bytes consumed (monotonic) */
	volatile uint64_t completed;	/* last SYNC serial reached */
	volatile uint32_t host_generation;	/* generation the host serves */
	volatile uint32_t host_version;
	volatile uint64_t host_heartbeat;
	/* host: answer to the last op that asks for one (guest SYNCs, then reads) */
	volatile int32_t reply_status;	/* 0 ok, else failed */
	uint32_t reply_len;
	char reply[QMTL_REPLY_SIZE];	/* error text or op-specific data */
	/* host: cb_done[serial % QMTL_CB_WINDOW] = serial once that command
	   buffer completed (and its IOSurface read-backs are in staging);
	   cb_error[...] = MTLCommandBufferStatus error code or 0 */
	volatile uint64_t cb_done[QMTL_CB_WINDOW];
	volatile uint32_t cb_error[QMTL_CB_WINDOW];
};

/* ring records: 8-byte aligned, never split across the ring end */
struct qmtl_cmd {
	uint32_t op;
	uint32_t size;			/* whole record incl. this header */
};

/*
 * Objects are named by guest-chosen ids (uint32, never 0, unique per slot).
 * Buffer contents live in the slot heap: the host wraps the whole heap as
 * one MTLBuffer, a guest buffer is (heap offset, length). "staging" offsets
 * are heap offsets too. Ops marked REPLY write reply_status/reply.
 */
enum {
	QMTL_OP_PAD = 0,		/* skip to the ring end */
	QMTL_OP_HELLO,
	QMTL_OP_SYNC,			/* -> completed = serial */
	QMTL_OP_FREE,			/* any object */
	QMTL_OP_QUEUE_NEW,
	QMTL_OP_BUFFER_NEW,
	QMTL_OP_TEXTURE_NEW,
	QMTL_OP_TEXTURE_VIEW,
	QMTL_OP_TEXTURE_REPLACE,
	QMTL_OP_TEXTURE_READ,		/* host writes staging; guest SYNCs */
	QMTL_OP_LIBRARY_NEW,		/* REPLY: u64 length of the function list
					   "name\ttype\n" the host wrote over the staging bytes */
	QMTL_OP_FUNCTION_NEW,		/* REPLY */
	QMTL_OP_RENDER_PIPELINE_NEW,	/* REPLY */
	QMTL_OP_COMPUTE_PIPELINE_NEW,	/* REPLY: u32 maxTotalThreadsPerThreadgroup, threadExecutionWidth */
	QMTL_OP_DEPTH_STENCIL_NEW,
	QMTL_OP_SAMPLER_NEW,
	QMTL_OP_CB_NEW,
	QMTL_OP_CB_COMMIT,
	QMTL_OP_RENDER_ENCODER_NEW,
	QMTL_OP_BLIT_ENCODER_NEW,
	QMTL_OP_COMPUTE_ENCODER_NEW,
	QMTL_OP_ENC_END,
	QMTL_OP_SET_RENDER_PIPELINE,
	QMTL_OP_SET_DEPTH_STENCIL,
	QMTL_OP_SET_VIEWPORT,
	QMTL_OP_SET_SCISSOR,
	QMTL_OP_SET_RASTER,		/* cull, winding, fill, depth bias */
	QMTL_OP_SET_BLEND_COLOR,
	QMTL_OP_SET_STENCIL_REF,
	QMTL_OP_SET_BUFFER,
	QMTL_OP_SET_BYTES,
	QMTL_OP_SET_TEXTURE,
	QMTL_OP_SET_SAMPLER,
	QMTL_OP_DRAW,
	QMTL_OP_DRAW_INDEXED,
	QMTL_OP_SET_COMPUTE_PIPELINE,
	QMTL_OP_DISPATCH,
	QMTL_OP_COPY_TEX_TEX,
	QMTL_OP_COPY_BUF_BUF,
	QMTL_OP_COPY_BUF_TEX,
	QMTL_OP_COPY_TEX_BUF,
	QMTL_OP_GEN_MIPMAPS,
	QMTL_OP_FILL_BUF,
	QMTL_OP_SET_THREADGROUP_MEMORY,	/* qmtl_set_buffer: buffer 0, offset = length */
	QMTL_OP_COUNT
};

enum { QMTL_STAGE_VERTEX, QMTL_STAGE_FRAGMENT, QMTL_STAGE_COMPUTE, QMTL_STAGE_TILE };

struct qmtl_hello { struct qmtl_cmd hdr; int32_t pid; uint32_t pad; };
struct qmtl_sync { struct qmtl_cmd hdr; uint64_t serial; };
struct qmtl_id { struct qmtl_cmd hdr; uint32_t id; uint32_t pad; };	/* FREE, QUEUE_NEW, ENC_END */

struct qmtl_buffer_new {
	struct qmtl_cmd hdr;
	uint32_t id, pad;
	uint64_t heap_off, length, options;
};

struct qmtl_texture_desc {
	uint32_t type, pixel_format;
	uint32_t width, height, depth;
	uint32_t mipmap_levels, sample_count, array_length;
	uint32_t usage, storage_mode;
	uint32_t swizzle;		/* MTLTextureSwizzleChannels packed */
	uint32_t pad;
};

struct qmtl_texture_new {
	struct qmtl_cmd hdr;
	uint32_t id;
	uint32_t buffer;		/* != 0: linear texture on this buffer */
	struct qmtl_texture_desc desc;
	uint64_t buffer_offset;		/* within that buffer */
	uint64_t bytes_per_row;
	uint64_t init_off;		/* staging with initial contents, or ~0 */
	uint64_t init_bpr, init_bpi;
	uint32_t iosurface;		/* IOSurface id (for logs) */
	uint32_t pad;
	uint64_t pool_off;		/* surface in the pool: offset there, or ~0 */
	uint64_t pool_bpr;
};

struct qmtl_texture_view {
	struct qmtl_cmd hdr;
	uint32_t id, parent;
	uint32_t pixel_format, pad;
};

struct qmtl_region { uint32_t x, y, z, w, h, d; };

struct qmtl_texture_io {		/* TEXTURE_REPLACE / TEXTURE_READ */
	struct qmtl_cmd hdr;
	uint32_t id;
	uint32_t level, slice, pad;
	struct qmtl_region region;
	uint64_t staging_off, bytes_per_row, bytes_per_image;
};

struct qmtl_library_new {
	struct qmtl_cmd hdr;
	uint32_t id, pad;
	uint64_t staging_off, length;	/* metallib bytes */
};

/* index ~0: set by name (MTLFunctionConstantValues has no getters; the
   guest records the setters' arguments) */
struct qmtl_constant { uint32_t index, type; uint8_t value[16]; char name[48]; };

struct qmtl_function_new {
	struct qmtl_cmd hdr;
	uint32_t id, library;
	char name[128];
	uint32_t nconstants, pad;
	struct qmtl_constant constants[];	/* specialised with these if any */
};

struct qmtl_color_attachment {
	uint32_t pixel_format, write_mask;
	uint32_t blending, rgb_op, alpha_op;
	uint32_t src_rgb, dst_rgb, src_alpha, dst_alpha;
};

struct qmtl_vertex_attr { uint32_t format, offset, buffer_index, pad; };
struct qmtl_vertex_layout { uint32_t stride, step_function, step_rate, pad; };

struct qmtl_render_pipeline_new {
	struct qmtl_cmd hdr;
	uint32_t id;
	uint32_t vertex_fn, fragment_fn;
	uint32_t depth_format, stencil_format;
	uint32_t sample_count, alpha_to_coverage, rasterization_enabled;
	uint32_t topology_class;
	uint32_t has_vertex_desc;
	struct qmtl_color_attachment color[8];
	struct qmtl_vertex_attr attrs[16];	/* format 0 = unused */
	struct qmtl_vertex_layout layouts[8];	/* stride 0 = unused */
	char label[64];
};

struct qmtl_compute_pipeline_new {
	struct qmtl_cmd hdr;
	uint32_t id, function;
};

struct qmtl_stencil { uint32_t fail, depth_fail, pass, compare, read_mask, write_mask; };

struct qmtl_depth_stencil_new {
	struct qmtl_cmd hdr;
	uint32_t id;
	uint32_t depth_compare, depth_write;
	uint32_t has_front, has_back, pad;
	struct qmtl_stencil front, back;
};

struct qmtl_sampler_new {
	struct qmtl_cmd hdr;
	uint32_t id;
	uint32_t min_filter, mag_filter, mip_filter;
	uint32_t s_address, t_address, r_address;
	uint32_t normalized, max_anisotropy, compare, border;
	float lod_min, lod_max;
	uint32_t pad;
};

struct qmtl_cb_new { struct qmtl_cmd hdr; uint32_t id, queue; };

/* textures backed by an IOSurface that this command buffer renders into:
   after completion the host copies each into staging for the guest */
struct qmtl_readback { uint32_t texture, pad; uint64_t staging_off, bytes_per_row; };

struct qmtl_cb_commit {
	struct qmtl_cmd hdr;
	uint32_t id, nreadback;
	uint64_t serial;
	struct qmtl_readback readback[];
};

struct qmtl_attachment {
	uint32_t texture, level, slice, depth_plane;
	uint32_t load, store;
	uint32_t resolve_texture, resolve_level, resolve_slice, pad;
	double clear[4];		/* color rgba, or depth in [0], stencil in [1] */
};

struct qmtl_render_encoder_new {
	struct qmtl_cmd hdr;
	uint32_t cb, id;
	struct qmtl_attachment color[8];
	struct qmtl_attachment depth, stencil;
	uint32_t width, height;		/* renderTargetWidth/Height, 0 = default */
	uint32_t layers, samples;
};

struct qmtl_encoder_new { struct qmtl_cmd hdr; uint32_t cb, id; };	/* BLIT, COMPUTE */

struct qmtl_enc_obj { struct qmtl_cmd hdr; uint32_t enc, obj; };	/* SET_*_PIPELINE, SET_DEPTH_STENCIL */

struct qmtl_viewport {
	struct qmtl_cmd hdr;
	uint32_t enc, pad;
	double x, y, w, h, znear, zfar;
};

struct qmtl_scissor { struct qmtl_cmd hdr; uint32_t enc, pad; uint64_t x, y, w, h; };

struct qmtl_raster {
	struct qmtl_cmd hdr;
	uint32_t enc;
	uint32_t cull, winding, fill;
	float depth_bias, slope_scale, clamp;
	uint32_t pad;
};

struct qmtl_blend_color { struct qmtl_cmd hdr; uint32_t enc, pad; float rgba[4]; };
struct qmtl_stencil_ref { struct qmtl_cmd hdr; uint32_t enc, front, back, pad; };

struct qmtl_set_buffer {
	struct qmtl_cmd hdr;
	uint32_t enc, stage, buffer, index;
	uint64_t offset;
};

struct qmtl_set_bytes {
	struct qmtl_cmd hdr;
	uint32_t enc, stage, index, length;
	uint8_t bytes[];
};

struct qmtl_set_texture { struct qmtl_cmd hdr; uint32_t enc, stage, texture, index; };
struct qmtl_set_sampler {
	struct qmtl_cmd hdr;
	uint32_t enc, stage, sampler, index;
	float lod_min, lod_max;
	uint32_t has_lod, pad;
};

struct qmtl_draw {
	struct qmtl_cmd hdr;
	uint32_t enc, primitive;
	uint64_t start, count, instances, base_instance;
};

struct qmtl_draw_indexed {
	struct qmtl_cmd hdr;
	uint32_t enc, primitive;
	uint32_t index_type, index_buffer;
	uint64_t index_count, index_offset, instances;
	int64_t base_vertex;
	uint64_t base_instance;
};

struct qmtl_dispatch {
	struct qmtl_cmd hdr;
	uint32_t enc, per_thread;	/* per_thread: dispatchThreads instead of dispatchThreadgroups */
	uint64_t grid[3], group[3];
};

struct qmtl_copy_tex_tex {
	struct qmtl_cmd hdr;
	uint32_t enc, src, dst, pad;
	uint32_t src_slice, src_level, dst_slice, dst_level;
	uint32_t src_origin[3], size[3], dst_origin[3], whole;	/* whole: copyFromTexture:toTexture: */
};

struct qmtl_copy_buf_buf {
	struct qmtl_cmd hdr;
	uint32_t enc, src, dst, pad;
	uint64_t src_off, dst_off, size;
};

struct qmtl_copy_buf_tex {		/* COPY_BUF_TEX and COPY_TEX_BUF */
	struct qmtl_cmd hdr;
	uint32_t enc, buffer, texture, pad;
	uint64_t buffer_off, bytes_per_row, bytes_per_image;
	uint32_t slice, level;
	uint32_t origin[3], size[3];
};

struct qmtl_gen_mipmaps { struct qmtl_cmd hdr; uint32_t enc, texture; };

struct qmtl_fill_buf {
	struct qmtl_cmd hdr;
	uint32_t enc, buffer;
	uint64_t offset, length;
	uint32_t value, pad;
};

_Static_assert(sizeof(struct qmtl_slot) <= QMTL_HEADER_SIZE, "slot header too big");

#endif /* QMTL_H */
