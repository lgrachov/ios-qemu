/*
 * QEMUMetal.bundle, step 1 of Metal API remoting: a logging-only device.
 *
 * Kernel patch 0103 (boot-arg sweetmetal=1) publishes an IOAcceleratorES
 * service with MetalPluginName = QEMUMetal and MetalPluginClassName =
 * QEMUMTLDevice. iOS 16 Metal (MTLRegisterDevices) then loads
 * /System/Library/Extensions/QEMUMetal.bundle and calls
 * [[QEMUMTLDevice alloc] initWithAcceleratorPort:service]; the class must
 * be a subclass of _MTLDevice, and MTLAddDevice asserts that it conforms to
 * the MTLDevice and MTLDeviceSPI protocols (added at load time below, so
 * the compiler does not demand every method).
 *
 * This device does no rendering. Every method that _MTLDevice leaves
 * abstract (it calls doesNotRecognizeSelector:) or does not have at all is
 * logged once per process and returns nil/0, so a boot shows which Metal
 * calls CoreAnimation and the other clients make. Log: one line per event
 * in /private/var/tmp/QEMUMetal.log (any user can append) and os_log.
 * Methods _MTLDevice answers itself never reach these hooks, so creating
 * the device also turns on libobjc's message tracer
 * (instrumentObjcMessageSends: every class/selector pair on a method-cache
 * miss, written to /tmp/msgSends-<pid>).
 *
 * Transport (milestone A): the device opens the IOAcceleratorES user
 * client (kernel patch 0104), whose selector 0 maps this process's slot of
 * the shared region, and talks to the host helper through the slot's
 * command ring (qmtl.h).
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <os/log.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <IOKit/IOKitLib.h>
#include "qmtl.h"

@interface _MTLDevice : NSObject
- (instancetype)init;
@end

@interface QEMUMTLDevice : _MTLDevice
@end

static const char *proc_name(void)
{
	static char name[64];
	if (!name[0]) {
		const char *p = getprogname();
		snprintf(name, sizeof(name), "%s[%d]", p ? p : "?", getpid());
	}
	return name;
}

static void qlog(const char *fmt, ...)
{
	char msg[512];
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

/* each selector once per process */
static void log_selector(const char *kind, SEL sel)
{
	static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
	static NSMutableSet<NSString *> *seen;
	NSString *name = NSStringFromSelector(sel);
	pthread_mutex_lock(&lock);
	if (!seen) {
		seen = [NSMutableSet new];
	}
	BOOL first = ![seen containsObject:name];
	if (first) {
		[seen addObject:name];
	}
	pthread_mutex_unlock(&lock);
	if (first) {
		qlog("%s %s", kind, name.UTF8String);
	}
}

/* ---- transport: this process's slot (one device per process) ---- */

static struct qmtl_slot *slot;
static uint8_t *ring;
static uint64_t serial;
static pthread_mutex_t ring_lock = PTHREAD_MUTEX_INITIALIZER;

static uint64_t now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
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

/* Append one record (size 8-aligned, < ring size); ring_lock held. */
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

/* Wait until the host has run everything sent so far. */
static bool qmtl_sync(uint64_t timeout_ms)
{
	pthread_mutex_lock(&ring_lock);
	struct qmtl_sync c = { { QMTL_OP_SYNC, sizeof(c) }, ++serial };
	bool ok = ring_put(&c, sizeof(c));
	pthread_mutex_unlock(&ring_lock);
	for (uint64_t start = now_ms(); ok; usleep(50)) {
		if (__atomic_load_n(&slot->completed, __ATOMIC_ACQUIRE) >= c.serial) {
			return true;
		}
		if (now_ms() - start > timeout_ms) {
			return false;
		}
	}
	return false;
}

static bool attach(mach_port_t service)
{
	io_connect_t conn = MACH_PORT_NULL;
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
		return false;
	}
	/* conn stays open for the life of the process: closing frees the slot */
	slot = (struct qmtl_slot *)(uintptr_t)out[1];
	ring = (uint8_t *)slot + QMTL_HEADER_SIZE;
	qlog("slot %llu at %p (%llu MiB, generation %llu)", out[0], slot, out[2] >> 20, out[3]);

	uint64_t start = now_ms();
	struct qmtl_hello hello = { { QMTL_OP_HELLO, sizeof(hello) }, getpid(), 0 };
	pthread_mutex_lock(&ring_lock);
	bool ok = ring_put(&hello, sizeof(hello));
	pthread_mutex_unlock(&ring_lock);
	if (ok && qmtl_sync(3000)) {
		qlog("host answered in %llu ms (host generation %u)", now_ms() - start, slot->host_generation);
		return true;
	}
	qlog("no answer from the host helper");
	return false;
}

__attribute__((constructor)) static void loaded(void)
{
	Class cls = objc_getClass("QEMUMTLDevice");
	static const char *names[] = { "MTLDevice", "MTLDeviceSPI" };
	for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
		const char *name = names[i];
		Protocol *p = objc_getProtocol(name);
		if (!p || !class_addProtocol(cls, p)) {
			qlog("protocol %s: %s", name, p ? "already there" : "not found");
		}
	}
	qlog("bundle loaded");
}

@implementation QEMUMTLDevice

- (instancetype)initWithAcceleratorPort:(mach_port_t)port
{
	self = [super init];
	qlog("initWithAcceleratorPort: port 0x%x -> %p", port, self);
	if (slot == NULL) {
		attach(port);
	}
	void (*trace)(BOOL) = (void (*)(BOOL))dlsym(RTLD_DEFAULT, "instrumentObjcMessageSends");
	if (trace) {
		trace(YES);
	}
	return self;
}

/* asked by MTLAddDevice (initLimits / initFeatureQueries); A11 values */
- (unsigned long long)featureProfile
{
	return 5;	/* -[AGXA11FamilyDevice featureProfile] */
}

- (unsigned long long)maxBufferLength
{
	return 256ULL << 20;
}

- (NSString *)name
{
	return @"QEMU Metal (logging only)";
}

/* _MTLDevice's abstract methods call this; do not throw */
- (void)doesNotRecognizeSelector:(SEL)sel
{
	log_selector("abstract", sel);
}

/* methods _MTLDevice does not have: log and return nil/0 */
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel
{
	NSMethodSignature *sig = [super methodSignatureForSelector:sel];
	return sig ? sig : [NSMethodSignature signatureWithObjCTypes:"@@:"];
}

- (void)forwardInvocation:(NSInvocation *)inv
{
	log_selector("missing", inv.selector);
}

@end
