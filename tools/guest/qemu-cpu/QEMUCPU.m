/*
 * libQEMUCPU.dylib: CPU fallbacks for the guest's GPU-only code paths.
 *
 * The QEMU guest has no GPU (no Metal device). iOS 18 frameworks often have a
 * CPU implementation but only pick it on special conditions; this library,
 * inserted into every process by the SWEET kernel (patches-15.6/0115: exec
 * adds DYLD_INSERT_LIBRARIES=/usr/lib/qemu/libQEMUCPU.dylib), makes them pick
 * it whenever there is no Metal device. Each shim is installed only when its
 * framework is loaded (_dyld_register_func_for_add_image), so processes that
 * never use a framework are not touched. Not objc_addLoadImageFunc: iOS 18's
 * libobjc calls it with runtimeLock held (and also for shared-cache images
 * the process never loaded), so the shim's objc_getClass aborted in
 * os_unfair_lock_recursive_abort (/sbin/mount, the first process, killed the
 * boot).
 *
 * Shims:
 *   CoreImage  -[CIContext initWithOptions:] uses Metal, else OpenGL ES, else
 *              fails ("No supported back-end renderer is usable"); its CPU
 *              renderer (CI::SWContext, +[CIContext internalSWContextWithOptions:])
 *              is only for widget extensions and two macOS processes. Without
 *              a Metal device the shim builds the software context instead
 *              (iconservicesagent's SF Symbol icons: Settings rows).
 *
 * Log: /private/var/tmp/QEMUCPU.log only (one line per shim and process).
 * No os_log: the first os_log of a process registers with logd and waits for
 * the reply; logd runs this constructor too, so it waited on itself and
 * every process behind it (boot stalled at 0.6 s).
 * Built and installed by tools/cpu-shims.py.
 */
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <fcntl.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static void qlog(const char *fmt, ...)
{
	char msg[512];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(msg, sizeof(msg), fmt, ap);
	va_end(ap);
	int fd = open("/private/var/tmp/QEMUCPU.log", O_WRONLY | O_APPEND | O_CREAT, 0666);
	if (fd >= 0) {
		dprintf(fd, "%s[%d] %s\n", getprogname(), getpid(), msg);
		close(fd);
	}
}

/* Does this process get a Metal device? Asked once, after Metal is loaded. */
static bool have_metal(void)
{
	static int known = -1;
	if (known < 0) {
		id (*create)(void) = (id (*)(void))dlsym(RTLD_DEFAULT, "MTLCreateSystemDefaultDevice");
		id dev = create ? create() : nil;
		known = dev != nil;
		if (dev) {
			((void (*)(id, SEL))objc_msgSend)(dev, sel_registerName("release"));
		}
	}
	return known;
}

/* CoreImage */

static IMP ci_init_orig;

static id ci_init(id self, SEL cmd, id options)
{
	if (!have_metal()) {
		Class cls = objc_getClass("CIContext");
		void *internal = ((void *(*)(id, SEL, id))objc_msgSend)((id)cls,
		    sel_registerName("internalSWContextWithOptions:"), options);
		if (internal) {
			static bool logged;
			if (!logged) {
				logged = true;
				qlog("CoreImage: no Metal device, CIContext uses the software renderer");
			}
			id ctx = ((id (*)(id, SEL, void *))objc_msgSend)(self,
			    sel_registerName("_initWithInternalRepresentation:"), internal);
			/* the original drops its reference the same way (CI::Object::unref) */
			void (*unref)(void *) = (void (*)(void *))dlsym(RTLD_DEFAULT, "_ZNK2CI6Object5unrefEv");
			if (unref) {
				unref(internal);
			}
			return ctx;
		}
	}
	return ((id (*)(id, SEL, id))ci_init_orig)(self, cmd, options);
}

static void shim_coreimage(void)
{
	Method m = class_getInstanceMethod(objc_getClass("CIContext"), sel_registerName("initWithOptions:"));
	if (!m || !class_getClassMethod(objc_getClass("CIContext"), sel_registerName("internalSWContextWithOptions:"))) {
		qlog("CoreImage: CIContext methods not found, no shim");
		return;
	}
	ci_init_orig = method_setImplementation(m, (IMP)ci_init);
}

/* framework image -> its shim */

static const struct {
	const char *path;
	void (*install)(void);
} shims[] = {
	{ "/System/Library/Frameworks/CoreImage.framework/CoreImage", shim_coreimage },
};
static bool shim_done[sizeof(shims) / sizeof(shims[0])];

static void image_loaded(const struct mach_header *mh, __unused intptr_t slide)
{
	Dl_info info;
	if (!dladdr(mh, &info) || !info.dli_fname) {
		return;
	}
	for (size_t i = 0; i < sizeof(shims) / sizeof(shims[0]); i++) {
		if (!shim_done[i] && strcmp(info.dli_fname, shims[i].path) == 0) {
			shim_done[i] = true;
			qlog("%s loaded, installing its shim", shims[i].path);
			shims[i].install();
		}
	}
}

__attribute__((constructor)) static void qemucpu_init(void)
{
	/* bring-up: shows which processes get the library at all */
	qlog("loaded");
	_dyld_register_func_for_add_image(image_loaded);
}
