/*
 * QEMUMetal.bundle: a Metal device for the iOS guest that runs its work on
 * the host's GPU (Metal API remoting).
 *
 * Kernel patch 0103/0104 (boot-arg sweetmetal=1) publishes an
 * IOAcceleratorES service with MetalPluginName = QEMUMetal and
 * MetalPluginClassName = QEMUMTLDevice. iOS 16 Metal (MTLRegisterDevices)
 * then loads /System/Library/Extensions/QEMUMetal.bundle and calls
 * [[QEMUMTLDevice alloc] initWithAcceleratorPort:service]; the class must
 * be a subclass of _MTLDevice, and MTLAddDevice asserts that it conforms to
 * the MTLDevice and MTLDeviceSPI protocols (added at load time, so the
 * compiler does not demand every method).
 *
 * The device opens the service's user client, whose selector 0 maps this
 * process's slot of the shared region (qmtl.h), and records every Metal
 * call into the slot's command ring; tools/host/qemu-metal-host.m replays
 * them on the host. This file has the transport, the slot heap, the
 * completion thread and the device; QMTLObjects.m the other Metal objects.
 *
 * Every Metal method we do not implement is logged once per process and
 * returns nil/0. Log: /private/var/tmp/QEMUMetal.log and os_log.
 */
#import <objc/runtime.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <os/log.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <IOKit/IOKitLib.h>
#import "qmtl_guest.h"

id qmtl_device;

static const char *proc_name(void)
{
	static char name[64];
	if (!name[0]) {
		const char *p = getprogname();
		snprintf(name, sizeof(name), "%s[%d]", p ? p : "?", getpid());
	}
	return name;
}

void qlog(const char *fmt, ...)
{
	char msg[768];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(msg, sizeof(msg), fmt, ap);
	va_end(ap);
	os_log(OS_LOG_DEFAULT, "QEMUMetal: %{public}s %{public}s", proc_name(), msg);
	int fd = open("/private/var/tmp/QEMUMetal.log", O_WRONLY | O_APPEND | O_CREAT, 0666);
	if (fd >= 0) {
		dprintf(fd, "%s %s\n", proc_name(), msg);
		close(fd);
	}
}

void qmtl_log_selector(const char *kind, id obj, SEL sel)
{
	qmtl_log_once([NSString stringWithFormat:@"%s %s %@", kind, object_getClassName(obj), NSStringFromSelector(sel)]);
}

void qmtl_log_once(NSString *key)
{
	static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
	static NSMutableSet<NSString *> *seen;
	pthread_mutex_lock(&lock);
	if (!seen) {
		seen = [NSMutableSet new];
	}
	BOOL first = ![seen containsObject:key];
	if (first) {
		[seen addObject:key];
	}
	pthread_mutex_unlock(&lock);
	if (first) {
		qlog("%s", key.UTF8String);
	}
}

static const char *protocol_types(Protocol *p, SEL sel)
{
	for (int req = 1; req >= 0; req--) {
		struct objc_method_description d = protocol_getMethodDescription(p, sel, req, YES);
		if (d.types) {
			return d.types;
		}
	}
	unsigned n = 0;
	Protocol * __unsafe_unretained *inherited = protocol_copyProtocolList(p, &n);
	const char *types = NULL;
	for (unsigned i = 0; i < n && !types; i++) {
		types = protocol_types(inherited[i], sel);
	}
	free(inherited);
	return types;
}

NSMethodSignature *qmtl_signature(Class cls, SEL sel)
{
	for (Class c = cls; c; c = class_getSuperclass(c)) {
		unsigned n = 0;
		Protocol * __unsafe_unretained *list = class_copyProtocolList(c, &n);
		const char *types = NULL;
		for (unsigned i = 0; i < n && !types; i++) {
			types = protocol_types(list[i], sel);
		}
		free(list);
		if (types) {
			return [NSMethodSignature signatureWithObjCTypes:types];
		}
	}
	return [NSMethodSignature signatureWithObjCTypes:"@@:"];
}

void qmtl_adopt(Class cls, const char *const *protocols)
{
	for (; *protocols; protocols++) {
		Protocol *p = objc_getProtocol(*protocols);
		if (p) {
			class_addProtocol(cls, p);
		}
	}
}

/* ---- transport: this process's slot (one device per process) ---- */

static struct qmtl_slot *slot;
static uint8_t *ring;
static io_connect_t conn;
static uint64_t sync_serial;
static uint32_t last_id;
static pthread_mutex_t ring_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t call_lock = PTHREAD_MUTEX_INITIALIZER;

static uint64_t now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

uint32_t qmtl_new_id(void)
{
	return __atomic_add_fetch(&last_id, 1, __ATOMIC_RELAXED);
}

static bool wait_tail(uint64_t need_free, uint64_t head)
{
	for (uint64_t start = now_ms(); ; usleep(50)) {
		uint64_t tail = __atomic_load_n(&slot->tail, __ATOMIC_ACQUIRE);
		if (QMTL_RING_SIZE - (head - tail) >= need_free) {
			return true;
		}
		if (now_ms() - start > 5000) {
			qlog("ring full for 5 s (head %llu tail %llu): host not running?", head, tail);
			return false;
		}
	}
}

/* ring_lock held */
static bool ring_put(const void *rec, uint32_t size)
{
	uint64_t head = slot->head;
	uint64_t off = head % QMTL_RING_SIZE;
	if (QMTL_RING_SIZE - off < size) {
		if (!wait_tail(QMTL_RING_SIZE - off, head)) {
			return false;
		}
		struct qmtl_cmd pad = { QMTL_OP_PAD, (uint32_t)(QMTL_RING_SIZE - off) };
		memcpy(ring + off, &pad, sizeof(pad));
		head += QMTL_RING_SIZE - off;
		off = 0;
	}
	if (!wait_tail(size, head)) {
		return false;
	}
	memcpy(ring + off, rec, size);
	__atomic_store_n(&slot->head, head + size, __ATOMIC_RELEASE);
	return true;
}

bool qmtl_send(const void *rec, uint32_t size)
{
	if (slot == NULL || size > QMTL_RING_SIZE / 2 || (size & 7)) {
		return false;
	}
	pthread_mutex_lock(&ring_lock);
	bool ok = ring_put(rec, size);
	pthread_mutex_unlock(&ring_lock);
	return ok;
}

/* Wait until the host has run everything sent so far. */
static bool qmtl_sync(uint64_t timeout_ms)
{
	pthread_mutex_lock(&ring_lock);
	struct qmtl_sync c = { { QMTL_OP_SYNC, sizeof(c) }, ++sync_serial };
	bool ok = slot != NULL && ring_put(&c, sizeof(c));
	pthread_mutex_unlock(&ring_lock);
	for (uint64_t start = now_ms(); ok; usleep(30)) {
		if (__atomic_load_n(&slot->completed, __ATOMIC_ACQUIRE) >= c.serial) {
			return true;
		}
		if (now_ms() - start > timeout_ms) {
			qlog("host did not answer sync %llu in %llu ms", c.serial, timeout_ms);
			return false;
		}
	}
	return false;
}

bool qmtl_call(const void *rec, uint32_t size, NSData **reply)
{
	pthread_mutex_lock(&call_lock);
	slot->reply_status = -1;
	slot->reply_len = 0;
	bool ok = qmtl_send(rec, size) && qmtl_sync(30000);
	ok = ok && slot->reply_status == 0;
	if (reply != NULL) {
		uint32_t len = MIN(slot->reply_len, (uint32_t)QMTL_REPLY_SIZE);
		*reply = [NSData dataWithBytes:(const void *)slot->reply length:len];
	}
	pthread_mutex_unlock(&call_lock);
	return ok;
}

NSError *qmtl_error(NSString *what, NSData *reply)
{
	NSString *text = [[NSString alloc] initWithData:reply ?: [NSData data] encoding:NSUTF8StringEncoding];
	qlog("%s failed: %s", what.UTF8String, text.UTF8String);
	return [NSError errorWithDomain:@"QEMUMetal" code:1
	    userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %@", what, text ?: @"?"] }];
}

/* ---- slot heap: first fit over 256-byte units, sizes in a header unit ---- */

#define HEAP_UNIT 256
#define MAX_FREE 4096

struct span { uint64_t off, len; };
struct deferred { int64_t off; uint64_t ring_pos, cb_serial; };

static pthread_mutex_t heap_lock = PTHREAD_MUTEX_INITIALIZER;
static struct span free_spans[MAX_FREE];
static int nfree;
static struct deferred *deferred;
static int ndeferred, cap_deferred;
static uint64_t last_committed_cb;

static void heap_init(void)
{
	free_spans[0].off = QMTL_HEAP_OFFSET;
	free_spans[0].len = QMTL_SLOT_SIZE - QMTL_HEAP_OFFSET;
	nfree = 1;
}

/* heap_lock held */
static void heap_release(uint64_t off, uint64_t len)
{
	int i = 0;
	while (i < nfree && free_spans[i].off < off) {
		i++;
	}
	bool merge_prev = i > 0 && free_spans[i - 1].off + free_spans[i - 1].len == off;
	bool merge_next = i < nfree && off + len == free_spans[i].off;
	if (merge_prev && merge_next) {
		free_spans[i - 1].len += len + free_spans[i].len;
		memmove(&free_spans[i], &free_spans[i + 1], (nfree - i - 1) * sizeof(free_spans[0]));
		nfree--;
	} else if (merge_prev) {
		free_spans[i - 1].len += len;
	} else if (merge_next) {
		free_spans[i].off = off;
		free_spans[i].len += len;
	} else if (nfree < MAX_FREE) {
		memmove(&free_spans[i + 1], &free_spans[i], (nfree - i) * sizeof(free_spans[0]));
		free_spans[i].off = off;
		free_spans[i].len = len;
		nfree++;
	} else {
		qlog("heap: free list full, leaking %llu bytes", len);
	}
}

/* heap_lock held */
static void heap_reap(void)
{
	uint64_t tail = __atomic_load_n(&slot->tail, __ATOMIC_ACQUIRE);
	int keep = 0;
	for (int i = 0; i < ndeferred; i++) {
		struct deferred d = deferred[i];
		if (tail >= d.ring_pos && (d.cb_serial == 0 || qmtl_cb_done(d.cb_serial, NULL))) {
			uint64_t start = (uint64_t)d.off - HEAP_UNIT;
			heap_release(start, *(uint64_t *)((uint8_t *)slot + start));
		} else {
			deferred[keep++] = d;
		}
	}
	ndeferred = keep;
}

int64_t qmtl_heap_alloc(uint64_t size)
{
	uint64_t len = (size + HEAP_UNIT - 1) / HEAP_UNIT * HEAP_UNIT + HEAP_UNIT;
	/* waiting here stalls the caller (the render server): give up soon */
	for (int attempt = 0; attempt < 40; attempt++) {
		pthread_mutex_lock(&heap_lock);
		heap_reap();
		for (int i = 0; i < nfree; i++) {
			if (free_spans[i].len >= len) {
				uint64_t start = free_spans[i].off;
				free_spans[i].off += len;
				free_spans[i].len -= len;
				if (free_spans[i].len == 0) {
					memmove(&free_spans[i], &free_spans[i + 1], (nfree - i - 1) * sizeof(free_spans[0]));
					nfree--;
				}
				pthread_mutex_unlock(&heap_lock);
				*(uint64_t *)((uint8_t *)slot + start) = len;
				return (int64_t)(start + HEAP_UNIT);
			}
		}
		bool waiting = ndeferred > 0;
		pthread_mutex_unlock(&heap_lock);
		if (!waiting) {
			break;
		}
		usleep(500);	/* deferred frees pending: wait for the host */
	}
	qlog("heap: no room for %llu bytes", size);
	return -1;
}

void *qmtl_heap_ptr(uint64_t off)
{
	return (uint8_t *)slot + off;
}

void qmtl_heap_free_later(int64_t off)
{
	if (off < 0 || slot == NULL) {
		return;
	}
	pthread_mutex_lock(&heap_lock);
	if (ndeferred == cap_deferred) {
		cap_deferred = cap_deferred ? cap_deferred * 2 : 256;
		deferred = realloc(deferred, cap_deferred * sizeof(*deferred));
	}
	deferred[ndeferred++] = (struct deferred){ off, __atomic_load_n(&slot->head, __ATOMIC_ACQUIRE),
		__atomic_load_n(&last_committed_cb, __ATOMIC_ACQUIRE) };
	pthread_mutex_unlock(&heap_lock);
}

/* ---- command buffer completion ---- */

static uint64_t last_cb_serial;
static pthread_mutex_t done_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t done_cond = PTHREAD_COND_INITIALIZER;
static NSMutableArray *waiters;	/* @[serial, block] */

uint64_t qmtl_cb_next_serial(void)
{
	return __atomic_add_fetch(&last_cb_serial, 1, __ATOMIC_RELAXED);
}

void qmtl_cb_committed(uint64_t serial)
{
	uint64_t cur = __atomic_load_n(&last_committed_cb, __ATOMIC_RELAXED);
	while (serial > cur && !__atomic_compare_exchange_n(&last_committed_cb, &cur, serial, false,
	    __ATOMIC_RELEASE, __ATOMIC_RELAXED)) {
	}
}

bool qmtl_cb_done(uint64_t serial, uint32_t *error)
{
	uint64_t v = __atomic_load_n(&slot->cb_done[serial % QMTL_CB_WINDOW], __ATOMIC_ACQUIRE);
	if (v >= serial && error != NULL) {
		*error = slot->cb_error[serial % QMTL_CB_WINDOW];
	}
	return v >= serial;
}

void qmtl_cb_wait(uint64_t serial)
{
	for (uint64_t start = now_ms(), warned = 0; !qmtl_cb_done(serial, NULL); usleep(50)) {
		if (!warned && now_ms() - start > 5000) {
			qlog("command buffer %llu not done after 5 s", serial);
			warned = 1;
		}
	}
}

void qmtl_cb_notify(uint64_t serial, void (^block)(uint32_t error))
{
	pthread_mutex_lock(&done_lock);
	[waiters addObject:@[ @(serial), [block copy] ]];
	pthread_cond_signal(&done_cond);
	pthread_mutex_unlock(&done_lock);
}

static void *completion_thread(void *arg)
{
	(void)arg;
	pthread_setname_np("cx.lev.ios-qemu.metal.completion");
	for (;;) {
		NSMutableArray *ready = [NSMutableArray array];
		pthread_mutex_lock(&done_lock);
		while (waiters.count == 0) {
			pthread_cond_wait(&done_cond, &done_lock);
		}
		for (NSUInteger i = 0; i < waiters.count;) {
			NSArray *w = waiters[i];
			if (qmtl_cb_done([w[0] unsignedLongLongValue], NULL)) {
				[ready addObject:w];
				[waiters removeObjectAtIndex:i];
			} else {
				i++;
			}
		}
		pthread_mutex_unlock(&done_lock);
		for (NSArray *w in ready) {
			@autoreleasepool {
				uint32_t error = 0;
				qmtl_cb_done([w[0] unsignedLongLongValue], &error);
				((void (^)(uint32_t))w[1])(error);
			}
		}
		if (ready.count == 0) {
			usleep(100);
		}
	}
	return NULL;
}

/* ---- MTLFunctionConstantValues: record what the setters were given ---- */

static const void *constants_key = &constants_key;

static uint32_t data_type_size(MTLDataType t)
{
	struct { MTLDataType first; int n; uint32_t elem; } kinds[] = {
		{ MTLDataTypeFloat, 4, 4 }, { MTLDataTypeHalf, 4, 2 }, { MTLDataTypeInt, 4, 4 },
		{ MTLDataTypeUInt, 4, 4 }, { MTLDataTypeShort, 4, 2 }, { MTLDataTypeUShort, 4, 2 },
		{ MTLDataTypeChar, 4, 1 }, { MTLDataTypeUChar, 4, 1 }, { MTLDataTypeBool, 4, 1 },
		{ MTLDataTypeLong, 4, 8 }, { MTLDataTypeULong, 4, 8 },
	};
	for (size_t i = 0; i < sizeof(kinds) / sizeof(kinds[0]); i++) {
		if (t >= kinds[i].first && t < kinds[i].first + kinds[i].n) {
			uint32_t n = (uint32_t)(t - kinds[i].first) + 1;
			return MIN(16u, kinds[i].elem * (n == 3 ? 4 : n));
		}
	}
	return 4;
}

static void record_constant(id values, const void *value, MTLDataType type, uint32_t index, NSString *name)
{
	struct qmtl_constant c = { index, (uint32_t)type };
	memcpy(c.value, value, data_type_size(type));
	if (name) {
		strlcpy(c.name, name.UTF8String, sizeof(c.name));
	}
	@synchronized (values) {
		NSMutableArray *list = objc_getAssociatedObject(values, constants_key);
		if (!list) {
			list = [NSMutableArray array];
			objc_setAssociatedObject(values, constants_key, list, OBJC_ASSOCIATION_RETAIN);
		}
		[list addObject:[NSData dataWithBytes:&c length:sizeof(c)]];
	}
}

NSArray<NSData *> *qmtl_constants_of(MTLFunctionConstantValues *values)
{
	if (!values) {
		return @[];
	}
	@synchronized (values) {
		return [objc_getAssociatedObject(values, constants_key) copy] ?: @[];
	}
}

static void hook_constant_values(void)
{
	/* iOS: +alloc returns the private MTLFunctionConstantValuesInternal,
	   which has its own setters */
	Class cls = [[MTLFunctionConstantValues new] class];
	SEL s1 = @selector(setConstantValue:type:atIndex:);
	SEL s2 = @selector(setConstantValues:type:withRange:);
	SEL s3 = @selector(setConstantValue:type:withName:);
	Method m1 = class_getInstanceMethod(cls, s1), m2 = class_getInstanceMethod(cls, s2), m3 = class_getInstanceMethod(cls, s3);
	if (!m1 || !m2 || !m3) {
		qlog("MTLFunctionConstantValues setters not found");
		return;
	}
	void (*o1)(id, SEL, const void *, MTLDataType, NSUInteger) = (void *)method_getImplementation(m1);
	void (*o2)(id, SEL, const void *, MTLDataType, NSRange) = (void *)method_getImplementation(m2);
	void (*o3)(id, SEL, const void *, MTLDataType, NSString *) = (void *)method_getImplementation(m3);
	method_setImplementation(m1, imp_implementationWithBlock(^(id self, const void *v, MTLDataType t, NSUInteger i) {
		record_constant(self, v, t, (uint32_t)i, nil);
		o1(self, s1, v, t, i);
	}));
	method_setImplementation(m2, imp_implementationWithBlock(^(id self, const void *v, MTLDataType t, NSRange r) {
		uint32_t sz = data_type_size(t);
		for (NSUInteger k = 0; k < r.length; k++) {
			record_constant(self, (const uint8_t *)v + k * sz, t, (uint32_t)(r.location + k), nil);
		}
		o2(self, s2, v, t, r);
	}));
	method_setImplementation(m3, imp_implementationWithBlock(^(id self, const void *v, MTLDataType t, NSString *n) {
		record_constant(self, v, t, ~0u, n);
		o3(self, s3, v, t, n);
	}));
	/* descriptors copy their constantValues: carry the record over */
	SEL s4 = @selector(copyWithZone:), s5 = @selector(reset);
	Method m4 = class_getInstanceMethod(cls, s4), m5 = class_getInstanceMethod(cls, s5);
	id (*o4)(id, SEL, NSZone *) = (void *)method_getImplementation(m4);
	void (*o5)(id, SEL) = (void *)method_getImplementation(m5);
	method_setImplementation(m4, imp_implementationWithBlock(^id(id self, NSZone *zone) {
		id copy = o4(self, s4, zone);
		NSArray *list = qmtl_constants_of(self);
		if (copy && list.count) {
			objc_setAssociatedObject(copy, constants_key, [list mutableCopy], OBJC_ASSOCIATION_RETAIN);
		}
		return copy;
	}));
	if (m5) {
		method_setImplementation(m5, imp_implementationWithBlock(^(id self) {
			@synchronized (self) {
				objc_setAssociatedObject(self, constants_key, nil, OBJC_ASSOCIATION_RETAIN);
			}
			o5(self, s5);
		}));
	}
}

void qmtl_note_commit(uint64_t wait_us)
{
	static uint64_t n, total, worst, since;
	static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
	pthread_mutex_lock(&lock);
	n++;
	total += wait_us;
	worst = MAX(worst, wait_us);
	uint64_t now = now_ms();
	if (since == 0) {
		since = now;
	}
	if (now - since >= 5000) {
		qlog("commits: %llu in %llu ms, wait for the GPU avg %llu us, max %llu us", n, now - since, total / n, worst);
		n = total = worst = 0;
		since = now;
	}
	pthread_mutex_unlock(&lock);
}

bool qmtl_surface_pool(IOSurfaceRef surface, NSUInteger plane, uint64_t *offset, uint64_t *bpr)
{
	if (conn == MACH_PORT_NULL) {
		return false;
	}
	uint64_t in = IOSurfaceGetID(surface), out[4] = { 0 };
	uint32_t n = 4;
	if (IOConnectCallScalarMethod(conn, 1, &in, 1, out, &n) != KERN_SUCCESS || out[0] == 0) {
		return false;
	}
	uint8_t *base = IOSurfaceGetBaseAddress(surface), *pixels = IOSurfaceGetBaseAddressOfPlane(surface, plane);
	uint64_t pa = out[0] + out[3] + (uint64_t)(pixels - base);
	*bpr = IOSurfaceGetBytesPerRowOfPlane(surface, plane);
	/* what Metal's linear textures on the host accept */
	if (pa < QMTL_POOL_PA || pa % 256 || *bpr % 64) {
		return false;
	}
	*offset = pa - QMTL_POOL_PA;
	return true;
}

/* ---- attach ---- */

#ifdef QMTL_HOST_TEST
/* tools/host/qmtl-selftest.m: this code on macOS against a file the host
   helper maps too; does what the kernel's attach does for slot 0 */
#include <sys/mman.h>
static bool attach_test(void)
{
	const char *path = getenv("QMTL_TEST_FILE");
	int fd = path ? open(path, O_RDWR) : -1;
	void *p = fd >= 0 ? mmap(NULL, QMTL_SLOT_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, QMTL_PA - QMTL_RAM_BASE) : MAP_FAILED;
	if (p == MAP_FAILED) {
		qlog("QMTL_TEST_FILE: cannot map");
		return false;
	}
	slot = p;
	ring = (uint8_t *)slot + QMTL_HEADER_SIZE;
	slot->head = slot->submitted = slot->tail = slot->completed = 0;
	slot->pid = getpid();
	strlcpy(slot->name, "selftest", sizeof(slot->name));
	slot->magic = QMTL_MAGIC;
	slot->version = QMTL_VERSION;
	slot->generation++;
	__atomic_store_n(&slot->state, QMTL_SLOT_OPEN, __ATOMIC_RELEASE);
	for (int i = 0; i < 200 && slot->host_generation != slot->generation; i++) {
		usleep(10000);
	}
	return true;
}
#endif

/* the kernel's IOAcceleratorES user client maps this process's slot */
static bool attach_kernel(mach_port_t service)
{
	kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &conn);
	if (kr != KERN_SUCCESS) {
		qlog("IOServiceOpen: 0x%x", kr);
		return false;
	}
	uint64_t out[4] = { 0 };
	uint32_t n = 4;
	kr = IOConnectCallScalarMethod(conn, 0, NULL, 0, out, &n);
	if (kr != KERN_SUCCESS) {
		qlog("attach: 0x%x", kr);
		IOServiceClose(conn);
		conn = MACH_PORT_NULL;
		return false;
	}
	/* conn stays open for the life of the process: closing frees the slot */
	slot = (struct qmtl_slot *)(uintptr_t)out[1];
	ring = (uint8_t *)slot + QMTL_HEADER_SIZE;
	qlog("slot %llu at %p (%llu MiB, generation %llu)", out[0], slot, out[2] >> 20, out[3]);
	return true;
}

static bool attach(mach_port_t service)
{
#ifdef QMTL_HOST_TEST
	bool ok = attach_test();
#else
	bool ok = attach_kernel(service);
#endif
	if (!ok) {
		return false;
	}
	memset((void *)slot->cb_done, 0, sizeof(slot->cb_done));
	memset((void *)slot->cb_error, 0, sizeof(slot->cb_error));
	heap_init();

	/* how fast is the shared memory for the CPU (cached or not)? */
	{
		size_t n = 8 << 20;
		void *plain = malloc(n);
		uint8_t *shared = (uint8_t *)slot + QMTL_HEAP_OFFSET;
		struct timespec a, b, c;
		memset(plain, 1, n);
		clock_gettime(CLOCK_MONOTONIC, &a);
		memset(plain, 2, n);
		clock_gettime(CLOCK_MONOTONIC, &b);
		memset(shared, 2, n);
		clock_gettime(CLOCK_MONOTONIC, &c);
		double t1 = (b.tv_sec - a.tv_sec) + (b.tv_nsec - a.tv_nsec) / 1e9;
		double t2 = (c.tv_sec - b.tv_sec) + (c.tv_nsec - b.tv_nsec) / 1e9;
		qlog("memset 8 MiB: ordinary memory %.0f MB/s, shared slot memory %.0f MB/s", n / t1 / 1e6, n / t2 / 1e6);
		free(plain);
	}

	uint64_t start = now_ms();
	struct qmtl_hello hello = { { QMTL_OP_HELLO, sizeof(hello) }, getpid(), 0 };
	if (qmtl_send(&hello, sizeof(hello)) && qmtl_sync(3000)) {
		qlog("host answered in %llu ms (host generation %u)", now_ms() - start, slot->host_generation);
		return true;
	}
	qlog("no answer from the host helper");
	return false;
}

__attribute__((constructor)) static void loaded(void)
{
	static const char *const protocols[] = { "MTLDevice", "MTLDeviceSPI", NULL };
	qmtl_adopt(objc_getClass("QEMUMTLDevice"), protocols);
	hook_constant_values();
	waiters = [NSMutableArray array];
	pthread_t t;
	pthread_create(&t, NULL, completion_thread, NULL);
	pthread_detach(t);
}

@implementation QEMUMTLDevice

/*
 * Processes that get the device. For now only CoreAnimation's render server:
 * other clients (SpringBoard's Metal Performance Shaders, widgets) abort on
 * a device they do not know, so they keep seeing no Metal device, as before.
 */
static bool process_allowed(void)
{
	static const char *const allowed[] = { "backboardd", "selftest", NULL };
	const char *name = getprogname();
	for (const char *const *a = allowed; *a; a++) {
		if (name && strcmp(name, *a) == 0) {
			return true;
		}
	}
	return false;
}

- (instancetype)initWithAcceleratorPort:(mach_port_t)port
{
	/* always: a rejected instance is still deallocated through _MTLDevice,
	   whose dealloc releases what -init created */
	if (!(self = [super init])) {
		return nil;
	}
	if (!process_allowed()) {
		return nil;
	}
	if (qmtl_device != nil) {
		return qmtl_device;	/* one device (and slot) per process */
	}
	if (slot == NULL && !attach(port)) {
		return nil;	/* no host: no Metal device, CoreAnimation keeps its CPU renderer */
	}
	qmtl_device = self;
	qlog("device ready");
	return self;
}

/* asked by MTLAddDevice (initLimits / initFeatureQueries); A11 values */
- (unsigned long long)featureProfile
{
	return 5;	/* -[AGXA11FamilyDevice featureProfile] */
}

- (unsigned long long)maxBufferLength
{
	return QMTL_SLOT_SIZE - QMTL_HEAP_OFFSET;
}

- (NSString *)name
{
	return @"QEMU Metal (host GPU)";
}

- (NSString *)vendorName
{
	return @"QEMU";
}

- (uint64_t)registryID
{
	return 0x51454d55;
}

- (BOOL)supportsFamily:(MTLGPUFamily)family
{
	return (family >= MTLGPUFamilyApple1 && family <= MTLGPUFamilyApple4) ||
	       family == MTLGPUFamilyCommon1 || family == MTLGPUFamilyCommon2;
}

- (BOOL)hasUnifiedMemory { return YES; }
- (BOOL)isLowPower { return NO; }
- (BOOL)isHeadless { return NO; }
- (BOOL)isRemovable { return NO; }
- (MTLSize)maxThreadsPerThreadgroup { return MTLSizeMake(1024, 1024, 1024); }
- (NSUInteger)maxThreadgroupMemoryLength { return 16384; }
- (NSUInteger)maxColorAttachments { return 8; }
- (NSUInteger)maxFragmentSamplers { return 16; }
- (NSUInteger)maxFragmentTextures { return 31; }
- (NSUInteger)maxTextureWidth2D { return 16384; }
- (NSUInteger)maxTextureHeight2D { return 16384; }
- (NSUInteger)minConstantBufferAlignmentBytes { return 16; }
- (NSUInteger)deviceLinearReadOnlyTextureAlignmentBytes { return 256; }
- (NSUInteger)iosurfaceReadOnlyTextureAlignmentBytes { return 256; }
- (NSUInteger)minimumLinearTextureAlignmentForPixelFormat:(MTLPixelFormat)format { return 256; }
- (NSUInteger)minimumTextureBufferAlignmentForPixelFormat:(MTLPixelFormat)format { return 256; }
- (BOOL)supportsMemorylessRenderTargets { return NO; }
- (BOOL)supportsTileShaders { return NO; }
- (BOOL)supportsRasterOrderGroups { return NO; }
- (BOOL)areRasterOrderGroupsSupported { return NO; }
- (BOOL)supportsSIMDGroup { return YES; }
- (BOOL)supportsNativeHardwareFP16 { return YES; }
- (BOOL)supportsExtendedXR10Formats { return NO; }
- (BOOL)supportsYCBCRFormats12 { return NO; }
- (BOOL)supportsYCBCRPackedFormats12 { return NO; }
- (BOOL)supportsTextureSampleCount:(NSUInteger)count { return count == 1 || count == 4; }
- (uint64_t)recommendedMaxWorkingSetSize { return QMTL_SLOT_SIZE; }
- (NSUInteger)currentAllocatedSize { return 0; }
- (MTLReadWriteTextureTier)readWriteTextureSupport { return MTLReadWriteTextureTier1; }
- (MTLArgumentBuffersTier)argumentBuffersSupport { return MTLArgumentBuffersTier1; }

/* _MTLDevice's abstract methods call this; do not throw */
- (void)doesNotRecognizeSelector:(SEL)sel
{
	qmtl_log_selector("abstract", self, sel);
}

/* methods _MTLDevice does not have: log and return nil/0 */
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel
{
	return [super methodSignatureForSelector:sel] ?: qmtl_signature([self class], sel);
}

- (void)forwardInvocation:(NSInvocation *)inv
{
	qmtl_log_selector("missing", self, inv.selector);
}

@end
