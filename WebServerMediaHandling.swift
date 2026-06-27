import AVFoundation
import AppKit
import Darwin
import Foundation
import MediaServerKit
import Swifter

enum ThumbQuality { case high, low }

extension WebServerManager {
    func serveFile(at url: URL, request: HttpRequest) -> HttpResponse {
        do {
            let attr = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attr[.size] as? UInt64 else { return .internalServerError }
            let mime = MimeType.forPath(url.path)
            
            if let rangeHeader = request.headers["range"], let range = RangeHeader.parse(rangeHeader, totalSize: size) {
                let (start, end) = range
                let length = end - start + 1
                return .raw(206, "Partial Content", [
                    "Content-Type": mime, "Content-Length": String(length),
                    "Content-Range": "bytes \(start)-\(end)/\(size)", "Accept-Ranges": "bytes"
                ], { writer in
                    guard let file = try? FileHandle(forReadingFrom: url) else { return }
                    defer { file.closeFile() }
                    try? file.seek(toOffset: start)
                    var remaining = length
                    let chunkSize = 512 * 1024
                    while remaining > 0 {
                        let toRead = Int(min(UInt64(chunkSize), remaining))
                        let data = file.readData(ofLength: toRead)
                        if data.isEmpty { break }
                        do {
                            try writer.write(data)
                            remaining -= UInt64(data.count)
                        } catch {
                            break
                        }
                    }
                })
            } else {
                let file = try FileHandle(forReadingFrom: url)
                return .raw(200, "OK", [
                    "Content-Type": mime,
                    "Content-Length": String(size),
                    "Accept-Ranges": "bytes"
                ], { writer in
                    defer { file.closeFile() }
                    let chunkSize = 512 * 1024
                    while true {
                        let chunk = file.readData(ofLength: chunkSize)
                        if chunk.isEmpty { break }
                        try? writer.write(chunk)
                    }
                })
            }
        } catch {
            return .internalServerError
        }
    }

    func getIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                defer { ptr = ptr?.pointee.ifa_next }
                guard let interface = ptr?.pointee else { continue }
                let addrFamily = interface.ifa_addr.pointee.sa_family
                if addrFamily == UInt8(AF_INET) {
                    guard let name = interface.ifa_name, let cStringName = String(cString: name, encoding: .utf8) else { continue }
                    if cStringName.starts(with: "en") {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST)
                        let ip = String(cString: hostname)
                        if !ip.isEmpty {
                            address = ip
                            break
                        }
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        return address
    }
    
    func generateThumbnailData(for url: URL, type: MediaType, quality: ThumbQuality, isOriginal: Bool = false, requestedTime: Double? = nil) async -> Data? {
        let size: CGSize = quality == .high ? CGSize(width: 400, height: 400) : CGSize(width: 50, height: 50)
        let compression = quality == .high ? 0.8 : 0.1
        
        if type == .photo {
            return generateImageThumbnail(url: url, targetSize: size, compression: compression, isOriginal: isOriginal)
        } else {
            return await generateVideoThumbnail(url: url, targetSize: size, compression: compression, isOriginal: isOriginal, requestedTime: requestedTime)
        }
    }
    
    private func generateImageThumbnail(url: URL, targetSize: CGSize, compression: Double, isOriginal: Bool) -> Data? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: max(targetSize.width, targetSize.height),
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else { return nil }
        let nsImage = NSImage(cgImage: cgImage, size: .zero)
        return isOriginal ? resizeToFit(nsImage: nsImage, maxSize: targetSize, compression: compression) : cropAndResize(nsImage: nsImage, targetSize: targetSize, compression: compression)
    }

    private func generateVideoThumbnail(url: URL, targetSize: CGSize, compression: Double, isOriginal: Bool, requestedTime: Double?) async -> Data? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        
        var bestCGImage: CGImage? = nil
        var fallbackImage: CGImage? = nil
        
        if let requestedTime = requestedTime, requestedTime >= 0, requestedTime <= duration {
            let time = CMTime(seconds: requestedTime, preferredTimescale: 600)
            if let cgImage = try? await generator.image(at: time).image {
                bestCGImage = cgImage
            }
        } else {
            var attempts: [Double] = [1.0, 3.0, 5.0, 10.0, 20.0, 30.0, 60.0]
            
            if duration < 5 {
                attempts.insert(0.0, at: 0)
            }
            
            let validAttempts = attempts.filter { $0 < duration }
            
            for seconds in validAttempts {
                let time = CMTime(seconds: seconds, preferredTimescale: 600)
                if let cgImage = try? await generator.image(at: time).image {
                    if fallbackImage == nil { fallbackImage = cgImage }
                    
                    if !isImagePredominantlyBlack(image: cgImage) {
                        bestCGImage = cgImage
                        break
                    }
                }
            }
        }
        
        if let cgImage = bestCGImage ?? fallbackImage {
            let nsImage = NSImage(cgImage: cgImage, size: .zero)
            return isOriginal ? resizeToFit(nsImage: nsImage, maxSize: targetSize, compression: compression) : cropAndResize(nsImage: nsImage, targetSize: targetSize, compression: compression)
        }
        return nil
    }
    
    private func cropAndResize(nsImage: NSImage, targetSize: CGSize, compression: Double) -> Data? {
        let newImage = NSImage(size: targetSize)
        newImage.lockFocus()
        let originalSize = nsImage.size
        let dim = min(originalSize.width, originalSize.height)
        let x = (originalSize.width - dim) / 2
        let y = (originalSize.height - dim) / 2
        let cropRect = CGRect(x: x, y: y, width: dim, height: dim)
        nsImage.draw(in: CGRect(origin: .zero, size: targetSize), from: cropRect, operation: .copy, fraction: 1.0)
        newImage.unlockFocus()
        
        guard let tiff = newImage.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: compression])
    }
    
    private func resizeToFit(nsImage: NSImage, maxSize: CGSize, compression: Double) -> Data? {
        let originalSize = nsImage.size
        let ratio = min(maxSize.width / originalSize.width, maxSize.height / originalSize.height)
        let targetSize = CGSize(width: originalSize.width * ratio, height: originalSize.height * ratio)
        
        let newImage = NSImage(size: targetSize)
        newImage.lockFocus()
        nsImage.draw(in: CGRect(origin: .zero, size: targetSize), from: CGRect(origin: .zero, size: originalSize), operation: .copy, fraction: 1.0)
        newImage.unlockFocus()
        
        guard let tiff = newImage.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: compression])
    }
    
    var placeholderData: Data {
        let img = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)!
        return img.tiffRepresentation!
    }
}
