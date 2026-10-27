// Lab: touches with exact timing, sent through XCTest's own event
// synthesizer (the way Appium's WebDriverAgent sends W3C actions). One
// record can hold several touches, each starting at its own offset, so a tap
// can land 50 ms after a swipe back. XCUIElement/XCUICoordinate taps can't:
// each one takes most of a second.
//
// Test-only code (UI test bundle); it never ships in the app.

#import <XCTest/XCTest.h>
#import <objc/runtime.h>
#import <objc/message.h>

@interface LabSynth : NSObject
+ (NSString *)perform:(NSArray *)touches;
@end

@implementation LabSynth

/// paths: one array of steps per finger. Steps: @[@"down", x, y, t],
/// @[@"move", x, y, t], @[@"up", t] — screen points (portrait), times in
/// seconds from the start of the record. A finger can go down again after
/// it lifted (pressDownAtOffset:, as WebDriverAgent does for a second tap).
/// Several fingers' paths don't keep their start times (the second one
/// starts when the first ends), so taps meant to follow a gesture at a set
/// time go in the same path.
+ (NSString *)perform:(NSArray *)paths {
    Class recCls = NSClassFromString(@"XCSynthesizedEventRecord");
    Class pathCls = NSClassFromString(@"XCPointerEventPath");
    if (!recCls || !pathCls) return @"synth: XCTest event classes not found";

    id rec = [recCls alloc];
    SEL initRec = NSSelectorFromString(@"initWithName:interfaceOrientation:");
    SEL initName = NSSelectorFromString(@"initWithName:");
    if ([rec respondsToSelector:initRec]) {
        rec = ((id (*)(id, SEL, NSString *, NSInteger))objc_msgSend)(rec, initRec, @"lab", (NSInteger)1);
    } else if ([rec respondsToSelector:initName]) {
        rec = ((id (*)(id, SEL, NSString *))objc_msgSend)(rec, initName, @"lab");
    } else {
        return @"synth: no initializer for the event record";
    }

    SEL initPath = NSSelectorFromString(@"initForTouchAtPoint:offset:");
    SEL moveSel = NSSelectorFromString(@"moveToPoint:atOffset:");
    SEL liftSel = NSSelectorFromString(@"liftUpAtOffset:");
    SEL pressSel = NSSelectorFromString(@"pressDownAtOffset:");
    SEL addSel = NSSelectorFromString(@"addPointerEventPath:");
    if (![pathCls instancesRespondToSelector:initPath]) return @"synth: no initForTouchAtPoint:offset:";
    BOOL canPress = [pathCls instancesRespondToSelector:pressSel];

    for (NSArray *steps in paths) {
        id path = nil;
        for (NSArray *st in steps) {
            NSString *kind = st[0];
            if ([kind isEqualToString:@"down"]) {
                CGPoint p = CGPointMake([st[1] doubleValue], [st[2] doubleValue]);
                double t = [st[3] doubleValue];
                if (!path) {
                    path = ((id (*)(id, SEL, CGPoint, double))objc_msgSend)([pathCls alloc], initPath, p, t);
                } else {
                    if (!canPress) return @"synth: no pressDownAtOffset:";
                    ((void (*)(id, SEL, CGPoint, double))objc_msgSend)(path, moveSel, p, MAX(0, t - 0.002));
                    ((void (*)(id, SEL, double))objc_msgSend)(path, pressSel, t);
                }
            } else if ([kind isEqualToString:@"move"]) {
                ((void (*)(id, SEL, CGPoint, double))objc_msgSend)(path, moveSel, CGPointMake([st[1] doubleValue], [st[2] doubleValue]), [st[3] doubleValue]);
            } else if ([kind isEqualToString:@"up"]) {
                ((void (*)(id, SEL, double))objc_msgSend)(path, liftSel, [st[1] doubleValue]);
            }
        }
        if (path) ((void (*)(id, SEL, id))objc_msgSend)(rec, addSel, path);
    }

    SEL syncSel = NSSelectorFromString(@"synthesizeWithError:");
    if ([rec respondsToSelector:syncSel]) {
        NSError *err = nil;
        BOOL ok = ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(rec, syncSel, &err);
        return ok ? @"synth: sent (record)" : [NSString stringWithFormat:@"synth: failed %@", err];
    }
    id device = [XCUIDevice sharedDevice];
    SEL synthGetter = NSSelectorFromString(@"eventSynthesizer");
    SEL synthSel = NSSelectorFromString(@"synthesizeEvent:completion:");
    if (![device respondsToSelector:synthGetter]) return @"synth: no event synthesizer";
    id synth = ((id (*)(id, SEL))objc_msgSend)(device, synthGetter);
    if (![synth respondsToSelector:synthSel]) return @"synth: synthesizer can't synthesize";
    __block BOOL done = NO;
    __block NSString *result = @"synth: no answer";
    void (^completion)(BOOL, NSError *) = ^(BOOL ok, NSError *err) {
        result = ok ? @"synth: sent (device)" : [NSString stringWithFormat:@"synth: failed %@", err];
        done = YES;
    };
    ((void (*)(id, SEL, id, id))objc_msgSend)(synth, synthSel, rec, completion);
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:30];
    while (!done && [until timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    return result;
}

@end
