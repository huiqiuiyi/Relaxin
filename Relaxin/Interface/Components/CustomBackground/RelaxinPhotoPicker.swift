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

        let completion: (URL?, String?) -> Void = { [weak self] url, errorText in
            DispatchQueue.main.async {
                guard let self else { return }
                loading.stopAnimating()
                loading.removeFromSuperview()
                self.isExporting = false

                guard let url else {
                    self.showAlert("载入失败：\(errorText ?? "未知错误")")
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

    private func exportImage(_ asset: PHAsset, completion: @escaping (URL?, String?) -> Void) {
        // 用 requestImage 拿图并编码为 JPEG。
        // 先按资产真实尺寸要原图；失败（iCloud 未下载 / 内存过大）时逐级降到 2048、1024。
        let widths: [CGFloat] = [0, 2048, 1024] // 0 = 原图尺寸
        requestImageStep(asset, widths: widths, index: 0, completion: completion)
    }

    private func requestImageStep(
        _ asset: PHAsset,
        widths: [CGFloat],
        index: Int,
        completion: @escaping (URL?, String?) -> Void
    ) {
        guard index < widths.count else {
            completion(nil, "图片载入失败，请换一张试试")
            return
        }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isSynchronous = false
        options.isNetworkAccessAllowed = true
        options.resizeMode = .none

        let targetSize: CGSize
        if widths[index] == 0 {
            targetSize = CGSize(
                width: CGFloat(asset.pixelWidth),
                height: CGFloat(asset.pixelHeight)
            )
        } else {
            let w = widths[index]
            let scale = w / CGFloat(max(asset.pixelWidth, 1))
            targetSize = CGSize(
                width: w,
                height: CGFloat(asset.pixelHeight) * scale
            )
        }

        imageManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFit,
            options: options
        ) { [weak self] image, info in
            guard let self else { return }
            guard let image else {
                let cancelled = info?[PHImageCancelledKey] as? Bool == true
                if cancelled {
                    completion(nil, "已取消")
                } else {
                    // 这一级失败，降一级再试
                    self.requestImageStep(asset, widths: widths, index: index + 1, completion: completion)
                }
                return
            }
            guard let data = image.jpegData(compressionQuality: 0.92) else {
                self.requestImageStep(asset, widths: widths, index: index + 1, completion: completion)
                return
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("relaxin-bg-\(UUID().uuidString).jpg")
            do {
                try data.write(to: url)
                completion(url, nil)
            } catch {
                completion(nil, "写入失败：\(error.localizedDescription)")
            }
        }
    }

    private func exportVideo(_ asset: PHAsset, completion: @escaping (URL?, String?) -> Void) {
        // 第一优先：直接拿原始资源文件数据（对本地视频最稳，绕开 AVAsset 转码）
        exportVideoRaw(asset, completion: completion)
    }

    /// 用 PHAssetResourceManager 直接取原始资源数据（本地视频首选）。
    private func exportVideoRaw(_ asset: PHAsset, completion: @escaping (URL?, String?) -> Void) {
        guard let resource = PHAssetResource.assetResources(for: asset).first else {
            exportVideoViaAVAsset(asset, completion: completion)
            return
        }

        let ext = Self.extensionForVideo(resource.originalFilename)
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("relaxin-bg-\(UUID().uuidString).\(ext)")
        let manager = PHAssetResourceManager.default()

        let requestOptions = PHAssetResourceRequestOptions()
        requestOptions.isNetworkAccessAllowed = true

        var data = Data()
        manager.requestData(
            for: resource,
            options: requestOptions,
            dataReceivedHandler: { chunk in
                data.append(chunk)
            },
            completionHandler: { [weak self] error in
                guard let self else { return }
                if let error {
                    // 原始资源拿不到（可能是 iCloud 未下载），退回 AVAsset 转码
                    self.exportVideoViaAVAsset(asset, completion: completion)
                    return
                }
                guard !data.isEmpty else {
                    self.exportVideoViaAVAsset(asset, completion: completion)
                    return
                }
                do {
                    try data.write(to: dest)
                    completion(dest, nil)
                } catch {
                    completion(nil, "视频写入失败：\(error.localizedDescription)")
                }
            }
        )
    }

    private func exportVideoViaAVAsset(_ asset: PHAsset, completion: @escaping (URL?, String?) -> Void) {
        let options = PHVideoRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true

        imageManager.requestAVAsset(
            forVideo: asset,
            options: options
        ) { avAsset, info, _ in
            guard let avAsset else {
                let error = (info?[PHImageErrorKey] as? NSError)?.localizedDescription
                    ?? (info?[PHImageCancelledKey] as? Bool == true ? "已取消" : nil)
                completion(nil, error)
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
                    completion(dest, nil)
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
                completion(nil, "无法创建视频导出器")
                return
            }
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("relaxin-bg-\(UUID().uuidString).mov")
            exportSession.outputURL = dest
            exportSession.outputFileType = .mov
            exportSession.shouldOptimizeForNetworkUse = false
            exportSession.exportAsynchronously {
                if exportSession.status == .completed {
                    completion(dest, nil)
                } else {
                    let msg = exportSession.error?.localizedDescription
                        ?? "导出状态 \(exportSession.status.rawValue)"
                    completion(nil, "视频导出失败：\(msg)")
                }
            }
        }
    }

    private static func extensionForVideo(_ filename: String) -> String {
        let ext = (filename as NSString).pathExtension
        guard !ext.isEmpty else { return "mov" }
        return ext.lowercased()
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
