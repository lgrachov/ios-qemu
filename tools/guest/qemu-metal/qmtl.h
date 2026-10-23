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

#define QMTL_MAGIC		0x4c544d51	/* 'QMTL' */
#define QMTL_VERSION		1

/* state, written by the kernel */
#define QMTL_SLOT_FREE		0
#define QMTL_SLOT_OPEN		1

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
	volatile uint64_t completed;	/* last serial finished */
	volatile uint32_t host_generation;	/* generation the host serves */
	volatile uint32_t host_version;
	volatile uint64_t host_heartbeat;
};

/* ring records: 8-byte aligned, never split across the ring end */
struct qmtl_cmd {
	uint32_t op;
	uint32_t size;			/* whole record incl. this header */
};

enum {
	QMTL_OP_PAD = 0,		/* skip to the ring end */
	QMTL_OP_HELLO = 1,		/* { int32 pid; } */
	QMTL_OP_SYNC = 2,		/* { uint64 serial; } -> completed = serial */
};

struct qmtl_hello {
	struct qmtl_cmd hdr;
	int32_t pid;
	uint32_t pad;
};

struct qmtl_sync {
	struct qmtl_cmd hdr;
	uint64_t serial;
};

#endif /* QMTL_H */
