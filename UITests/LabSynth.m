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

/// touches: [{ "points": [[x, y, t], …], "lift": t }, …] — screen points
/// (portrait), times in seconds from the start of the record. The first
/// point is where the finger goes down.
+ (NSString *)perform:(NSArray *)touches {
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
    SEL addSel = NSSelectorFromString(@"addPointerEventPath:");
    if (![pathCls instancesRespondToSelector:initPath]) return @"synth: no initForTouchAtPoint:offset:";

    for (NSDictionary *t in touches) {
        NSArray *pts = t[@"points"];
        NSArray *p0 = pts.firstObject;
        CGPoint start = CGPointMake([p0[0] doubleValue], [p0[1] doubleValue]);
        id path = ((id (*)(id, SEL, CGPoint, double))objc_msgSend)([pathCls alloc], initPath, start, [p0[2] doubleValue]);
        for (NSUInteger i = 1; i < pts.count; i++) {
            NSArray *p = pts[i];
            ((void (*)(id, SEL, CGPoint, double))objc_msgSend)(path, moveSel, CGPointMake([p[0] doubleValue], [p[1] doubleValue]), [p[2] doubleValue]);
        }
        ((void (*)(id, SEL, double))objc_msgSend)(path, liftSel, [t[@"lift"] doubleValue]);
        ((void (*)(id, SEL, id))objc_msgSend)(rec, addSel, path);
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
