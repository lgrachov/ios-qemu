/*
 * QEMUMetal.bundle internals: transport, slot heap and command-buffer
 * completion (QEMUMetal.m), shared by the Metal object classes
 * (QMTLObjects.m).
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <IOSurface/IOSurfaceRef.h>
#include "qmtl.h"

@interface _MTLDevice : NSObject
- (instancetype)init;
@end

/* the device; its object-creating methods are in QMTLObjects.m */
@interface QEMUMTLDevice : _MTLDevice
- (instancetype)initWithAcceleratorPort:(mach_port_t)port;
@end

void qlog(const char *fmt, ...) __printflike(1, 2);

/* once per process and selector: "missing" methods we do not implement */
void qmtl_log_selector(const char *kind, id obj, SEL sel);
/* method signature from the Metal protocols the class adopts (forwarding) */
NSMethodSignature *qmtl_signature(Class cls, SEL sel);
/* add Metal protocols at runtime (NULL-terminated names) */
void qmtl_adopt(Class cls, const char *const *protocols);

extern id qmtl_device;

uint32_t qmtl_new_id(void);
/* append one record to the ring; thread-safe, records keep their order */
bool qmtl_send(const void *rec, uint32_t size);
/* send a record whose op writes reply_status/reply and wait for the answer;
   *reply (optional) gets op-specific reply data or the error text */
bool qmtl_call(const void *rec, uint32_t size, NSData **reply);
NSError *qmtl_error(NSString *what, NSData *reply);

/* slot heap: buffer contents and staging, visible to the host in place */
int64_t qmtl_heap_alloc(uint64_t size);		/* -1 when full */
void *qmtl_heap_ptr(uint64_t off);
/* free once the host has run everything sent so far and every command
   buffer committed so far has completed (the GPU may still read it) */
void qmtl_heap_free_later(int64_t off);

/* command buffers */
uint64_t qmtl_cb_next_serial(void);
void qmtl_cb_committed(uint64_t serial);
bool qmtl_cb_done(uint64_t serial, uint32_t *error);
void qmtl_cb_wait(uint64_t serial);
/* run block on the completion thread once serial is done */
void qmtl_cb_notify(uint64_t serial, void (^block)(uint32_t error));

/* recorded MTLFunctionConstantValues (swizzled setters) */
NSArray<NSData *> *qmtl_constants_of(MTLFunctionConstantValues *values);

static inline uint32_t qmtl_size(uint32_t n)
{
	return (n + 7) & ~7u;
}
