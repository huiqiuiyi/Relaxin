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
    private var pendingRequests: [IndexPath: PHImageRequestID] = [:]
    private let imageManager = PHCachingImageManager()
    private var thumbnailSize = CGSize(width: 200, height: 200)

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
        thumbnailSize = CGSize(width: side * UIScreen.main.scale, height: side * UIScreen.main.scale)

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .systemBackground
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
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

extension RelaxinPhotoPickerController:
    UICollectionViewDataSource,
    UICollectionViewDelegate,
    UICollectionViewDataSourcePrefetching
{
    func collectionView(
        _ collectionView: UICollectionView,
        prefetchItemsAt indexPaths: [IndexPath]
    ) {
        // 预取即将进入视口的缩略图，滚动更流畅
        let assetsToPrefetch = indexPaths
            .filter { $0.item < assets.count && thumbnailCache[assets.object(at: $0.item).localIdentifier] == nil }
            .map { assets.object(at: $0.item) }
        guard !assetsToPrefetch.isEmpty else { return }
        imageManager.startCachingImages(
            for: assetsToPrefetch,
            targetSize: thumbnailSize,
            contentMode: .aspectFill,
            options: nil
        )
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cancelPrefetchingForItemsAt indexPaths: [IndexPath]
    ) {
        let assetsToCancel = indexPaths
            .filter { $0.item < assets.count }
            .map { assets.object(at: $0.item) }
        guard !assetsToCancel.isEmpty else { return }
        imageManager.stopCachingImages(
            for: assetsToCancel,
            targetSize: thumbnailSize,
            contentMode: .aspectFill,
            options: nil
        )
    }

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

        // 取消该 cell 之前的未完成请求，避免滚动时错乱
        if let previous = pendingRequests[indexPath] {
            imageManager.cancelImageRequest(previous)
            pendingRequests[indexPath] = nil
        }

        if let cached = thumbnailCache[key] {
            cell.imageView.image = cached
        } else {
            cell.imageView.image = nil
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic // 先出小图/模糊图，滚动不卡
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            let requestID = imageManager.requestImage(
                for: asset,
                targetSize: thumbnailSize,
                contentMode: .aspectFill,
                options: options
            ) { [weak self] image, info in
                guard let self, let image,
                      let degraded = info?[PHImageResultIsDegradedKey] as? Bool,
                      !degraded
                else {
                    return
                }
                self.thumbnailCache[key] = image
                self.pendingRequests[indexPath] = nil
                DispatchQueue.main.async {
                    if let visible = collectionView.indexPathsForVisibleItems
                        .first(where: { $0 == indexPath }) {
                        collectionView.reloadItems(at: [visible])
                    }
                }
            }
            pendingRequests[indexPath] = requestID
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
        // 显示加载指示，防止重复点击
        let loading = UIActivityIndicatorView(style: .medium)
        loading.center = view.center
        view.addSubview(loading)
        loading.startAnimating()
        view.isUserInteractionEnabled = false

        switch mode {
        case .image:
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isSynchronous = false
            options.isNetworkAccessAllowed = true
            imageManager.requestImageDataAndOrientation(for: asset, options: options) {
                [weak self] data, _, _, _ in
                DispatchQueue.main.async {
                    guard let self, let data else {
                        self?.stopLoading(loading)
                        return
                    }
                    self.finish(with: data, ext: "jpg", loading: loading)
                }
            }
        case .video:
            let options = PHVideoRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            imageManager.requestAVAsset(
                forVideo: asset,
                options: options
            ) {
                [weak self] avAsset, _, _ in
                DispatchQueue.main.async {
                    guard let self, let urlAsset = avAsset as? AVURLAsset else {
                        self?.stopLoading(loading)
                        return
                    }
                    // Copy the video into our storage directly from its URL.
                    self.installVideo(urlAsset.url, loading: loading)
                }
            }
        }
    }

    private func stopLoading(_ loading: UIActivityIndicatorView) {
        loading.stopAnimating()
        loading.removeFromSuperview()
        view.isUserInteractionEnabled = true
    }

    private func finish(with data: Data, ext: String, loading: UIActivityIndicatorView) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("relaxin-bg-\(UUID().uuidString).\(ext)")
        do {
            try data.write(to: url)
        } catch {
            stopLoading(loading)
            return
        }
        stopLoading(loading)
        dismiss(animated: true) { [weak self] in
            self?.onPick(url)
        }
    }

    private func installVideo(_ sourceURL: URL, loading: UIActivityIndicatorView) {
        let ext = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("relaxin-bg-\(UUID().uuidString).\(ext)")
        do {
            try FileManager.default.copyItem(at: sourceURL, to: dest)
        } catch {
            stopLoading(loading)
            return
        }
        stopLoading(loading)
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
