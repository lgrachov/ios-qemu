/*
 * qemu-appinstalld: installs and removes user apps in the iOS guest.
 *
 * launchd runs it per connection (inetdCompatibility, socket 127.0.0.1:62080,
 * added to the disk by `tools/install-app.py setup DISK`); stdin/stdout are
 * the connection. The host reaches the port through the kernel mux relay
 * (patch 0100). One command per connection, lines end with \n:
 *
 *   INSTALL <bundle-id> <size>\n  then <size> bytes of the .ipa
 *   UNINSTALL <bundle-id>\n
 *
 * Replies: "PROGRESS <percent> <status>" lines, then "OK" or "ERROR <reason>".
 * Installs go through LSApplicationWorkspace -> installd like an App Store or
 * Xcode install: the app lands in /var/containers/Bundle/Application as a
 * user app and can be deleted from the home screen. installd only serves
 * clients with com.apple.private.mobileinstall.allowedSPI (entitlements.plist).
 */
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <unistd.h>

@interface NSObject (QEMUAppInstall)
+ (id)defaultWorkspace;
- (BOOL)installApplication:(NSURL *)url withOptions:(NSDictionary *)options error:(NSError **)error usingBlock:(void (^)(NSDictionary *progress))block;
- (BOOL)uninstallApplication:(NSString *)bundleID withOptions:(NSDictionary *)options error:(NSError **)error usingBlock:(void (^)(NSDictionary *progress))block;
@end

static void reply(NSString *line)
{
	printf("%s\n", line.UTF8String);
	fflush(stdout);
}

static void (^progress)(NSDictionary *) = ^(NSDictionary *p) {
	reply([NSString stringWithFormat:@"PROGRESS %@ %@", p[@"PercentComplete"] ?: @"?", p[@"Status"] ?: @""]);
};

static int install(id workspace, NSString *bundleID, long long size)
{
	NSString *path = [NSString stringWithFormat:@"/private/var/tmp/qemu-appinstall-%d.ipa", getpid()];
	FILE *f = fopen(path.fileSystemRepresentation, "wb");
	if (f == NULL) {
		reply(@"ERROR cannot create the temporary file");
		return 1;
	}
	char buf[65536];
	long long left = size;
	while (left > 0) {
		size_t n = fread(buf, 1, left < (long long)sizeof(buf) ? (size_t)left : sizeof(buf), stdin);
		if (n == 0 || fwrite(buf, 1, n, f) != n) {
			break;
		}
		left -= n;
	}
	fclose(f);
	if (left != 0) {
		unlink(path.fileSystemRepresentation);
		reply(@"ERROR short upload");
		return 1;
	}
	NSError *error = nil;
	BOOL ok = [workspace installApplication:[NSURL fileURLWithPath:path]
	                            withOptions:@{@"CFBundleIdentifier": bundleID, @"PackageType": @"Customer"}
	                                  error:&error
	                             usingBlock:progress];
	unlink(path.fileSystemRepresentation);
	reply(ok ? @"OK" : [NSString stringWithFormat:@"ERROR %@", error ?: @"install failed"]);
	return ok ? 0 : 1;
}

int main(void)
{
	@autoreleasepool {
		char line[512];
		if (fgets(line, sizeof(line), stdin) == NULL) {
			return 1;
		}
		NSArray<NSString *> *words = [[@(line) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
		    componentsSeparatedByString:@" "];
		/* LSApplicationWorkspace (private) lives in CoreServices, which Foundation does not load */
		dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW);
		id workspace = [NSClassFromString(@"LSApplicationWorkspace") defaultWorkspace];
		if (workspace == nil) {
			reply(@"ERROR LSApplicationWorkspace unavailable");
			return 1;
		}
		if (words.count == 3 && [words[0] isEqualToString:@"INSTALL"]) {
			return install(workspace, words[1], words[2].longLongValue);
		}
		if (words.count == 2 && [words[0] isEqualToString:@"UNINSTALL"]) {
			NSError *error = nil;
			BOOL ok = [workspace uninstallApplication:words[1] withOptions:nil error:&error usingBlock:progress];
			reply(ok ? @"OK" : [NSString stringWithFormat:@"ERROR %@", error ?: @"uninstall failed"]);
			return ok ? 0 : 1;
		}
		reply(@"ERROR usage: INSTALL <bundle-id> <size> | UNINSTALL <bundle-id>");
		return 1;
	}
}
