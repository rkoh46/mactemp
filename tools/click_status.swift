// Helper used to open the MacTemp menu bar item (for screenshots / automated QA).
import AppKit

func axCopy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(el, attr as CFString, &value)
    return value
}

guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == "MacTemp" }) else {
    print("MacTemp not running"); exit(1)
}
let axApp = AXUIElementCreateApplication(app.processIdentifier)
guard let extras = axCopy(axApp, "AXExtrasMenuBar") else { print("no AXExtrasMenuBar"); exit(1) }
let mb = extras as! AXUIElement
let items = (axCopy(mb, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
print("status items: \(items.count)")
var titles: [String] = []
for item in items {
    let t = (axCopy(item, kAXTitleAttribute as String) as? String) ?? ""
    titles.append(t)
    print("item: \(t)")
}
let target = items.first(where: { (($0 as AXUIElement).value(kAXTitleAttribute) ?? "") != "" }) ?? items.first
guard let item = target else { print("no item"); exit(1) }
guard let posVal = axCopy(item, kAXPositionAttribute as String),
      let sizeVal = axCopy(item, kAXSizeAttribute as String) else { print("no geometry"); exit(1) }
var point = CGPoint.zero; AXValueGetValue(posVal as! AXValue, .cgPoint, &point)
var size = CGSize.zero;   AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
let click = CGPoint(x: point.x + size.width / 2, y: point.y + size.height / 2)
print("clicking \(click)")
CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: click, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(300_000)
CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: click, mouseButton: .left)?.post(tap: .cghidEventTap)
print("clicked")

extension AXUIElement {
    func value(_ attr: String) -> String? {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(self, attr as CFString, &v)
        return v as? String
    }
}
