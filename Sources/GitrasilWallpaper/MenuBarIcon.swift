import AppKit

/// The menu-bar item's image: a small tree (a leafy crown with forking branches cut through it, on
/// a trunk that flares into roots), drawn as a template so it takes the menu bar's own tint in light,
/// dark and highlighted states.
///
/// A placeholder: the Gitrasil icon Daniel remembers wasn't found in the repository's history, its
/// branches and stashes, ~/Downloads/gitrasil, the old session transcripts or Spotlight. Swap this
/// for the real one (as a template PDF or PNG) when it turns up.
enum MenuBarIcon {

    static func image() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()

            // The crown: overlapping leafy lobes.
            let crown = NSBezierPath()
            for (x, y, r) in [(9.0, 12.6, 4.4), (4.9, 10.9, 3.1), (13.1, 10.9, 3.1), (6.4, 14.3, 3.0), (11.6, 14.3, 3.0)] {
                crown.append(NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)))
            }
            crown.windingRule = .nonZero
            crown.fill()

            // The trunk, flaring into two roots.
            let trunk = NSBezierPath()
            trunk.move(to: NSPoint(x: 5.4, y: 0.8))
            trunk.curve(to: NSPoint(x: 8, y: 3.4), controlPoint1: NSPoint(x: 7, y: 1.2), controlPoint2: NSPoint(x: 7.8, y: 2))
            trunk.line(to: NSPoint(x: 8, y: 9))
            trunk.line(to: NSPoint(x: 10, y: 9))
            trunk.line(to: NSPoint(x: 10, y: 3.4))
            trunk.curve(to: NSPoint(x: 12.6, y: 0.8), controlPoint1: NSPoint(x: 10.2, y: 2), controlPoint2: NSPoint(x: 11, y: 1.2))
            trunk.close()
            trunk.fill()

            // Branches forking up through the crown, cut out of it.
            NSGraphicsContext.current?.compositingOperation = .clear
            let limbs = NSBezierPath()
            limbs.move(to: NSPoint(x: 9, y: 8.4))
            limbs.line(to: NSPoint(x: 9, y: 14.6))
            limbs.move(to: NSPoint(x: 9, y: 9.6))
            limbs.curve(to: NSPoint(x: 5.2, y: 12.4), controlPoint1: NSPoint(x: 7.4, y: 10.2), controlPoint2: NSPoint(x: 5.8, y: 11.2))
            limbs.move(to: NSPoint(x: 9, y: 10.8))
            limbs.curve(to: NSPoint(x: 12.8, y: 13.2), controlPoint1: NSPoint(x: 10.6, y: 11.4), controlPoint2: NSPoint(x: 12.2, y: 12.2))
            limbs.lineWidth = 1.1
            limbs.lineCapStyle = .round
            limbs.stroke()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Gitrasil Background"
        return image
    }
}
