import SwiftUI
import UIKit

/// A picture in iOS's own zooming scroll view — the Photos-app feel: pinch zoom with rubber-banding, double-tap to
/// zoom into the tapped spot (again to zoom out), momentum panning while zoomed. At normal size, horizontal swipes
/// are left to the pager around it (next/previous picture) and a downward swipe closes the viewer.
struct ZoomingImageView: UIViewRepresentable {
    let image: UIImage
    /// How far the picture is being pulled down to close (0 when not), for the viewer to fade its background.
    var onDismissDrag: (CGFloat) -> Void = { _ in }
    var onDismiss: () -> Void = {}

    func makeUIView(context: Context) -> ZoomScrollView {
        let view = ZoomScrollView()
        view.onDismissDrag = onDismissDrag
        view.onDismiss = onDismiss
        view.display(image)
        return view
    }

    func updateUIView(_ view: ZoomScrollView, context: Context) {
        view.onDismissDrag = onDismissDrag
        view.onDismiss = onDismiss
        if view.imageView.image !== image { view.display(image) }
    }
}

final class ZoomScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    var onDismissDrag: (CGFloat) -> Void = { _ in }
    var onDismiss: () -> Void = {}
    private var dismissing = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        backgroundColor = .clear
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        decelerationRate = .fast
        contentInsetAdjustmentBehavior = .never
        minimumZoomScale = 1
        maximumZoomScale = 5
        alwaysBounceVertical = true // lets the picture be pulled down to close at normal size
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func display(_ image: UIImage) {
        zoomScale = 1
        imageView.image = image
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale == minimumZoomScale {
            imageView.frame = bounds
            contentSize = bounds.size
        }
        centerImage()
    }

    private func centerImage() {
        let offsetX = max((bounds.width - contentSize.width) / 2, 0)
        let offsetY = max((bounds.height - contentSize.height) / 2, 0)
        imageView.center = CGPoint(x: contentSize.width / 2 + offsetX, y: contentSize.height / 2 + offsetY)
    }

    /// At normal size only vertical drags start here (pull down to close); horizontal ones go to the pager so the
    /// next picture swipes in without fighting this scroll view.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer, zoomScale <= minimumZoomScale + 0.01 {
            let velocity = panGestureRecognizer.velocity(in: self)
            return velocity.y > abs(velocity.x)
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    @objc private func handleDoubleTap(_ tap: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let point = tap.location(in: imageView)
            let scale: CGFloat = 2.5
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard zoomScale <= minimumZoomScale + 0.01, !dismissing else { return }
        onDismissDrag(max(0, -contentOffset.y))
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard zoomScale <= minimumZoomScale + 0.01 else { return }
        if -contentOffset.y > 110 || velocity.y < -1.4 {
            dismissing = true
            onDismiss()
        }
    }
}
