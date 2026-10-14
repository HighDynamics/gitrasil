import SwiftUI
import GitrasilCore

/// A stem grafted onto wood drawn in an earlier group (a bough off the shared trunk): narrowed inside
/// that wood and faded in over it, so it grows out of it (`TreeDrawing.draw`).
extension TreeDrawing {
    /// A grafted stem's `samples` (`draw`) narrowed where they lie inside their `parent`'s wood, from a
    /// third of their width at the foot to all of it where the stem leaves the parent, so its collar
    /// flares out of the parent's edge rather than ending in a corner past it. Inside, it fades away
    /// (`fadeIn`), so how narrow it is there doesn't show. Its collar flares less than a limb's (at most
    /// `graftFlare` past its own width, `own` points), so on a bough leaving the trunk at a slant it doesn't
    /// bulge out under the bough past the trunk's edge.
    func graft(_ samples: [(point: CGPoint, width: CGFloat)], into parent: Path, own: CGFloat) -> [(point: CGPoint, width: CGFloat)] {
        let most = own * Self.graftFlare
        let samples = samples.map { sample in
            // Eases toward the most rather than stopping at it, so the flare keeps its curve.
            let flare = max(sample.width - own, 0)
            return (point: sample.point, width: flare > 0 ? own + flare * most / (most + flare) : sample.width)
        }
        guard let out = samples.firstIndex(where: { !parent.contains($0.point) }), out > 0 else { return samples }
        var along: [CGFloat] = [0]
        for i in 1...out {
            along.append(along[i - 1] + hypot(samples[i].point.x - samples[i - 1].point.x, samples[i].point.y - samples[i - 1].point.y))
        }
        let leaves = max(along[out], 0.001)
        return samples.enumerated().map { i, sample in
            guard i < out else { return sample }
            let t = along[i] / leaves
            return (sample.point, sample.width * (1 / 3 + 2 / 3 * t * t * (3 - 2 * t)))
        }
    }

    static let graftFlare: CGFloat = 0.35

    /// Fades out the start of stem `index`'s wood in `layer` where it lies over its `parent`'s wood, so it
    /// grows out of that wood: gone at its foot, fully there by `emergence` of its parent's width along it
    /// or once it's clear of the parent, with no disc at the joint and its collar whole past the parent's edge.
    /// It eases off toward the parent's edge (`feather`), so there's no line where the parent's wood ends.
    func fadeIn(_ index: Int, _ stems: [TreeLayout.Stem], _ outlines: [[(point: CGPoint, width: CGFloat)]],
                over parent: [Path], in layer: inout GraphicsContext) {
        guard let fork = stems[index].fork, let foot = outlines[index].first?.point, let end = outlines[index].last?.point else { return }
        let length = max(fork.width * frame.scale * Self.emergence, 1)
        // Its direction from the foot, by where it is once it has faded in.
        let ahead = outlines[index].first { hypot($0.point.x - foot.x, $0.point.y - foot.y) >= length }?.point ?? end
        let span = max(hypot(ahead.x - foot.x, ahead.y - foot.y), 0.001)
        let to = CGPoint(x: foot.x + (ahead.x - foot.x) / span * length, y: foot.y + (ahead.y - foot.y) / span * length)
        var eraser = layer
        eraser.blendMode = .destinationOut
        let wood = parent.dropFirst().reduce(parent.first ?? Path()) { $0.union($1) }
        let feather = min(fork.width * frame.scale * Self.feather, 4)
        eraser.drawLayer { mask in
            mask.fill(wood, with: .color(.black))
            var edge = mask
            edge.blendMode = .destinationOut
            edge.addFilter(.blur(radius: feather / 2))
            edge.stroke(wood, with: .color(.black), lineWidth: feather * 2)
            mask.blendMode = .sourceIn
            mask.fill(Path(ellipseIn: CGRect(x: foot.x - length, y: foot.y - length, width: 2 * length, height: 2 * length)),
                      with: .linearGradient(Gradient(stops: [.init(color: .black, location: 0),
                                                             .init(color: .black.opacity(0.45), location: 0.4),
                                                             .init(color: .black.opacity(0), location: 1)]),
                                            startPoint: foot, endPoint: to))
        }
    }

    /// How far along an emerging stem it fades in, as a fraction of its parent's width (`fadeIn`); and how
    /// far in from the parent's edge the fade eases off, as a fraction of its width too.
    static let emergence: CGFloat = 0.6
    static let feather: CGFloat = 0.06
}
