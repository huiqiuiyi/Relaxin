import Photos
import SwiftUI
import UIKit

/// In-process photo library grid picker.
///
/// Unlike PhotosPicker / PHPickerViewController (which run the picker in a
/// separate system extension process that fails to launch on sideloaded
/// apps), this controller talks to the Photos framework directly inside the
/// app process, so it works on unsigned/sideloaded installations.
final class RelaxinPhotoPickerController: UIViewController {
    private enum PickerMode {
        case image
        case video
    }

    private let mode: PickerMode
    private let onPick: (URL) -> Void
    private let onCancel: () -> Void

    private var collectionView: UICollectionView!
    private var assets: PHFetchResult<PHAsset> = PHFetchResult<PHAsset>()
    private var thumbnailCache: [String: UIImage] = [:]
    private let imageManager = PHImageManager.default()

    private init(
        mode: PickerMode,
        onPick: @escaping (URL) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.mode = mode
        self.onPick = onPick
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func imageMode(
        onPick: @escaping (URL) -> Void,
        onCancel: @escaping () -> Void
    ) -> RelaxinPhotoPickerController {
        RelaxinPhotoPickerController(mode: .image, onPick: onPick, onCancel: onCancel)
    }

    static func videoMode(
        onPick: @escaping (URL) -> Void,
        onCancel: @escaping () -> Void
    ) -> RelaxinPhotoPickerController {
        RelaxinPhotoPickerController(mode: .video, onPick: onPick, onCancel: onCancel)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = mode == .image ? "选择背景图片" : "选择背景视频"
        view.backgroundColor = .systemBackground

        let layout = UICollectionViewFlowLayout()
        let side = (view.bounds.width - 12 * 5) / 4
        layout.itemSize = CGSize(width: side, height: side)
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 12
        layout.sectionInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .systemBackground
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(RelaxinPhotoCell.self, forCellWithReuseIdentifier: "cell")
        view.addSubview(collectionView)

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(cancelTapped)
        )

        loadAssets()
    }

    private func loadAssets() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            fetchAssets()
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] newStatus in
                DispatchQueue.main.async {
                    if newStatus == .authorized || newStatus == .limited {
                        self?.fetchAssets()
                    } else {
                        self?.showPermissionDenied()
                    }
                }
            }
        default:
            showPermissionDenied()
        }
    }

    private func fetchAssets() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 500
        switch mode {
        case .image:
            assets = PHAsset.fetchAssets(with: .image, options: options)
        case .video:
            assets = PHAsset.fetchAssets(with: .video, options: options)
        }
        collectionView.reloadData()
    }

    private func showPermissionDenied() {
        let label = UILabel()
        label.text = "没有相册访问权限，请在系统设置中允许访问照片"
        label.textAlignment = .center
        label.numberOfLines = 0
        label.textColor = .secondaryLabel
        label.font = .systemFont(ofSize: 15)
        label.frame = view.bounds.insetBy(dx: 40, dy: 200)
        view.addSubview(label)
    }

    @objc private func cancelTapped() {
        dismiss(animated: true) { [weak self] in
            self?.onCancel()
        }
    }
}

extension RelaxinPhotoPickerController: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(
        _ collectionView: UICollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        assets.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: "cell",
            for: indexPath
        ) as? RelaxinPhotoCell else {
            return UICollectionViewCell()
        }
        let asset = assets.object(at: indexPath.item)
        let key = asset.localIdentifier
        if let cached = thumbnailCache[key] {
            cell.imageView.image = cached
        } else {
            let side = (view.bounds.width - 12 * 5) / 4
            let targetSize = CGSize(width: side * 2, height: side * 2)
            imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: nil
            ) { [weak self] image, _ in
                guard let self, let image else { return }
                self.thumbnailCache[key] = image
                if let visible = collectionView.indexPathsForVisibleItems
                    .first(where: { $0 == indexPath }) {
                    collectionView.reloadItems(at: [visible])
                }
            }
            cell.imageView.image = nil
        }

        if mode == .video {
            cell.durationLabel.text = Self.durationText(asset.duration)
        }
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        didSelectItemAt indexPath: IndexPath
    ) {
        collectionView.deselectItem(at: indexPath, animated: true)
        let asset = assets.object(at: indexPath.item)
        pick(asset)
    }

    private func pick(_ asset: PHAsset) {
        switch mode {
        case .image:
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isSynchronous = false
            imageManager.requestImageDataAndOrientation(for: asset, options: options) {
                [weak self] data, _, _, _ in
                guard let self, let data else { return }
                self.finish(with: data, ext: "jpg")
            }
        case .video:
            let options = PHVideoRequestOptions()
            options.deliveryMode = .highQualityFormat
            imageManager.requestAVAsset(
                forVideo: asset,
                options: options
            ) {
                [weak self] avAsset, _, _ in
                guard let self, let urlAsset = avAsset as? AVURLAsset else { return }
                // Copy the video into our storage directly from its URL.
                DispatchQueue.main.async {
                    self.installVideo(urlAsset.url)
                }
            }
        }
    }

    private func finish(with data: Data, ext: String) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("relaxin-bg-\(UUID().uuidString).\(ext)")
        do {
            try data.write(to: url)
        } catch {
            return
        }
        dismiss(animated: true) { [weak self] in
            self?.onPick(url)
        }
    }

    private func installVideo(_ sourceURL: URL) {
        let ext = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("relaxin-bg-\(UUID().uuidString).\(ext)")
        do {
            try FileManager.default.copyItem(at: sourceURL, to: dest)
        } catch {
            return
        }
        dismiss(animated: true) { [weak self] in
            self?.onPick(dest)
        }
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        let total = Int(duration)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private final class RelaxinPhotoCell: UICollectionViewCell {
    let imageView = UIImageView()
    let durationLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 8
        contentView.addSubview(imageView)

        durationLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        durationLabel.textColor = .white
        durationLabel.textAlignment = .right
        durationLabel.layer.shadowColor = UIColor.black.cgColor
        durationLabel.layer.shadowOpacity = 0.8
        durationLabel.layer.shadowRadius = 1
        durationLabel.layer.shadowOffset = CGSize(width: 0, height: 1)
        contentView.addSubview(durationLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        durationLabel.frame = CGRect(x: 4, y: bounds.height - 18, width: bounds.width - 8, height: 14)
    }
}
