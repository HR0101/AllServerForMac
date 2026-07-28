import CoreGraphics
import Foundation
import ImageIO

// MARK: - ラフ画・線画の自動判別
//
// 完成した着色イラストと、下描き（ラフ画）や線画を、画素の色調だけで見分ける。
// 学習モデルは使わず、次の3点の組み合わせで判断する。
//
//   1. 色が乗っていない  … 線画・ラフ画はほぼ白黒。着色済みは彩度のある画素が広く占める。
//   2. 白地が広い        … 紙・キャンバスの余白。着色済みは画面全体が塗られる。
//   3. 線や擦れが妥当量  … 真っ白／真っ黒なだけの画像を拾わないための下限・上限。
//
// 判定は `judge(_:)` という純粋関数に閉じてあるので、閾値を調整するときはそこだけ見ればよい。

/// 画像1枚から取り出す色調の特徴。判定は画像そのものではなくこの値だけを見る。
struct ImageToneProfile: Equatable {
    /// 紙の白（明るくて彩度がない）画素の割合。
    /// 「描かれている量」はこの裏返し（1 - whiteRatio）で見る。
    /// 黒い線と中間調だけを数えると、青ペンの下描きのように色のついた線が
    /// 「色」に分類されて描き込みとして数えられず、まるごと取りこぼす。
    var whiteRatio: Double
    /// はっきり色が乗っている画素の割合
    var coloredRatio: Double
    /// 全画素の平均彩度
    var meanSaturation: Double
    /// 色相のばらつき（0＝ほぼ単色、1＝色とりどり）
    var hueSpread: Double
    /// 走査線1本を横切る間に線に入る回数の平均。
    /// きれいな線画は輪郭を数回またぐだけだが、当たりを取ったラフ画は
    /// 同じ場所に何本も線が重なるので、この値がはっきり大きくなる。
    var strokeCrossings: Double
    /// 横切った線のうち、2px 以下しかない極細のものの割合。
    /// スクリーントーンの網点は 1〜2px の点が並ぶだけなのでほぼ 1 になる。
    /// 網点を「線がたくさん重なっている」と誤認しないための歯止め。
    var tinyRunRatio: Double
}

/// 見つかったものの種類。
enum SketchKind: String {
    case lineArt
    case roughSketch

    var displayName: String {
        switch self {
        case .lineArt: return "線画"
        case .roughSketch: return "ラフ画"
        }
    }
}

struct SketchJudgement: Equatable {
    /// 0〜1。1に近いほど「ラフ画・線画らしい」。
    var score: Double
    /// 種類。score が低いときも参考値として入る。
    var kind: SketchKind
    /// 0〜1。線がどれだけ乱雑に重なっているか。ラフ画かどうかはこの値で決める。
    var roughness: Double
}

enum SketchDetector {
    // MARK: 判定（純粋関数）

    /// 色が乗っている画素がこの割合を超えたら、もう着色済みとみなす。
    private static let colorLimit = 0.16
    /// 白い余白の広さ。この下では余白なし、この上なら余白十分。
    private static let paperRamp = 0.15...0.55
    /// 描き込み量の下限側。これを下回るとほぼ白紙。
    private static let marksLowerRamp = 0.010...0.030
    /// 描き込み量の上限側。これを超えると全面塗り／写真。
    private static let marksUpperRamp = 0.55...0.80
    /// この色相のばらつきまでは「単色で描かれている」とみなす（青鉛筆の下描きなど）。
    private static let singleHueSpread = 0.34
    /// 単色と判断できたとき、色が乗っている量をどれだけ割り引くか。
    /// 青ペンの下描きは画面の1〜2割が青くなるが、それは「着色」ではなく線そのもの。
    private static let singleHueDiscount = 0.85
    /// 線の重なり具合。走査線あたりこの回数を超えて線をまたぐと「重なっている」とみなす。
    private static let crossingRamp = 2.5...7.0
    /// 極細の横切りがこの割合を超えたら、線の重なりではなく網点とみなして打ち消す。
    private static let screentoneRamp = 0.65...0.90
    /// これ以上の乱雑さならラフ画とする。
    private static let roughnessThreshold = 0.5

    /// 色調の特徴から「ラフ画・線画らしさ」を求める。
    ///
    /// 各条件は加点ではなく掛け算にしている。加点方式だと、条件を1つも満たさない
    /// 真っ白・真っ黒な画像やモノクロ写真が「色が無い」という理由だけで高得点を取ってしまう。
    /// 掛け算なら、どれか1つでも当てはまらない時点で候補から外れる。
    static func judge(_ profile: ImageToneProfile) -> SketchJudgement {
        // 青鉛筆の下描きのように単一色相で描かれたものは「着色済み」と数えない。
        let hueConcentration = 1 - ramp(profile.hueSpread, from: 0, to: singleHueSpread)
        let effectiveColored = profile.coloredRatio * (1 - hueConcentration * singleHueDiscount)

        // 色が乗っているほど 0 に近づく。着色イラストをここで落とす。
        let monochrome = 1 - clamp01(effectiveColored / colorLimit)
        // 薄く全面着色されている場合に効く。
        let desaturated = 1 - ramp(profile.meanSaturation, from: 0.08, to: 0.30)
        // 白い余白の広さ。全面が埋まった写真やベタ塗りをここで落とす。
        let paper = ramp(profile.whiteRatio, from: paperRamp.lowerBound, to: paperRamp.upperBound)

        // 描き込み量＝白地でない部分。少なすぎれば白紙、多すぎれば全面塗りや写真。
        let marks = 1 - profile.whiteRatio
        let enoughMarks = ramp(marks, from: marksLowerRamp.lowerBound, to: marksLowerRamp.upperBound)
        let notFlooded = 1 - ramp(marks, from: marksUpperRamp.lowerBound, to: marksUpperRamp.upperBound)

        let score = monochrome * desaturated * paper * enoughMarks * notFlooded
        let roughness = roughness(of: profile)

        return SketchJudgement(
            score: clamp01(score),
            kind: roughness >= roughnessThreshold ? .roughSketch : .lineArt,
            roughness: roughness
        )
    }

    /// 線がどれだけ乱雑に重なっているかを 0〜1 で返す。
    ///
    /// 「線をまたぐ回数が多い」だけでは足りない。スクリーントーンの網点も
    /// 走査線を大量にまたぐが、あれは 1〜2px の点が規則的に並んでいるだけでラフ画ではない。
    /// そこで極細の横切りばかりの画像は打ち消し、
    /// ある程度の長さを持つ線が何本も重なっているものだけを高くする。
    private static func roughness(of profile: ImageToneProfile) -> Double {
        let crossings = ramp(profile.strokeCrossings, from: crossingRamp.lowerBound, to: crossingRamp.upperBound)
        let screentone = ramp(profile.tinyRunRatio, from: screentoneRamp.lowerBound, to: screentoneRamp.upperBound)
        return clamp01(crossings * (1 - screentone))
    }

    /// `lower` 以下で 0、`upper` 以上で 1 になる線形の傾斜。
    /// しきい値をきっかり切らずに滑らかに効かせるため、判定の各条件はこれを通す。
    private static func ramp(_ value: Double, from lower: Double, to upper: Double) -> Double {
        guard upper > lower else { return value >= upper ? 1 : 0 }
        return clamp01((value - lower) / (upper - lower))
    }

    private static func clamp01(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    // MARK: 画素統計の抽出

    /// 判定に使う一辺の長さ。
    ///
    /// 色調だけなら 96px でも足りるが、それだと重なった線が潰れて1本に見えてしまい、
    /// ラフ画の「線が何本も重なっている」という特徴が測れない。線の分離が保てる大きさにする。
    private static let analysisSide = 256

    /// 画像ファイルから色調の特徴を読む。読めなければ nil。
    /// ファイルIOと画素走査だけなので、バックグラウンドから並行して呼んでよい。
    nonisolated static func profile(forImageAt url: URL) -> ImageToneProfile? {
        guard let cgImage = downsampledImage(at: url) else { return nil }
        return profile(of: cgImage)
    }

    nonisolated private static func downsampledImage(at url: URL) -> CGImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: analysisSide,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    nonisolated static func profile(of cgImage: CGImage) -> ImageToneProfile? {
        let width = min(cgImage.width, analysisSide)
        let height = min(cgImage.height, analysisSide)
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        let drawn: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            // 透過 PNG の線画は「背景が抜けている」だけで見た目は白地なので、
            // 先に白で塗ってから描く。そうしないと透過部分が黒と数えられてしまう。
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        var whiteCount = 0
        var coloredCount = 0
        var saturationSum = 0.0
        var hueBins = [Int](repeating: 0, count: hueBinCount)

        // 線の重なりを数えるために、画素ごとの「線かどうか」を持っておく。
        var isStroke = [Bool](repeating: false, count: width * height)

        let total = width * height
        for pixel in 0..<total {
            let index = pixel * 4
            let r = Double(pixels[index]) / 255
            let g = Double(pixels[index + 1]) / 255
            let b = Double(pixels[index + 2]) / 255

            let maxC = max(r, g, b)
            let minC = min(r, g, b)
            let saturation = maxC <= 0 ? 0 : (maxC - minC) / maxC
            let luminance = 0.299 * r + 0.587 * g + 0.114 * b
            saturationSum += saturation

            if maxC > 0.88 && saturation < 0.12 {
                whiteCount += 1
            }

            if saturation > 0.25 && maxC > 0.25 {
                coloredCount += 1
                hueBins[hueBin(r: r, g: g, b: b, maxC: maxC, minC: minC)] += 1
            }

            // 薄い当たり線も線として数える（濃い線だけ見るとラフ画を取りこぼす）。
            isStroke[pixel] = luminance < strokeLuminanceThreshold
        }

        let runStats = strokeRunStats(isStroke: isStroke, width: width, height: height)
        let totalDouble = Double(total)
        return ImageToneProfile(
            whiteRatio: Double(whiteCount) / totalDouble,
            coloredRatio: Double(coloredCount) / totalDouble,
            meanSaturation: saturationSum / totalDouble,
            hueSpread: hueSpread(bins: hueBins, coloredCount: coloredCount),
            strokeCrossings: runStats.crossingsPerScanline,
            tinyRunRatio: runStats.tinyRatio
        )
    }

    /// 線とみなす明るさの上限。薄い当たり線も拾えるよう高めに取る。
    private static let strokeLuminanceThreshold = 0.72

    /// 縦横に走査して、線を横切る回数とその長さのばらつきを求める。
    ///
    /// 塗り潰しは1回の長い連続として数えるので、ベタ塗りでは回数が増えない。
    /// 細い線が何本も重なっているときだけ回数が増える。
    nonisolated private static func strokeRunStats(
        isStroke: [Bool], width: Int, height: Int
    ) -> (crossingsPerScanline: Double, tinyRatio: Double) {
        var runLengths: [Int] = []

        func scan(_ length: Int, _ pixelAt: (Int) -> Bool) {
            var current = 0
            for position in 0..<length {
                if pixelAt(position) {
                    current += 1
                } else if current > 0 {
                    runLengths.append(current)
                    current = 0
                }
            }
            if current > 0 { runLengths.append(current) }
        }

        for y in 0..<height {
            scan(width) { isStroke[y * width + $0] }
        }
        for x in 0..<width {
            scan(height) { isStroke[$0 * width + x] }
        }

        let scanlines = width + height
        guard scanlines > 0, runLengths.count > 1 else { return (0, 0) }

        return (
            Double(runLengths.count) / Double(scanlines),
            Double(runLengths.filter { $0 <= tinyRunLength }.count) / Double(runLengths.count)
        )
    }

    /// これ以下の長さしかない横切りは「極細」とみなす（網点1粒ぶん）。
    private static let tinyRunLength = 2

    private static let hueBinCount = 12

    /// 色が乗っている画素のうち、意味のある量を占める色相の種類がいくつあるか（0〜1）。
    /// 単色トーンのラフは低く、色とりどりの完成絵は高くなる。
    private static func hueSpread(bins: [Int], coloredCount: Int) -> Double {
        guard coloredCount > 0 else { return 0 }
        let floorCount = Double(coloredCount) * 0.05
        let usedBins = bins.filter { Double($0) >= floorCount }.count
        return Double(usedBins) / Double(hueBinCount)
    }

    private static func hueBin(r: Double, g: Double, b: Double, maxC: Double, minC: Double) -> Int {
        let delta = maxC - minC
        guard delta > 0 else { return 0 }
        var hue: Double
        if maxC == r {
            hue = (g - b) / delta
        } else if maxC == g {
            hue = 2 + (b - r) / delta
        } else {
            hue = 4 + (r - g) / delta
        }
        hue *= 60
        if hue < 0 { hue += 360 }
        return min(hueBinCount - 1, Int(hue / (360 / Double(hueBinCount))))
    }
}
