import AppKit
import ApplicationServices
import TidyBarCore

// M0 探索工具：把 AXExtrasMenuBar 子项的**全部属性名与取值**打出来，
// 用来回答一个关键问题——Tahoe 上第三方图标的 AXTitle 基本为空，
// 那到底有没有一个跨启动稳定的标识（AXIdentifier / AXUUID / AXHelp …）可用？
//
//   swift run tidybar-attr-dump                 看全部进程的图标属性
//   swift run tidybar-attr-dump com.raycast.macos   只看某个 App
//   swift run tidybar-attr-dump --self 5        本进程造 5 个图标后 dump 自己（分辨 reader bug 与进程特殊性）

let arguments = CommandLine.arguments
let flagNames: Set<String> = ["--self"]
// 只把非选项、且不是某个选项取值的参数当作 bundle id 过滤器
var wanted: Set<String> = []
do {
    var skipNext = false
    for argument in arguments.dropFirst() {
        if skipNext { skipNext = false; continue }
        if argument.hasPrefix("--") {
            if flagNames.contains(argument) { skipNext = true }
            continue
        }
        wanted.insert(argument)
    }
}
let selfFixtureCount = arguments.firstIndex(of: "--self").flatMap { index -> Int? in
    guard index + 1 < arguments.count else { return nil }
    return Int(arguments[index + 1])
}
let myPID = ProcessInfo.processInfo.processIdentifier

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// 已知答案：图标由本进程自己创建
var heldFixtures: [NSStatusItem] = []
if let selfFixtureCount {
    for index in 1...selfFixtureCount {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "S" + String(index)
        heldFixtures.append(item)
    }
    for _ in 0..<12 { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
    print("已在本进程创建 " + String(selfFixtureCount) + " 个状态项")
}

let interestingAttributes: [String] = [
    kAXRoleAttribute, kAXSubroleAttribute, kAXRoleDescriptionAttribute,
    kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute,
    kAXIdentifierAttribute, "AXUUID", "AXLabel",
    kAXValueAttribute, kAXSelectedAttribute, kAXEnabledAttribute,
    kAXPositionAttribute, kAXSizeAttribute, kAXParentAttribute,
    "AXMainWindow", "AXFocused", "AXFrontmost", "AXHidden",
].map { $0 as String }

func copyAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func describe(_ value: CFTypeRef?) -> String {
    guard let value else { return "—" }
    if CFGetTypeID(value) == AXValueGetTypeID() {
        let axValue = value as! AXValue
        switch AXValueGetType(axValue) {
        case .cgPoint:
            var point = CGPoint.zero
            AXValueGetValue(axValue, .cgPoint, &point)
            return "Point(\(Int(point.x)),\(Int(point.y)))"
        case .cgSize:
            var size = CGSize.zero
            AXValueGetValue(axValue, .cgSize, &size)
            return "Size(\(Int(size.width)),\(Int(size.height)))"
        case .cgRect:
            var rect = CGRect.zero
            AXValueGetValue(axValue, .cgRect, &rect)
            return "Rect(\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height)))"
        default:
            return "AXValue(其他类型)"
        }
    }
    if let string = value as? String { return string.isEmpty ? "\"\"" : "\"\(string)\"" }
    if let number = value as? NSNumber { return number.boolValue ? "true" : number.stringValue }
    if CFGetTypeID(value) == AXUIElementGetTypeID() { return "<AXUIElement>" }
    let array = value as! CFArray
    return "<Array x\(CFArrayGetCount(array))>"
}

/// 元素自身拥有的全部属性名（比猜属性名可靠）
func attributeNames(of element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyAttributeNames(element, &names) == .success, let names else { return [] }
    let array = names as! [String]
    return array
}

print("本进程 pid=\(ProcessInfo.processInfo.processIdentifier)，bundleID=\(Bundle.main.bundleIdentifier ?? "nil")")
let ourEntry = NSWorkspace.shared.runningApplications.first { $0.processIdentifier == ProcessInfo.processInfo.processIdentifier }
print("本进程在 runningApplications 中: \(ourEntry != nil)，activationPolicy=\(String(describing: ourEntry?.activationPolicy))")
print("AXIsProcessTrusted = \(AXIsProcessTrusted())")

var dumpedProcesses = 0
for application in NSWorkspace.shared.runningApplications where application.activationPolicy != .prohibited {
    if selfFixtureCount != nil {
        // 已知答案模式：只看本进程（判定 reader 通路）+ 一个真实第三方 App 作对照
        guard application.processIdentifier == myPID
            || application.bundleIdentifier == "com.raycast.macos" else { continue }
    } else if !wanted.isEmpty, let id = application.bundleIdentifier, !wanted.contains(id) { continue }

    let appElement = AXUIElementCreateApplication(application.processIdentifier)
    guard let extrasValue = copyAttribute(appElement, "AXExtrasMenuBar") else { continue }
    guard CFGetTypeID(extrasValue) == AXUIElementGetTypeID() else { continue }
    let extras = extrasValue as! AXUIElement

    guard let childrenValue = copyAttribute(extras, kAXChildrenAttribute as String) else { continue }
    let cfChildren = childrenValue as! CFArray
    let childCount = CFArrayGetCount(cfChildren)

    dumpedProcesses += 1
    print("\n───── \(application.bundleIdentifier ?? "(无 bundleID)") ｜ \(application.localizedName ?? "?") ｜ pid=\(application.processIdentifier) ｜ 子项 \(childCount)")

    for index in 0..<min(childCount, wanted.isEmpty ? 6 : childCount) {
        guard let raw = CFArrayGetValueAtIndex(cfChildren, index) else { continue }
        let child = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue() as! AXUIElement

        let names = attributeNames(of: child)
        print("  · 子项[\(index)] 属性名: \(names.isEmpty ? "(空)" : names.joined(separator: ", "))")
        for name in interestingAttributes {
            let value = copyAttribute(child, name)
            let rendered = describe(value)
            if rendered != "—" || name == kAXTitleAttribute {
                print("      \(name) = \(rendered)")
            }
        }
    }
}

print("\n共 dump \(dumpedProcesses) 个进程")
