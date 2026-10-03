import CoreGraphics
import Foundation

/// 在指定屏幕坐标处合成滚轮事件，驱动 profile 模式下的应用滚动。
/// （需要辅助功能权限；CGWarpMouseCursorPosition 不需要）
///
/// Usage: scroll <x> <y> <dyPixelsPerEvent> <count> <intervalMs>
/// dy < 0 向下滚，dy > 0 向上滚
let args = CommandLine.arguments
let x = Double(args[1])!
let y = Double(args[2])!
let dy = Int32(args[3])!
let count = Int(args[4])!
let intervalMs = Double(args[5])!

CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
usleep(200_000)

for _ in 0..<count {
    let ev = CGEvent(
        scrollWheelEvent2Source: nil,
        units: .pixel,
        wheelCount: 1,
        wheel1: dy,
        wheel2: 0,
        wheel3: 0
    )!
    ev.post(tap: .cghidEventTap)
    usleep(UInt32(intervalMs * 1000))
}
