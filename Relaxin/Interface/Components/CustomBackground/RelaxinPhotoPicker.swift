import AVFoundation
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
    private let imageManager = PHImageManager.default()
    private var thumbnailSize = CGSize(width: 200, height: 200)
    private var isExporting = false

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
        let side = max(60, (view.bounds.width - 12 * 5) / 4)
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
        collectionView.register(RelaxinPhotoCell.self, forCellWithReuseIdentifier: "cell")
        view.addSubview(collectionView)

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(cancelTapped)
        )

        loadAssets()
    }

    // MARK: - Permission & fetch

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

    private func showAlert(_ message: String) {
        let alert = UIAlertController(
            title: "提示",
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - Collection

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
        cell.imageView.image = nil
        cell.durationLabel.text = mode == .video
            ? Self.durationText(asset.duration)
            : nil

        // 直接在 cell 上设置缩略图，不 reload（避免索引错乱/闪烁）
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat // 直接要清晰缩略图，不要模糊过渡图
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        imageManager.requestImage(
            for: asset,
            targetSize: thumbnailSize,
            contentMode: .aspectFill,
            options: options
        ) { [weak cell] image, _ in
            guard let cell, let image else { return }
            DispatchQueue.main.async {
                // cell 复用后可能已经换 asset，只有图片还在这个 cell 时才设置
                cell.imageView.image = image
            }
        }
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        didSelectItemAt indexPath: IndexPath
    ) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard !isExporting else { return }
        let asset = assets.object(at: indexPath.item)
        pick(asset)
    }

    // MARK: - Pick & export

    private func pick(_ asset: PHAsset) {
        isExporting = true

        let loading = UIActivityIndicatorView(style: .large)
        loading.center = view.center
        loading.color = .secondaryLabel
        view.addSubview(loading)
        loading.startAnimating()

        let completion: (URL?) -> Void = { [weak self] url in
            DispatchQueue.main.async {
                guard let self else { return }
                loading.stopAnimating()
                loading.removeFromSuperview()
                self.isExporting = false

                guard let url else {
                    self.showAlert("无法载入这个项目，请换一个试试")
                    return
                }
                self.dismiss(animated: true) {
                    self.onPick(url)
                }
            }
        }

        switch mode {
        case .image:
            exportImage(asset, completion: completion)
        case .video:
            exportVideo(asset, completion: completion)
        }
    }

    private func exportImage(_ asset: PHAsset, completion: @escaping (URL?) -> Void) {
        // 异步拿原始数据（后台线程回调），按真实 UTI 给扩展名。
        // 不转码、不改尺寸：原样保存，UIImage 原生支持 HEIC/PNG/JPEG。
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isSynchronous = false
        options.isNetworkAccessAllowed = true
        options.resizeMode = .none

        imageManager.requestImageDataAndOrientation(
            for: asset,
            options: options
        ) { data, dataUTI, _, _ in
            guard let data, !data.isEmpty else {
                completion(nil)
                return
            }
            let ext = Self.fileExtension(for: dataUTI)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("relaxin-bg-\(UUID().uuidString).\(ext)")
            do {
                try data.write(to: url)
                completion(url)
            } catch {
                completion(nil)
            }
        }
    }

    /// Maps a photo UTI to a file extension UIImage can decode.
    private static func fileExtension(for dataUTI: String?) -> String {
        switch dataUTI {
        case "public.heic", "public.heif":
            "heic"
        case "public.png":
            "png"
        case "public.jpeg", "public.jpg":
            "jpg"
        case "public.gif":
            "gif"
        default:
            "jpg"
        }
    }

    private func exportVideo(_ asset: PHAsset, completion: @escaping (URL?) -> Void) {
        let options = PHVideoRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true

        imageManager.requestAVAsset(
            forVideo: asset,
            options: options
        ) { avAsset, _, _ in
            guard let avAsset else {
                completion(nil)
                return
            }

            // 优先直接复制（本地视频），失败则用 AVAssetExportSession 转码导出
            if let urlAsset = avAsset as? AVURLAsset,
               FileManager.default.fileExists(atPath: urlAsset.url.path) {
                let ext = urlAsset.url.pathExtension.isEmpty ? "mov" : urlAsset.url.pathExtension
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent("relaxin-bg-\(UUID().uuidString).\(ext)")
                do {
                    try FileManager.default.copyItem(at: urlAsset.url, to: dest)
                    completion(dest)
                    return
                } catch {
                    // 复制失败，继续走转码
                }
            }

            // 转码导出到我们自己的临时文件（兼容 iCloud / 混合格式）
            guard let exportSession = AVAssetExportSession(
                asset: avAsset,
                presetName: AVAssetExportPresetHighestQuality
            ) else {
                completion(nil)
                return
            }
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("relaxin-bg-\(UUID().uuidString).mov")
            exportSession.outputURL = dest
            exportSession.outputFileType = .mov
            exportSession.shouldOptimizeForNetworkUse = false
            exportSession.exportAsynchronously {
                if exportSession.status == .completed {
                    completion(dest)
                } else {
                    completion(nil)
                }
            }
        }
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        let total = Int(duration)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Cell

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

    override func prepareForReuse() {
        super.prepareForReuse()
        imageView.image = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        durationLabel.frame = CGRect(x: 4, y: bounds.height - 18, width: bounds.width - 8, height: 14)
    }
}
