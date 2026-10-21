/*
 * Entry stub for tools/qemu-sweet.py --display: registers the phone's
 * framebuffer with QEMU's ramfb device, then jumps to the kernel with
 * x0 = boot_args. ramfb then shows that guest RAM live in the QEMU window.
 *
 * Built by qemu-sweet.py with
 *   clang -target aarch64-none-elf -c -DBOOT_ARGS=.. -DENTRY=.. -DFB_BASE=.. -DFB_W=.. -DFB_H=..
 * Runs at EL1 with the MMU off: every access is Device memory, so all
 * loads and stores must be naturally aligned.
 *
 * fw_cfg (virt: MMIO 0x09020000, DMA register at +16) holds a file
 * directory; the stub looks up "etc/ramfb" and writes a RAMFBCfg to it.
 * All fw_cfg structures are big endian. If ramfb is absent the kernel
 * still boots, just without a live picture.
 */
#define FW_CFG_BASE	0x09020000
#define FW_CFG_FILE_DIR	0x19
#define DMA_ERROR	0x01
#define DMA_READ	0x02
#define DMA_SELECT	0x08
#define DMA_WRITE	0x10
#define DIR_SIZE	4096
#define XRGB8888	0x34325258	/* DRM fourcc 'XR24': a8r8g8b8 little endian */

.macro be32 v
	.byte ((\v) >> 24) & 0xff, ((\v) >> 16) & 0xff, ((\v) >> 8) & 0xff, (\v) & 0xff
.endm

	.text
	.globl _start
_start:
	ldr	x9, fw_cfg
	adr	x10, dma
	adr	x11, dir

	/* read the file directory into dir */
	mov	w1, #(DMA_SELECT | DMA_READ)
	movk	w1, #FW_CFG_FILE_DIR, lsl #16
	mov	w2, #DIR_SIZE
	mov	x3, x11
	bl	dma_go

	/* dir: be32 count, then {be32 size; be16 select; be16 reserved; char name[56]} */
	ldr	w2, [x11]
	rev	w2, w2
	add	x3, x11, #4
next:
	cbz	w2, boot
	add	x4, x3, #8
	adr	x5, ramfb_name
cmp_byte:
	ldrb	w6, [x4], #1
	ldrb	w7, [x5], #1
	cmp	w6, w7
	b.ne	skip
	cbnz	w6, cmp_byte

	/* found: write the RAMFBCfg to the selected file */
	ldrh	w6, [x3, #4]
	rev16	w6, w6
	lsl	w1, w6, #16
	orr	w1, w1, #(DMA_SELECT | DMA_WRITE)
	mov	w2, #(cfg_end - cfg)
	adr	x3, cfg
	bl	dma_go
	b	boot
skip:
	add	x3, x3, #64
	sub	w2, w2, #1
	b	next

boot:
	ldr	x0, boot_args
	ldr	x1, entry
	br	x1

/* w1 = control, w2 = length, x3 = buffer address; x10 = FWCfgDmaAccess */
dma_go:
	rev	w1, w1
	rev	w2, w2
	rev	x3, x3
	str	w1, [x10]
	str	w2, [x10, #4]
	str	x3, [x10, #8]
	dsb	sy
	rev	x1, x10
	str	x1, [x9, #16]		/* writing the address starts the transfer */
wait:
	ldr	w1, [x10]
	rev	w1, w1
	and	w1, w1, #~DMA_ERROR	/* QEMU clears control when done, ERROR stays set on failure */
	cbnz	w1, wait
	ret

	.balign 8
fw_cfg:		.quad FW_CFG_BASE
boot_args:	.quad BOOT_ARGS
entry:		.quad ENTRY
cfg:		/* RAMFBCfg: be64 addr, be32 fourcc, flags, width, height, stride */
	be32	(FB_BASE >> 32)
	be32	(FB_BASE & 0xffffffff)
	be32	XRGB8888
	be32	0
	be32	FB_W
	be32	FB_H
	be32	(FB_W * 4)
cfg_end:
ramfb_name:	.asciz "etc/ramfb"
	.balign 16
dma:		.skip 16
	.balign 64
dir:		.skip DIR_SIZE
