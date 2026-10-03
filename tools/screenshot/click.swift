import CoreGraphics
import Foundation

/// 在指定屏幕坐标合成一次鼠标左键点击（需要辅助功能权限）。
///
/// Usage: click <x> <y>
let x = Double(CommandLine.arguments[1])!
let y = Double(CommandLine.arguments[2])!
let point = CGPoint(x: x, y: y)

CGWarpMouseCursorPosition(point)
usleep(200_000)

let down = CGEvent(
    mouseEventSource: nil,
    mouseType: .leftMouseDown,
    mouseCursorPosition: point,
    mouseButton: .left
)!
down.post(tap: .cghidEventTap)
usleep(80_000)

let up = CGEvent(
    mouseEventSource: nil,
    mouseType: .leftMouseUp,
    mouseCursorPosition: point,
    mouseButton: .left
)!
up.post(tap: .cghidEventTap)
