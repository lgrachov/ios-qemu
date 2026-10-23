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
