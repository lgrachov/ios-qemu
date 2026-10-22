/* Embedded framework of the test app, loaded through @rpath (needs patch 0101). */
#import <Foundation/Foundation.h>

NSString *HelloKitGreeting(void)
{
	return @"Hello from QEMU";
}
