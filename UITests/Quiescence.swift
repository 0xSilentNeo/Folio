import XCTest
import ObjectiveC

/// XCUITest waits for the app to be idle — no animation running — before it
/// sends each tap ("Wait for app to idle" in the test log). That makes a tap
/// *during* an animation impossible to test: the tap only lands once the
/// animation is over. Real fingers don't wait, and several reported bugs live
/// exactly in that window (a tap while a menu or a page is still animating).
///
/// There is no public switch for this. This looks up XCTest's private
/// quiescence methods at run time, prints what it finds, and replaces only
/// methods whose type encoding is exactly `void (id, SEL, BOOL[, BOOL])` with
/// an empty body. If XCTest changes, nothing matches, nothing is replaced, and
/// the report says so — the test then still runs, with the usual waiting.
enum Quiescence {
    private static var done = false

    @discardableResult
    static func skipWaiting() -> String {
        if done { return "already off" }
        var report: [String] = []
        for clsName in ["XCUIApplicationProcess", "XCUIApplicationImpl", "XCUIApplication"] {
            guard let cls = NSClassFromString(clsName) else { report.append("\(clsName): not found"); continue }
            var count: UInt32 = 0
            guard let list = class_copyMethodList(cls, &count) else { continue }
            defer { free(list) }
            for i in 0..<Int(count) {
                let m = list[i]
                let name = NSStringFromSelector(method_getName(m))
                guard name.lowercased().contains("quiescence") else { continue }
                let enc = method_getTypeEncoding(m).map { String(cString: $0) } ?? "?"
                var replaced = false
                if clsName == "XCUIApplicationProcess" {
                    let args = name.filter { $0 == ":" }.count
                    // v = void return; @ self; : _cmd; B = BOOL (offsets vary by arch, so strip digits)
                    let shape = enc.filter { !$0.isNumber }
                    if args == 1, shape == "v@:B" {
                        let b: @convention(block) (AnyObject, Bool) -> Void = { _, _ in }
                        method_setImplementation(m, imp_implementationWithBlock(b)); replaced = true
                    } else if args == 2, shape == "v@:BB" {
                        let b: @convention(block) (AnyObject, Bool, Bool) -> Void = { _, _, _ in }
                        method_setImplementation(m, imp_implementationWithBlock(b)); replaced = true
                    } else if args == 3, shape == "v@:BBB" {
                        // Xcode 27: waitForQuiescenceIncludingAnimationsIdle:usingActivity:isPreEvent:
                        let b: @convention(block) (AnyObject, Bool, Bool, Bool) -> Void = { _, _, _, _ in }
                        method_setImplementation(m, imp_implementationWithBlock(b)); replaced = true
                    }
                }
                report.append("\(clsName) -\(name) \(enc)\(replaced ? " → skipped" : "")")
            }
        }
        done = true
        let text = report.joined(separator: "; ")
        print("QUIESCENCE \(text)")
        return text
    }
}
