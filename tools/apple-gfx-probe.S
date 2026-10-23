/*
 * Bare-metal probe for QEMU's apple-gfx-pci (Apple ParavirtualizedGraphics) on
 * -M virt, without our kernel: gives the device at 00:02.0 BAR0 = 0x10000000,
 * enables memory space + bus mastering, then reads all 16 KiB of BAR0 as
 * 32-bit guest loads. QEMU's apple_gfx_read trace shows each value.
 *
 *   xcrun clang -target aarch64-none-elf -c apple-gfx-probe.S -o p.o
 *   xcrun llvm-objcopy -O binary -j .text p.o p.bin
 *   qemu-system-aarch64 -M virt,gic-version=3,highmem-ecam=off -accel hvf -cpu host \
 *     -m 2G -display none -serial none -device apple-gfx-pci,addr=0x2 \
 *     -device loader,file=p.bin,addr=0x40200000,force-raw=on \
 *     -device loader,addr=0x40200000,cpu-num=0 -monitor stdio \
 *     -trace 'apple_gfx*' -D trace.log
 *
 * Results are also stored in guest RAM at RES (xp /20wx 0x40300000):
 * +0 vendor/device, +4 BAR0 size mask, +8 BAR0 readback, +12 command,
 * +16 0x600df00d when done, +64 the registers.
 */
#define ECAM	0x3f000000
#define SLOT	2
#define BAR	0x10000000
#define RES	0x40300000
	.text
	.globl _start
_start:
	ldr	x12, =(ECAM + (SLOT << 15))
	ldr	x10, =RES
	ldr	w1, [x12]
	str	w1, [x10]
	mov	w1, #-1
	str	w1, [x12, #0x10]
	ldr	w1, [x12, #0x10]
	str	w1, [x10, #4]
	ldr	w1, =BAR
	str	w1, [x12, #0x10]
	ldr	w1, [x12, #0x10]
	str	w1, [x10, #8]
	ldr	w1, [x12, #4]
	orr	w1, w1, #6
	str	w1, [x12, #4]
	ldr	w1, [x12, #4]
	str	w1, [x10, #12]
	ldr	x13, =BAR
	add	x11, x10, #64
	mov	x2, #0
	mov	x3, #0x4000
1:	ldr	w1, [x13, x2]
	str	w1, [x11, x2]
	add	x2, x2, #4
	cmp	x2, x3
	b.ne	1b
	ldr	w1, =0x600df00d
	str	w1, [x10, #16]
	dsb	sy
2:	wfe
	b	2b
	.ltorg
