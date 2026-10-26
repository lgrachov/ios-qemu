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
 * Diagnostics:
 *   PosterBoard  +[PBFPosterExtensionDataStoreMigrator migrateDataStoreAtBaseURL:...]
 *              fails 59 -> 61 without saying why (black wallpaper on iOS 18):
 *              log its arguments, result and error, every NSError created
 *              while it runs (with the calling frames), the migrator's
 *              class methods and the store viability check's per-directory
 *              -[NSURL pbf_URLIsReachableAndConformToResourceValues:error:].
 *              Found: the check wants NSURLFileProtectionKey = None and our
 *              HFS volume has no data protection (no value at all), so every
 *              store was "not viable". EXPERIMENT (not diagnostic): a
 *              directory without a protection class passes as None; the
 *              store then migrates to 61. Proper fix: report class D from
 *              the kernel.
 *
 * Log: /private/var/tmp/QEMUCPU.log only (one line per shim and process).
 * No os_log: the first os_log of a process registers with logd and waits for
 * the reply; logd runs this constructor too, so it waited on itself and
 * every process behind it (boot stalled at 0.6 s).
 * Built and installed by tools/cpu-shims.py.
 */
#include <dlfcn.h>
#include <execinfo.h>
#include <mach-o/dyld.h>
#include <fcntl.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
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
		fchmod(fd, 0666);	/* root creates it first; mobile processes append too */
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

/* PosterBoard data store migration (diagnostic) */

static IMP pb_migrate_orig, pb_error_init_orig, pb_conform_orig;
static int pb_migrating;

static const char *objc_desc(id obj)
{
	if (!obj) {
		return "(nil)";
	}
	id desc = ((id (*)(id, SEL))objc_msgSend)(obj, sel_registerName("description"));
	const char *c = desc ? ((const char *(*)(id, SEL))objc_msgSend)(desc, sel_registerName("UTF8String")) : NULL;
	return c ? c : "?";
}

static void log_callers(const char *what)
{
	void *frames[8];
	int n = backtrace(frames, 8);
	for (int i = 2; i < n; i++) {
		Dl_info info;
		if (dladdr(frames[i], &info) && info.dli_sname) {
			const char *image = info.dli_fname ? strrchr(info.dli_fname, '/') : NULL;
			qlog("  %s caller %d: %s %s+%#lx", what, i - 2, image ? image + 1 : "?",
			    info.dli_sname, (unsigned long)((char *)frames[i] - (char *)info.dli_saddr));
		} else {
			qlog("  %s caller %d: %p", what, i - 2, frames[i]);
		}
	}
}

static id pb_error_init(id self, SEL cmd, id domain, long code, id user_info)
{
	id err = ((id (*)(id, SEL, id, long, id))pb_error_init_orig)(self, cmd, domain, code, user_info);
	if (pb_migrating) {
		qlog("NSError %s %ld: %s", objc_desc(domain), code, objc_desc(user_info));
		log_callers("NSError");
	}
	return err;
}

/* the store viability check's per-directory test */
static BOOL pb_conform(id self, SEL cmd, id values, id *error)
{
	BOOL ok = ((BOOL (*)(id, SEL, id, id *))pb_conform_orig)(self, cmd, values, error);
	/* EXPERIMENT: our HFS has no data protection, so NSURLFileProtectionKey
	 * has no value at all; treat that as NSURLFileProtectionNone */
	id key = (__bridge id)dlsym(RTLD_DEFAULT, "NSURLFileProtectionKey") ? *(id *)dlsym(RTLD_DEFAULT, "NSURLFileProtectionKey") : nil;
	if (!ok && key) {
		id prot = nil;
		((BOOL (*)(id, SEL, id *, id, id *))objc_msgSend)(self, sel_registerName("getResourceValue:forKey:error:"), &prot, key, NULL);
		if (!prot) {
			id rest = ((id (*)(id, SEL))objc_msgSend)(values, sel_registerName("mutableCopy"));
			((void (*)(id, SEL, id))objc_msgSend)(rest, sel_registerName("removeObjectForKey:"), key);
			ok = ((BOOL (*)(id, SEL, id, id *))pb_conform_orig)(self, cmd, rest, error);
			qlog("conform %s: no protection class, without that key -> %d", objc_desc(self), ok);
		}
	}
	qlog("conform %s -> %d (wants %s)", objc_desc(self), ok, objc_desc(values));
	if (!ok) {
		id keys = ((id (*)(id, SEL))objc_msgSend)(values, sel_registerName("allKeys"));
		id actual = ((id (*)(id, SEL, id, id *))objc_msgSend)(self,
		    sel_registerName("resourceValuesForKeys:error:"), keys, NULL);
		qlog("  has %s", objc_desc(actual));
	}
	return ok;
}

static BOOL pb_migrate(id self, SEL cmd, id base, unsigned long from, unsigned long to, BOOL cleanup, id *error)
{
	qlog("migrate %lu -> %lu cleanup %d (%s)", from, to, cleanup, objc_desc(base));
	pb_migrating++;
	BOOL ok = ((BOOL (*)(id, SEL, id, unsigned long, unsigned long, BOOL, id *))pb_migrate_orig)(self, cmd,
	    base, from, to, cleanup, error);
	pb_migrating--;
	qlog("migrate %lu -> %lu returned %d, error %s", from, to, ok, error ? objc_desc(*error) : "(no out-param)");
	return ok;
}

static void shim_posterboard(void)
{
	if (strcmp(getprogname(), "PosterBoard") != 0) {
		return;
	}
	Class migrator = objc_getClass("PBFPosterExtensionDataStoreMigrator");
	Method m = migrator ? class_getClassMethod(migrator,
	    sel_registerName("migrateDataStoreAtBaseURL:fromVersion:toVersion:cleanupAfterMigrationSucceeds:error:")) : NULL;
	Method e = class_getInstanceMethod(objc_getClass("NSError"), sel_registerName("initWithDomain:code:userInfo:"));
	Method c = class_getInstanceMethod(objc_getClass("NSURL"), sel_registerName("pbf_URLIsReachableAndConformToResourceValues:error:"));
	if (!m || !e || !c) {
		qlog("PosterBoard: migrator %p method %p NSError init %p conform %p, no trace", migrator, m, e, c);
		return;
	}
	unsigned int count = 0;
	Method *methods = class_copyMethodList(object_getClass(migrator), &count);
	for (unsigned int i = 0; i < count; i++) {
		qlog("PosterBoard: migrator +%s", sel_getName(method_getName(methods[i])));
	}
	free(methods);
	pb_error_init_orig = method_setImplementation(e, (IMP)pb_error_init);
	pb_migrate_orig = method_setImplementation(m, (IMP)pb_migrate);
	pb_conform_orig = method_setImplementation(c, (IMP)pb_conform);
}

/* framework image -> its shim */

static const struct {
	const char *path;
	void (*install)(void);
} shims[] = {
	{ "/System/Library/Frameworks/CoreImage.framework/CoreImage", shim_coreimage },
	{ "/System/Library/PrivateFrameworks/PosterBoard.framework/PosterBoard", shim_posterboard },
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
