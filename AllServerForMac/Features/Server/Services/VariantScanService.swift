import Foundation
import MediaServerKit

// MARK: - 差分動画の探索をサーバー側で回す
//
// 実ファイルを持っているのは Mac だけなので、検出は必ずこちら側で行う
// （フレームを時刻ぴったりで何枚も起こす処理を、クライアントに肩代わりさせようがない）。
//
// Swifter のハンドラは同期で、指紋づくりは1本あたり数秒かかる。そこでハンドラの中では
// 「いまわかっていること」だけを即返し、足りないぶんは裏で作る。クライアントは
// `state` が `ready` になるまで繰り返し尋ねる（`/video/:id/prepare` と同じ形）。
//
// 指紋の置き場は Mac の画面側（`VariantVideoViewModel`）と同じなので、
// どちらかで一度作れば、もう一方は待たずに済む。
nonisolated final class VariantScanService: @unchecked Sendable {
    /// 1本ぶんの入力。ハンドラ側（ワーカースレッド）で組み立てて渡す。
    struct Target: Sendable {
        let item: VideoItem
        let url: URL
        let stamp: VariantSignatureStore.Stamp
    }

    /// 一度に並べてフレームを起こす本数。4K を無制限に並べるとメモリが跳ねる。
    private static let concurrency = 3

    private let store: VariantSignatureStore
    private let lock = NSLock()
    private var fingerprints: [UUID: VariantVideoDetector.Fingerprint] = [:]
    /// 走らせている探索。アルバム単位で1本だけにする。
    private var running: Set<UUID> = []
    private var progress: [UUID: (scanned: Int, total: Int)] = [:]

    init(directory: URL) {
        self.store = VariantSignatureStore(directory: directory)
    }

    /// いまわかっている範囲での探索結果を返す。足りなければ裏で作り始める。
    func result(
        albumID: UUID,
        targets: [Target],
        tolerance: TimeInterval,
        maxAverageDistance: Double,
        titleInfluence: Double
    ) -> RemoteVariantScanResult {
        let buckets = VariantVideoDetector.durationBuckets(of: targets.map(\.item), tolerance: tolerance)
        let members = buckets.flatMap { $0 }

        lock.lock()
        let known = fingerprints
        let isRunning = running.contains(albumID)
        let reported = progress[albumID]
        lock.unlock()

        let groups = Self.groups(
            in: buckets,
            fingerprints: known,
            maxAverageDistance: maxAverageDistance,
            titleInfluence: titleInfluence
        )

        let missingIDs = Set(members.map(\.id)).subtracting(known.keys)
        guard !missingIDs.isEmpty else {
            return RemoteVariantScanResult(
                state: RemoteVariantScanResult.readyState,
                scanned: members.count,
                total: members.count,
                groups: groups
            )
        }

        if !isRunning {
            let pending = targets.filter { missingIDs.contains($0.item.id) }
            start(albumID: albumID, pending: pending)
        }
        return RemoteVariantScanResult(
            state: RemoteVariantScanResult.scanningState,
            scanned: reported?.scanned ?? 0,
            total: reported?.total ?? missingIDs.count,
            groups: groups
        )
    }

    private static func groups(
        in buckets: [[VideoItem]],
        fingerprints: [UUID: VariantVideoDetector.Fingerprint],
        maxAverageDistance: Double,
        titleInfluence: Double
    ) -> [RemoteVariantGroup] {
        buckets.flatMap { bucket in
            VariantVideoDetector.groups(
                in: bucket,
                fingerprints: fingerprints,
                maxAverageDistance: maxAverageDistance,
                titleInfluence: titleInfluence
            ).map { items -> RemoteVariantGroup in
                let stats = VariantVideoDetector.stats(for: items, fingerprints: fingerprints)
                return RemoteVariantGroup(
                    // 同じ顔ぶれなら同じ id になるようにしておく。
                    // 画面側が問い合わせのたびに一覧を作り直さずに済む。
                    id: items.map(\.id.uuidString).joined(separator: "-"),
                    duration: items.first?.duration ?? 0,
                    videoIDs: items.map(\.id.uuidString),
                    minFrameDistance: stats?.frameDistance.lowerBound,
                    maxFrameDistance: stats?.frameDistance.upperBound,
                    minTitleSimilarity: stats?.titleSimilarity.lowerBound,
                    maxTitleSimilarity: stats?.titleSimilarity.upperBound
                )
            }
        }
        .sorted { $0.videoIDs.count > $1.videoIDs.count }
    }

    // MARK: - 裏で作る

    private func start(albumID: UUID, pending: [Target]) {
        lock.lock()
        running.insert(albumID)
        progress[albumID] = (scanned: 0, total: pending.count)
        lock.unlock()

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            var done = 0

            // まず置き場から拾う。前に作ったぶんは起こし直さない。
            // ハンドラは同期なのでこの置き場に触れるのは非同期側だけ。つまり最初の問い合わせは
            // 必ず「探索中」で返るが、全部残っていれば次の問い合わせでもう「完了」になる。
            var remaining: [Target] = []
            for target in pending {
                if let cached = await self.store.signature(for: target.item.id, stamp: target.stamp) {
                    self.put(cached, for: target.item)
                    done += 1
                    self.advance(albumID: albumID, scanned: done, total: pending.count)
                } else {
                    remaining.append(target)
                }
            }

            var index = 0
            while index < remaining.count {
                let slice = Array(remaining[index..<min(index + Self.concurrency, remaining.count)])
                index += slice.count

                // まとめて起こすが、進み具合は1本ぶんずつ伝える。
                // 束ごとにしか動かないと、画面のバーが十数秒止まって見える。
                let built = await withTaskGroup(of: (Target, VideoFrameSignature?).self) { group in
                    for target in slice {
                        group.addTask {
                            (target, await VariantFrameSampler.signature(
                                forVideoAt: target.url,
                                duration: target.item.duration
                            ))
                        }
                    }
                    var collected: [(Target, VideoFrameSignature?)] = []
                    for await entry in group {
                        collected.append(entry)
                        done += 1
                        self.advance(albumID: albumID, scanned: done, total: pending.count)
                    }
                    return collected
                }

                for (target, signature) in built {
                    guard let signature else { continue }
                    await self.store.store(signature, for: target.item.id, stamp: target.stamp)
                    self.put(signature, for: target.item)
                }
            }
            await self.store.save()
            self.finish(albumID: albumID)
        }
    }

    private func put(_ signature: VideoFrameSignature, for item: VideoItem) {
        lock.withLock {
            fingerprints[item.id] = VariantVideoDetector.Fingerprint(
                signature: signature,
                filename: item.originalFilename
            )
        }
    }

    private func advance(albumID: UUID, scanned: Int, total: Int) {
        lock.withLock { progress[albumID] = (scanned: min(scanned, total), total: total) }
    }

    private func finish(albumID: UUID) {
        lock.withLock {
            running.remove(albumID)
            progress[albumID] = nil
        }
    }
}
