import Foundation

/// 极简测试骨架。
///
/// 为什么不直接用 XCTest / swift-testing：本机可能只装了 Command Line Tools，
/// 此时 `swift test` 两条路都断（XCTest 未随 CLT 安装；swift-testing 的
/// Testing.framework 又缺 lib_TestingInterop.dylib，dlopen 失败）。
/// M0 阶段需要的是「任何 Mac 上 clone 下来就能跑的回归」，所以先用零依赖 runner：
///     swift run tidybar-checks
/// 装了完整 Xcode 后，可把 Cases 目录整体平移回 swift-testing/XCTest（断言语义已刻意对齐）。

public struct CheckFailure: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// 一条用例：名称 + 可执行体
public struct TestCase {
    public let name: String
    public let body: () throws -> Void

    public init(_ name: String, _ body: @escaping () throws -> Void) {
        self.name = name
        self.body = body
    }
}

public struct TestSuite {
    public let name: String
    public let cases: [TestCase]

    public init(_ name: String, _ cases: [TestCase]) {
        self.name = name
        self.cases = cases
    }
}

/// 当前用例的失败收集箱。
/// 断言设计为「不抛错、只记账」，这样一条用例里的多个检查都能跑完、一次看全部问题；
/// 只有 require/record 这类「无法继续」的情况才抛错提前中止。
enum FailureBox {
    nonisolated(unsafe) private static var messages: [String] = []

    static func begin() { messages = [] }
    static func add(_ message: String) { messages.append(message) }
    static func finish() -> [String] { messages }
}

// MARK: - 断言

func location(_ file: String, _ line: Int) -> String {
    " (\(URL(fileURLWithPath: file).lastPathComponent):\(line))"
}

public func expect(
    _ condition: Bool,
    _ message: String = "",
    file: String = #file,
    line: Int = #line
) {
    if !condition {
        FailureBox.add("断言失败\(location(file, line))\(message.isEmpty ? "" : " — " + message)")
    }
}

public func expectEqual<Value: Equatable>(
    _ lhs: Value,
    _ rhs: Value,
    _ message: String = "",
    file: String = #file,
    line: Int = #line
) {
    if lhs != rhs {
        FailureBox.add("期望 \(rhs)，实际 \(lhs)\(location(file, line))\(message.isEmpty ? "" : " — " + message)")
    }
}

public func expectNil<Value>(
    _ value: Value?,
    _ message: String = "",
    file: String = #file,
    line: Int = #line
) {
    if value != nil {
        FailureBox.add("期望 nil，实际 \(String(describing: value))\(location(file, line))\(message.isEmpty ? "" : " — " + message)")
    }
}

public func expectNotNil<Value>(
    _ value: Value?,
    _ message: String = "",
    file: String = #file,
    line: Int = #line
) {
    if value == nil {
        FailureBox.add("期望非 nil\(location(file, line))\(message.isEmpty ? "" : " — " + message)")
    }
}

/// 断言抛出特定错误（等价于 swift-testing 的 #expect(throws:)）
public func expect<E: Error & Equatable>(
    throws expected: E,
    file: String = #file,
    line: Int = #line,
    _ body: () throws -> Void
) {
    do {
        try body()
        FailureBox.add("应当抛出 \(expected)，但没有抛出\(location(file, line))")
    } catch let error as E {
        if error != expected {
            FailureBox.add("错误类型对但值不符：期望 \(expected)，实际 \(error)\(location(file, line))")
        }
    } catch {
        FailureBox.add("抛出了非预期错误 \(error)\(location(file, line))")
    }
}

public func expectThrows(
    file: String = #file,
    line: Int = #line,
    _ body: () throws -> Void
) {
    do {
        try body()
        FailureBox.add("应当抛出错误，但没有抛出\(location(file, line))")
    } catch {
        // 如期抛错
    }
}

// MARK: - 需要中止的用例级工具

public func require<Value>(_ value: Value?, _ message: String = "") throws -> Value {
    guard let value else { throw CheckFailure("必要值缺失：\(message)") }
    return value
}

public func record(_ message: String) throws {
    FailureBox.add(message)
    throw CheckFailure(message)
}

// MARK: - 运行器

public enum Runner {
    public struct Summary {
        public let passed: Int
        public let failed: Int
        public var didAllPass: Bool { failed == 0 }
    }

    @discardableResult
    public static func run(_ suites: [TestSuite], verbose: Bool = false) -> Summary {
        var passed = 0
        var failures: [(suite: String, test: String, messages: [String])] = []

        for suite in suites {
            print("▸ \(suite.name)")
            for test in suite.cases {
                FailureBox.begin()
                var aborted: String?
                do {
                    try test.body()
                } catch {
                    aborted = error.localizedDescription
                }
                var messages = FailureBox.finish()
                if let aborted, !messages.contains(aborted) { messages.append(aborted) }

                if messages.isEmpty {
                    passed += 1
                    if verbose { print("  ✓ \(test.name)") }
                } else {
                    failures.append((suite.name, test.name, messages))
                    print("  ✗ \(test.name)")
                }
            }
        }

        print("")
        if failures.isEmpty {
            print("全部通过：\(passed) 条用例，\(suites.count) 个套件")
        } else {
            print("失败 \(failures.count) / 共 \(passed + failures.count)：")
            for failure in failures {
                print("  ✗ \(failure.suite).\(failure.test)")
                for message in failure.messages {
                    print("      \(message)")
                }
            }
        }
        return Summary(passed: passed, failed: failures.count)
    }
}
