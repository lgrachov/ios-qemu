/* A minimal user app for testing tools/install-app.py: one screen with a label. */
#import <UIKit/UIKit.h>

@interface HelloDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation HelloDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options
{
	UIViewController *vc = [UIViewController new];
	vc.view.backgroundColor = UIColor.systemTealColor;
	UILabel *label = [UILabel new];
	label.text = @"Hello from QEMU";
	label.font = [UIFont boldSystemFontOfSize:34];
	label.textColor = UIColor.whiteColor;
	label.translatesAutoresizingMaskIntoConstraints = NO;
	[vc.view addSubview:label];
	[NSLayoutConstraint activateConstraints:@[
		[label.centerXAnchor constraintEqualToAnchor:vc.view.centerXAnchor],
		[label.centerYAnchor constraintEqualToAnchor:vc.view.centerYAnchor],
	]];
	self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
	self.window.rootViewController = vc;
	[self.window makeKeyAndVisible];
	return YES;
}
@end

int main(int argc, char *argv[])
{
	@autoreleasepool {
		return UIApplicationMain(argc, argv, nil, NSStringFromClass(HelloDelegate.class));
	}
}
