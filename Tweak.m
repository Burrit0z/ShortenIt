#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <objc/runtime.h>
#include <substrate.h>

#import "Tweak.h"
#import "api.h"

/*
	In order to compile this, you MUST create a file called api.h with a #define for 
	kAPI_URL. It should be in the following format, and must be for a YOURLS instance

	#define kAPI_URL @"https://e.example.com/yourls-api.php?signature=example"

	Do not share your signature with anyone. If the YOURLS api is public on the instance,
	then you don't need to worry about the signature.

	Look at http://yourls.org/#API if you are interested in learning more aboit the api
*/

// Make POST request to API with error message
// Returns shortened URL
static NSString *makeAPIRequest(NSString *selectedText) {
    // nil is success
    __block NSString *status = nil;
    __block NSString *result = nil;

    if(selectedText && ([selectedText hasPrefix:@"https://"] || [selectedText hasPrefix:@"http://"])) {
        // Bad use of semaphore. Unfortunately I kinda do need to do this since the function
        // returns a value...
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

        NSURLSession *session = [NSURLSession sharedSession];
        // Make action be set to shorten, and we want response in JSON
        NSURL *postURL = [NSURL URLWithString:[NSString stringWithFormat:@"%@&action=shorturl&url=%@&format=json", kAPI_URL, selectedText]];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:postURL];
        request.HTTPMethod = @"POST";

        NSURLSessionDataTask *task = [session dataTaskWithRequest:request
                                                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                                                    if(error || ((NSHTTPURLResponse *)response).statusCode != 200) {
                                                        status = [NSString stringWithFormat:@"Error making request.\n\nError: %@\nStatus code: %ld", error, (long)((NSHTTPURLResponse *)response).statusCode];
                                                    } else {
                                                        NSError *conversionError;
                                                        NSDictionary *response = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:&conversionError];

                                                        if(conversionError) {
                                                            status = @"Failure converting response from JSON to NSDictionary";
                                                        } else {
                                                            if(response[@"shorturl"]) {
                                                                // This should be where our shortened URL is
                                                                result = response[@"shorturl"];
                                                            } else {
                                                                status = @"Shortened URL was nil";
                                                            }
                                                        }
                                                    }

                                                    dispatch_semaphore_signal(semaphore);
                                                }];

        // Do task off the main thread cause why not
        dispatch_async(dispatch_queue_create("com.burritoz.shortenit.networking", NULL), ^{
            [task resume];
        });

        // Wait for completion, then return status
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    } else {
        status = @"No valid URL was found, or no text was selected";
    }

    // Check if there was an error
    if(status) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"ShortenIt"
                                                                       message:status
                                                                preferredStyle:UIAlertControllerStyleAlert];

        UIAlertAction *f = [UIAlertAction actionWithTitle:@"OK"
                                                    style:UIAlertActionStyleCancel
                                                  handler:^(UIAlertAction *action){
                                                  }];

        [alert addAction:f];

        // Yeah its deprecated... and?
        [UIApplication.sharedApplication.keyWindow.rootViewController presentViewController:alert animated:YES completion:nil];
    }

    return result;
}

//- (void)shortenURL
static void shortenURL(UITextField *self, SEL _cmd) {
    if(![self respondsToSelector:@selector(selectedText)]) return;
    NSString *selectedText = [self selectedText];

    NSString *shortURL = makeAPIRequest(selectedText);
    if(shortURL) {
        // Set clipboard to our URL
        UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
        pasteboard.string = shortURL;

        // It's actually a lot more efficient *not* to reallocate every time
        static const UINotificationFeedbackGenerator *gen;
        gen = [[UINotificationFeedbackGenerator alloc] init];
        // Create a haptic to signify our work is done, and there was success
        [gen notificationOccurred:UINotificationFeedbackTypeSuccess];

        // Replace occurences of the old URL with new URL in text field
        // Make an exception for ICTextView, notes apps freezes lol
        // It's not even something I can try/catch, since it doesnt raise an exception
        NSString *newText = [self.text stringByReplacingOccurrencesOfString:selectedText withString:shortURL];
        if(![self isKindOfClass:objc_getClass("ICTextView")]) self.text = newText;
    }
}

static void addMenuItem() {
    // Just call the setter to make our hook take effect

    // Some apps don't have this set manually, so otherwise our action
    // will not get added. Works for every app I tested, like Twitter, Discord
    // (which add their own items) and Spotlight/apps which don't

    // If we added an item here, it would get added twice for apps that don't
    // implement custom menu items
    UIMenuController.sharedMenuController.menuItems = @[];
}

static void (*orig_setMenuItems)(UIMenuController *, SEL, NSArray *);
static void hooked_setMenuItems(UIMenuController *self, SEL _cmd, NSArray *items) {
    UIMenuItem *item = [[UIMenuItem alloc] initWithTitle:@"Shorten" action:@selector(shortenURL)];
    NSMutableArray *mut = [items mutableCopy];
    [mut addObject:item];

    orig_setMenuItems(self, _cmd, mut);
}

__attribute((constructor)) static void loadTweak() {
    // Add our menu item when the app finished launching
    // Otherwise we will crash SpringBoard lol

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetLocalCenter(),
        NULL,
        addMenuItem,
        CFSTR("UIApplicationDidFinishLaunchingNotification"),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);

    // Unfortunately, apps can reset this on us, so we'll need a hook, too
    MSHookMessageEx(
        [UIMenuController class],
        @selector(setMenuItems:),
        (IMP)&hooked_setMenuItems,
        (IMP *)&orig_setMenuItems);

    // Here's the method we are adding
    class_addMethod(
        [UIResponder class],
        @selector(shortenURL),
        (IMP)shortenURL,
        "v@:");
}
