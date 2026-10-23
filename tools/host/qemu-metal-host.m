/*
 * Host side of QEMU Metal remoting (milestone A: transport only).
 *
 *   qemu-metal-host FILE
 *
 * FILE is the file backing guest RAM that QEMU shares with this helper
 * (qemu-sweet.py --metal FILE; harness.sh --metal starts this helper); the
 * Metal region is at file offset QMTL_PA - QMTL_RAM_BASE.
 * Layout and protocol: tools/guest/qemu-metal/qmtl.h. The guest kernel
 * hands each Metal process a slot; this helper follows every open slot's
 * command ring and answers. When a slot's generation changes (process
 * attached or exited) its state is dropped.
 *
 * Built by harness.sh: clang -fobjc-arc -framework Foundation -framework Metal
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
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

struct slot_state {
	uint32_t generation;	/* generation being served, 0 = none */
	uint64_t tail;
};

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

/* Run one ring record; returns false on a malformed record. */
static bool run_cmd(int idx, struct qmtl_slot *h, const struct qmtl_cmd *cmd)
{
	switch (cmd->op) {
	case QMTL_OP_HELLO: {
		const struct qmtl_hello *c = (const void *)cmd;
		hlog("slot %d: hello from %.*s[%d]", idx, (int)sizeof(h->name), h->name, c->pid);
		return true;
	}
	case QMTL_OP_SYNC: {
		const struct qmtl_sync *c = (const void *)cmd;
		atomic_store_explicit((_Atomic uint64_t *)&h->completed, c->serial, memory_order_release);
		return true;
	}
	default:
		hlog("slot %d: unknown op %u (size %u)", idx, cmd->op, cmd->size);
		return false;
	}
}

/* Consume everything the guest has written; returns whether there was work. */
static bool serve(int idx, struct qmtl_slot *h, struct slot_state *st)
{
	uint8_t *ring = (uint8_t *)h + QMTL_HEADER_SIZE;
	uint64_t head = atomic_load_explicit((_Atomic uint64_t *)&h->head, memory_order_acquire);
	bool worked = st->tail != head;

	while (st->tail != head) {
		uint64_t off = st->tail % QMTL_RING_SIZE;
		const struct qmtl_cmd *cmd = (const void *)(ring + off);
		if (head - st->tail < sizeof(*cmd) || cmd->size < sizeof(*cmd) || (cmd->size & 7) ||
		    cmd->size > QMTL_RING_SIZE - off || cmd->size > head - st->tail) {
			hlog("slot %d: corrupt ring at %llu (op %u size %u head %llu); dropping the slot",
			    idx, st->tail, cmd->op, cmd->size, head);
			st->tail = head;
			st->generation = 0;
			break;
		}
		if (cmd->op == QMTL_OP_PAD) {
			st->tail += QMTL_RING_SIZE - off;
			continue;
		}
		if (!run_cmd(idx, h, cmd)) {
			st->tail = head;
			break;
		}
		st->tail += cmd->size;
	}
	atomic_store_explicit((_Atomic uint64_t *)&h->tail, st->tail, memory_order_release);
	return worked;
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

	@autoreleasepool {
		id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
		hlog("host GPU: %s", dev ? dev.name.UTF8String : "none");
	}
	uint8_t *shm = map_shared(argv[1]);
	if (shm == NULL) {
		if (!stop) {
			hlog("cannot map %s", argv[1]);
		}
		return 1;
	}
	hlog("mapped %s (%d slots of %llu MiB)", argv[1], QMTL_SLOTS, QMTL_SLOT_SIZE >> 20);

	struct slot_state slots[QMTL_SLOTS] = { 0 };
	uint64_t beat = 0;
	while (!stop) {
		bool worked = false;
		beat++;
		for (int i = 0; i < QMTL_SLOTS; i++) {
			struct qmtl_slot *h = (struct qmtl_slot *)(shm + i * QMTL_SLOT_SIZE);
			struct slot_state *st = &slots[i];
			uint32_t state = atomic_load_explicit((_Atomic uint32_t *)&h->state, memory_order_acquire);
			uint32_t gen = h->generation;

			if (h->magic != QMTL_MAGIC || state != QMTL_SLOT_OPEN) {
				if (st->generation != 0) {
					hlog("slot %d: closed", i);
					st->generation = 0;
				}
				continue;
			}
			if (gen != st->generation) {
				if (st->generation != 0) {
					hlog("slot %d: closed (reopened)", i);
				}
				st->generation = gen;
				st->tail = 0;
				hlog("slot %d: opened by %.*s[%d] (generation %u)", i, (int)sizeof(h->name), h->name, h->pid, gen);
				h->host_version = QMTL_VERSION;
				atomic_store_explicit((_Atomic uint32_t *)&h->host_generation, gen, memory_order_release);
			}
			h->host_heartbeat = beat;
			worked |= serve(i, h, st);
		}
		if (!worked) {
			usleep(200);
		}
	}
	hlog("stopped");
	return 0;
}
