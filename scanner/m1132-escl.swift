// SPDX-License-Identifier: GPL-2.0-or-later
//
// m1132-escl - eSCL (AirScan) scanner service for the USB-attached
// HP LaserJet Professional M1132 MFP. Native arm64, Apple frameworks only.
//
// It drives the scanner over USB and publishes it on this Mac as an eSCL
// scanner (_uscan._tcp), so NAPS2 (ESCL or Apple driver), Image Capture and
// Preview can use it without HP's Intel-only scanner module.
//
// USB protocol: "PROTOCOL.md" of https://github.com/F1f0mp4/m1132-scan
// (Filip Tarcala, MIT), derived from HP's macOS driver. This is an independent
// implementation of that description.
//
//   m1132-escl [--port N] [--allow-lan]
//
// Build: swiftc -O -framework IOUSBHost -o m1132-escl m1132-escl.swift

import CoreGraphics
import Foundation
import IOKit
import IOUSBHost
import ImageIO
import Network

// MARK: - Constants

let usbVendor = 0x03F0, usbProduct = 0x042A
let magic: UInt32 = 0x4153_5001             // "ASP\x01"
let glassRight: UInt32 = 850                 // 1/100 inch, glass is 8.50 x 11.22 in
let glassBottom: UInt32 = 1122
let resolutions: [UInt32] = [150, 300, 600]  // 1200 dpi is untested on the device
let makeAndModel = "HP LaserJet Professional M1132 MFP"
let serviceName = "HP LaserJet M1132 MFP (native)"
let scannerUUID = "4d313133-3200-4e61-7469-766561726d36"

func log(_ s: String) {
    let t = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write("\(t) \(s)\n".data(using: .utf8)!)
}

struct ScanError: Error, CustomStringConvertible { let description: String }

func be32(_ d: Data, _ off: Int) -> UInt32 {
    var v: UInt32 = 0
    for i in 0..<4 { v = v << 8 | UInt32(d[d.startIndex + off + i]) }
    return v
}

func appendBE32(_ d: inout Data, _ v: UInt32) {
    withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) }
}

/// 32-byte message header: magic, id, param1, param2, status, length, 0, 0.
func message(_ id: UInt32, length: UInt32 = 0) -> Data {
    var d = Data()
    for v in [magic, id, 0, 0, 0, length, 0, 0] { appendBE32(&d, v) }
    return d
}

// MARK: - USB transport

final class USBScanner {
    let iface: IOUSBHostInterface
    let pipeOut: IOUSBHostPipe
    let pipeIn: IOUSBHostPipe
    var buffered = Data()   // the IN pipe is a byte stream, keep surplus bytes

    init() throws {
        // The scan interface is the vendor-specific one (class/subclass/protocol FF/FF/FF).
        let match = IOUSBHostInterface.__createMatchingDictionary(
            withVendorID: NSNumber(value: usbVendor), productID: NSNumber(value: usbProduct),
            bcdDevice: nil, interfaceNumber: nil, configurationValue: nil,
            interfaceClass: 0xFF, interfaceSubclass: 0xFF, interfaceProtocol: 0xFF,
            speed: nil, productIDArray: nil).takeRetainedValue()
        let service = IOServiceGetMatchingService(kIOMainPortDefault, match)
        guard service != 0 else { throw ScanError(description: "scanner not found (printer off or unplugged?)") }
        defer { IOObjectRelease(service) }
        iface = try IOUSBHostInterface(__ioService: service, options: [], queue: nil, interestHandler: nil)

        // First bulk OUT and bulk IN endpoint of this interface (alternate setting 0).
        let number = iface.interfaceDescriptor.pointee.bInterfaceNumber
        let config = UnsafeRawPointer(iface.configurationDescriptor)
        let total = Int(iface.configurationDescriptor.pointee.wTotalLength)
        var off = 0, inInterface = false
        var outAddr: UInt8?, inAddr: UInt8?
        while off + 2 <= total {
            let len = Int(config.load(fromByteOffset: off, as: UInt8.self))
            let type = config.load(fromByteOffset: off + 1, as: UInt8.self)
            guard len >= 2 else { break }
            if type == 4 && len >= 4 {          // interface descriptor
                inInterface = config.load(fromByteOffset: off + 2, as: UInt8.self) == number
                    && config.load(fromByteOffset: off + 3, as: UInt8.self) == 0
            } else if type == 5 && len >= 4 && inInterface {   // endpoint descriptor
                let addr = config.load(fromByteOffset: off + 2, as: UInt8.self)
                if config.load(fromByteOffset: off + 3, as: UInt8.self) & 3 == 2 {   // bulk
                    if addr & 0x80 == 0 { outAddr = outAddr ?? addr } else { inAddr = inAddr ?? addr }
                }
            }
            off += len
        }
        guard let o = outAddr, let i = inAddr else { throw ScanError(description: "no bulk endpoints on the scan interface") }
        pipeOut = try iface.copyPipe(withAddress: Int(o))
        pipeIn = try iface.copyPipe(withAddress: Int(i))
    }

    deinit { iface.destroy() }

    func send(_ d: Data) throws {
        var n = 0
        try pipeOut.__sendIORequest(with: NSMutableData(data: d), bytesTransferred: &n, completionTimeout: 5)
        guard n == d.count else { throw ScanError(description: "short USB write \(n)/\(d.count)") }
    }

    /// One bulk IN transfer, nil on timeout.
    private func transfer(timeout: TimeInterval) throws -> Data? {
        let buf = NSMutableData(length: 65536)!
        var n = 0
        do {
            try pipeIn.__sendIORequest(with: buf, bytesTransferred: &n, completionTimeout: timeout)
        } catch let e as NSError where e.code == Int(kIOReturnTimeout) || e.code == Int(kIOReturnAborted) {
            return nil
        }
        return Data(bytes: buf.bytes, count: n)
    }

    func read(_ count: Int, timeout: TimeInterval = 60) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while buffered.count < count {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { throw ScanError(description: "scanner timeout") }
            if let c = try transfer(timeout: left) { buffered.append(c) }
        }
        let out = Data(buffered.prefix(count))
        buffered.removeFirst(count)
        return out
    }

    /// Discard whatever arrives within `timeout`.
    func drain(timeout: TimeInterval) throws {
        buffered.removeAll()
        let deadline = Date().addingTimeInterval(timeout)
        while deadline.timeIntervalSinceNow > 0, try transfer(timeout: deadline.timeIntervalSinceNow) != nil {}
    }

    /// Send a command and read its 32-byte reply; returns (status, payload length).
    func command(_ id: UInt32, payload: Data = Data()) throws -> (status: UInt32, length: UInt32) {
        var d = message(id, length: UInt32(payload.count))
        d.append(payload)
        try send(d)
        let r = try read(32, timeout: 10)
        guard be32(r, 0) == magic, be32(r, 4) == id else { throw ScanError(description: "bad reply to command 0x\(String(id, radix: 16))") }
        return (be32(r, 16), be32(r, 20))
    }
}

// MARK: - Scan engine

enum ColorMode: String { case rgb = "RGB24", gray = "Grayscale8", bw = "BlackAndWhite1" }

struct ScanParams {
    var dpi: UInt32 = 300
    var mode = ColorMode.rgb
    var left: UInt32 = 0, top: UInt32 = 0             // 1/100 inch from the glass corner
    var width = glassRight, height = glassBottom
}

struct RawImage { var width: Int, height: Int, channels: Int, dpi: Int, pixels: Data }

final class CancelToken { var cancelled = false }


/// One flatbed scan. Session order as HP's driver: lock, reset defaults, read
/// back, edit resolution/window/colour, write, start, read the packet stream.
func scan(_ p: ScanParams, cancel: CancelToken) throws -> RawImage {
    let s = try USBScanner()

    try s.send(message(0x15))                        // fire-and-forget before the lock
    try s.drain(timeout: 1)
    var locked = false
    for _ in 0..<30 {
        if try s.command(0x00).status == 0 { locked = true; break }
        Thread.sleep(forTimeInterval: 1)
    }
    guard locked else { throw ScanError(description: "scanner busy (lock refused)") }
    defer { _ = try? s.command(0x01) }               // unlock

    guard try s.command(0x08).status == 0 else { throw ScanError(description: "default settings refused") }
    let g = try s.command(0x06)
    guard g.status == 0, g.length == 100 else { throw ScanError(description: "cannot read settings") }
    let block = try s.read(100)
    var v = (0..<25).map { be32(block, $0 * 4) }

    // Fields: 3 resolution, 16-19 window top/left/bottom/right, 20-23 scannable
    // area, 24 colour type (1 colour, 0 grey; black & white is grey + threshold).
    // The firmware overstates the glass length, so clamp to the real glass.
    let maxRight = min(v[23], glassRight), maxBottom = min(v[22], glassBottom)
    v[3] = p.dpi
    v[17] = min(v[21] + p.left, maxRight - 1)
    v[16] = min(v[20] + p.top, maxBottom - 1)
    v[19] = min(v[17] + max(p.width, 1), maxRight)
    v[18] = min(v[16] + max(p.height, 1), maxBottom)
    v[24] = p.mode == .rgb ? 1 : 0
    var newBlock = Data()
    for x in v { appendBE32(&newBlock, x) }
    guard try s.command(0x07, payload: newBlock).status == 0 else { throw ScanError(description: "scan settings refused") }

    let channels = p.mode == .rgb ? 3 : 1
    var width = Int(v[19] - v[17]) * Int(p.dpi) / 100
    let rows = Int(v[18] - v[16]) * Int(p.dpi) / 100
    var pixels = Data(capacity: width * rows * channels)
    var carry = Data()

    guard try s.command(0x02).status == 0 else { throw ScanError(description: "scan start refused") }
    var open = true, cancelSent = false
    defer {
        if open {                                     // error mid-scan: stop the head
            try? s.send(message(0x03))
            try? s.drain(timeout: 5)
        }
    }

    while true {
        if cancel.cancelled && !cancelSent {
            try s.send(message(0x03))
            cancelSent = true
        }
        let h = try s.read(32, timeout: 60)
        guard be32(h, 0) == magic else { throw ScanError(description: "lost sync with the scanner") }
        let id = be32(h, 4)
        let len = Int(be32(h, 20))
        let body = len > 0 ? try s.read(len, timeout: 60) : Data()

        switch id {
        case 0x05:                                    // image data: 24-byte data header + lines
            let type = be32(body, 0), stride = Int(be32(body, 20))
            guard be32(body, 12) == 1, (type == 10 && channels == 3) || (type == 6 && channels == 1) else {
                throw ScanError(description: "unexpected image data type \(type)")
            }
            if stride < width {                       // firmware rounds rows to 16 px
                guard pixels.isEmpty else { throw ScanError(description: "row width changed mid-scan") }
                width = stride
            }
            carry.append(body.dropFirst(24))
            // Colour rows arrive as R, G, B lines of `stride` bytes; grey as one line.
            let rowBytes = stride * channels
            let whole = carry.count / rowBytes
            var out = [UInt8](repeating: 0, count: whole * width * channels)
            carry.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                for y in 0..<whole {
                    let base = y * rowBytes, dst = y * width * channels
                    for x in 0..<width {
                        for c in 0..<channels { out[dst + x * channels + c] = src[base + c * stride + x] }
                    }
                }
            }
            pixels.append(contentsOf: out)
            carry.removeFirst(whole * rowBytes)
        case 0x18:                                    // e_NewScanPage needs an ack
            try s.send(message(0x18))
        case 0x0C:                                    // e_EndJob
            open = false
            if cancelSent { throw ScanError(description: "cancelled") }
            let got = min(pixels.count / (width * channels), rows)
            pixels.removeSubrange((got * width * channels)...)
            return RawImage(width: width, height: got, channels: channels, dpi: Int(p.dpi), pixels: pixels)
        case 0x04:                                    // e_AbortScanJob
            open = false
            throw ScanError(description: cancelSent ? "cancelled" : "scanner aborted the scan")
        case 0x09, 0x0A, 0x0B, 0x0D, 0x0E:            // job/sheet/page start and end
            break
        default:
            throw ScanError(description: "unexpected packet 0x\(String(id, radix: 16))")
        }
    }
}

// MARK: - Output formats

func cgImage(_ img: RawImage, mode: ColorMode) throws -> CGImage {
    var pixels = img.pixels
    if mode == .bw {                                  // threshold like HP's driver
        pixels.withUnsafeMutableBytes { (b: UnsafeMutableRawBufferPointer) in
            for i in 0..<b.count { b[i] = b[i] >= 128 ? 255 : 0 }
        }
    }
    let space = img.channels == 3 ? CGColorSpace(name: CGColorSpace.sRGB)! : CGColorSpaceCreateDeviceGray()
    guard let provider = CGDataProvider(data: pixels as CFData),
          let cg = CGImage(width: img.width, height: img.height, bitsPerComponent: 8, bitsPerPixel: 8 * img.channels,
                           bytesPerRow: img.width * img.channels, space: space,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { throw ScanError(description: "cannot build image \(img.width)x\(img.height)") }
    return cg
}

func encode(_ cg: CGImage, uti: String, dpi: Int) throws -> Data {
    let out = NSMutableData()
    guard let dst = CGImageDestinationCreateWithData(out as CFMutableData, uti as CFString, 1, nil) else {
        throw ScanError(description: "no encoder for \(uti)")
    }
    let props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
                                  kCGImageDestinationLossyCompressionQuality: 0.9]
    CGImageDestinationAddImage(dst, cg, props as CFDictionary)
    guard CGImageDestinationFinalize(dst) else { throw ScanError(description: "\(uti) encoding failed") }
    return out as Data
}

/// Encode a scan as the eSCL document format the client asked for.
func document(_ img: RawImage, mode: ColorMode, format: String) throws -> (Data, String) {
    let cg = try cgImage(img, mode: mode)
    switch format {
    case "image/png":
        return (try encode(cg, uti: "public.png", dpi: img.dpi), format)
    case "application/pdf":
        // Embed the page as JPEG; CoreGraphics keeps the DCT data as is.
        let jpeg = try encode(cg, uti: "public.jpeg", dpi: img.dpi)
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let page = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw ScanError(description: "pdf page failed") }
        let out = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: Double(img.width) * 72 / Double(img.dpi),
                         height: Double(img.height) * 72 / Double(img.dpi))
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw ScanError(description: "pdf failed") }
        ctx.beginPDFPage(nil)
        ctx.draw(page, in: box)
        ctx.endPDFPage()
        ctx.closePDF()
        return (out as Data, format)
    default:
        return (try encode(cg, uti: "public.jpeg", dpi: img.dpi), "image/jpeg")
    }
}

// MARK: - eSCL jobs

final class Job {
    let id = UUID().uuidString.lowercased()
    let params: ScanParams
    let format: String
    let cancel = CancelToken()
    let done = DispatchGroup()
    var state = "Processing"          // Processing, Completed, Aborted
    var result: (Data, String)?
    var delivered = false
    init(params: ScanParams, format: String) { self.params = params; self.format = format }
}

let jobsLock = NSLock()
var jobs: [String: Job] = [:]
var jobOrder: [String] = []
let scanQueue = DispatchQueue(label: "m1132-escl.scan")

func scannerBusy() -> Bool {
    jobsLock.lock(); defer { jobsLock.unlock() }
    return jobs.values.contains { $0.state == "Processing" }
}

func startJob(_ job: Job) {
    jobsLock.lock()
    jobs[job.id] = job
    jobOrder.append(job.id)
    while jobOrder.count > 10 { jobs.removeValue(forKey: jobOrder.removeFirst()) }
    jobsLock.unlock()
    job.done.enter()
    scanQueue.async {
        let p = job.params
        log("job \(job.id): \(p.mode.rawValue) \(p.dpi) dpi, window \(p.left),\(p.top) \(p.width)x\(p.height)/100 in, \(job.format)")
        do {
            let img = try scan(p, cancel: job.cancel)
            job.result = try document(img, mode: p.mode, format: job.format)
            log("job \(job.id): done, \(img.width)x\(img.height) px, \(job.result!.0.count) bytes")
            jobsLock.lock(); job.state = "Completed"; jobsLock.unlock()
        } catch {
            log("job \(job.id): \(error)")
            jobsLock.lock(); job.state = "Aborted"; jobsLock.unlock()
        }
        job.done.leave()
    }
}

// MARK: - eSCL XML

let xmlHead = """
<?xml version="1.0" encoding="UTF-8"?>
"""
let ns = "xmlns:scan=\"http://schemas.hp.com/imaging/escl/2011/05/03\" xmlns:pwg=\"http://www.pwg.org/schemas/2010/12/sm\""

func capabilitiesXML() -> String {
    let res = resolutions.map {
        "<scan:DiscreteResolution><scan:XResolution>\($0)</scan:XResolution><scan:YResolution>\($0)</scan:YResolution></scan:DiscreteResolution>"
    }.joined()
    let formats = ["image/jpeg", "application/pdf", "image/png"]
    let fmt = formats.map { "<pwg:DocumentFormat>\($0)</pwg:DocumentFormat>" }.joined()
        + formats.map { "<scan:DocumentFormatExt>\($0)</scan:DocumentFormatExt>" }.joined()
    return xmlHead + """
    <scan:ScannerCapabilities \(ns)>
    <pwg:Version>2.63</pwg:Version>
    <pwg:MakeAndModel>\(makeAndModel)</pwg:MakeAndModel>
    <scan:UUID>\(scannerUUID)</scan:UUID>
    <scan:Platen><scan:PlatenInputCaps>
    <scan:MinWidth>16</scan:MinWidth><scan:MaxWidth>\(glassRight * 3)</scan:MaxWidth>
    <scan:MinHeight>16</scan:MinHeight><scan:MaxHeight>\(glassBottom * 3)</scan:MaxHeight>
    <scan:MaxScanRegions>1</scan:MaxScanRegions>
    <scan:SettingProfiles><scan:SettingProfile>
    <scan:ColorModes><scan:ColorMode>RGB24</scan:ColorMode><scan:ColorMode>Grayscale8</scan:ColorMode><scan:ColorMode>BlackAndWhite1</scan:ColorMode></scan:ColorModes>
    <scan:DocumentFormats>\(fmt)</scan:DocumentFormats>
    <scan:SupportedResolutions><scan:DiscreteResolutions>\(res)</scan:DiscreteResolutions></scan:SupportedResolutions>
    <scan:ColorSpaces><scan:ColorSpace>sRGB</scan:ColorSpace></scan:ColorSpaces>
    </scan:SettingProfile></scan:SettingProfiles>
    <scan:SupportedIntents><scan:Intent>Document</scan:Intent><scan:Intent>TextAndGraphic</scan:Intent><scan:Intent>Photo</scan:Intent><scan:Intent>Preview</scan:Intent></scan:SupportedIntents>
    <scan:MaxOpticalXResolution>600</scan:MaxOpticalXResolution><scan:MaxOpticalYResolution>600</scan:MaxOpticalYResolution>
    </scan:PlatenInputCaps></scan:Platen>
    </scan:ScannerCapabilities>
    """
}

func statusXML() -> String {
    jobsLock.lock(); defer { jobsLock.unlock() }
    let busy = jobs.values.contains { $0.state == "Processing" }
    let list = jobOrder.compactMap { jobs[$0] }.map { j in
        "<scan:JobInfo><pwg:JobUri>/eSCL/ScanJobs/\(j.id)</pwg:JobUri><pwg:JobUuid>\(j.id)</pwg:JobUuid>"
            + "<scan:Age>0</scan:Age><pwg:ImagesCompleted>\(j.state == "Completed" ? 1 : 0)</pwg:ImagesCompleted>"
            + "<pwg:ImagesToTransfer>\(j.state == "Completed" && !j.delivered ? 1 : 0)</pwg:ImagesToTransfer>"
            + "<pwg:JobState>\(j.state)</pwg:JobState></scan:JobInfo>"
    }.joined()
    return xmlHead + """
    <scan:ScannerStatus \(ns)><pwg:Version>2.63</pwg:Version><pwg:State>\(busy ? "Processing" : "Idle")</pwg:State><scan:Jobs>\(list)</scan:Jobs></scan:ScannerStatus>
    """
}

/// Collects the text of ScanSettings elements by local name (namespaces stripped).
final class SettingsParser: NSObject, XMLParserDelegate {
    var values: [String: String] = [:]
    private var text = ""
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) { text = "" }
    func parser(_ parser: XMLParser, foundCharacters s: String) { text += s }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty && values[name] == nil { values[name] = t }
        text = ""
    }
}

func parseScanSettings(_ body: Data) -> (ScanParams, String) {
    let delegate = SettingsParser()
    let parser = XMLParser(data: body)
    parser.shouldProcessNamespaces = true
    parser.delegate = delegate
    parser.parse()
    let v = delegate.values
    var p = ScanParams()
    if let r = v["XResolution"].flatMap(UInt32.init) {
        p.dpi = resolutions.min { abs(Int($0) - Int(r)) < abs(Int($1) - Int(r)) }!
    }
    p.mode = v["ColorMode"].flatMap(ColorMode.init(rawValue:)) ?? .rgb
    // Region is in 1/300 inch; the scanner works in 1/100 inch.
    func h(_ key: String) -> UInt32? { v[key].flatMap(UInt32.init).map { $0 / 3 } }
    p.left = h("XOffset") ?? 0
    p.top = h("YOffset") ?? 0
    p.width = h("Width") ?? glassRight
    p.height = h("Height") ?? glassBottom
    let format = v["DocumentFormatExt"] ?? v["DocumentFormat"] ?? "image/jpeg"
    return (p, format)
}

// MARK: - HTTP server

struct Request { let method: String, path: String, headers: [String: String], body: Data }

func respond(_ c: NWConnection, _ code: Int, _ reason: String, type: String? = nil,
             body: Data = Data(), extra: [String: String] = [:]) {
    var head = "HTTP/1.1 \(code) \(reason)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
    if let t = type { head += "Content-Type: \(t)\r\n" }
    for (k, v) in extra { head += "\(k): \(v)\r\n" }
    var d = (head + "\r\n").data(using: .utf8)!
    d.append(body)
    c.send(content: d, completion: .contentProcessed { _ in c.cancel() })
}

func handle(_ r: Request, _ c: NWConnection) {
    log("\(c.endpoint) \(r.method) \(r.path) \(r.headers["user-agent"] ?? "")")
    let xml = "text/xml"
    let parts = r.path.split(separator: "/").map(String.init)   // ["eSCL", ...]
    guard parts.first == "eSCL" else { return respond(c, 404, "Not Found") }
    switch (r.method, Array(parts.dropFirst())) {
    case ("GET", ["ScannerCapabilities"]):
        respond(c, 200, "OK", type: xml, body: capabilitiesXML().data(using: .utf8)!)
    case ("GET", ["ScannerStatus"]):
        respond(c, 200, "OK", type: xml, body: statusXML().data(using: .utf8)!)
    case ("POST", ["ScanJobs"]):
        guard !scannerBusy() else { return respond(c, 503, "Service Unavailable") }
        let (params, format) = parseScanSettings(r.body)
        let job = Job(params: params, format: format)
        startJob(job)
        let host = r.headers["host"] ?? "localhost"
        respond(c, 201, "Created", extra: ["Location": "http://\(host)/eSCL/ScanJobs/\(job.id)"])
    case ("GET", let p) where p.count == 3 && p[0] == "ScanJobs" && p[2] == "NextDocument":
        jobsLock.lock(); let job = jobs[p[1]]; jobsLock.unlock()
        guard let job = job else { return respond(c, 404, "Not Found") }
        job.done.notify(queue: .global()) {
            jobsLock.lock()
            let ready = job.state == "Completed" && !job.delivered ? job.result : nil
            if ready != nil { job.delivered = true }
            jobsLock.unlock()
            guard let (data, type) = ready else { return respond(c, 404, "Not Found") }
            respond(c, 200, "OK", type: type, body: data)
        }
    case ("DELETE", let p) where p.count == 2 && p[0] == "ScanJobs":
        jobsLock.lock(); let job = jobs[p[1]]; jobsLock.unlock()
        guard let job = job else { return respond(c, 404, "Not Found") }
        job.cancel.cancelled = true
        respond(c, 200, "OK")
    default:
        respond(c, 404, "Not Found")
    }
}

/// Addresses of this Mac (without scope), used to refuse other machines.
func localAddresses() -> Set<String> {
    var out: Set<String> = ["127.0.0.1", "::1"]
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0 else { return out }
    defer { freeifaddrs(list) }
    var p = list
    while let a = p {
        if let sa = a.pointee.ifa_addr, sa.pointee.sa_family == AF_INET || sa.pointee.sa_family == AF_INET6 {
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.insert(String(cString: host).components(separatedBy: "%")[0])
            }
        }
        p = a.pointee.ifa_next
    }
    return out
}

func isLocal(_ c: NWConnection) -> Bool {
    guard case let .hostPort(host, _) = c.endpoint else { return false }
    let s = "\(host)".components(separatedBy: "%")[0]
    return localAddresses().contains(s.hasPrefix("::ffff:") ? String(s.dropFirst(7)) : s)
}

func receive(_ c: NWConnection, _ buf: Data) {
    c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
        var buf = buf
        if let d = data { buf.append(d) }
        if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
            let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
            let lines = head.components(separatedBy: "\r\n")
            let first = lines[0].split(separator: " ").map(String.init)
            var headers: [String: String] = [:]
            for l in lines.dropFirst() {
                if let i = l.firstIndex(of: ":") {
                    headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
                }
            }
            let length = Int(headers["content-length"] ?? "0") ?? 0
            let body = buf[end.upperBound...]
            if body.count >= length, first.count >= 2 {
                let path = first[1].components(separatedBy: "?")[0]
                return handle(Request(method: first[0], path: path, headers: headers, body: Data(body.prefix(length))), c)
            }
        }
        if complete || error != nil || buf.count > 1 << 20 { c.cancel(); return }
        receive(c, buf)
    }
}

// MARK: - Main

var port: UInt16 = 18132
var allowLAN = false
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--port": port = args.next().flatMap(UInt16.init) ?? port
    case "--allow-lan": allowLAN = true
    default:
        FileHandle.standardError.write("usage: m1132-escl [--port N] [--allow-lan]\n".data(using: .utf8)!)
        exit(2)
    }
}

let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
listener.service = NWListener.Service(name: serviceName, type: "_uscan._tcp", domain: nil, txtRecord: NWTXTRecord([
    "txtvers": "1", "vers": "2.63", "rs": "eSCL", "ty": makeAndModel, "UUID": scannerUUID,
    "pdl": "image/jpeg,application/pdf,image/png", "cs": "color,grayscale,binary",
    "is": "platen", "duplex": "F", "note": "native arm64 driver",
]))
listener.newConnectionHandler = { c in
    guard allowLAN || isLocal(c) else { log("refused \(c.endpoint)"); c.cancel(); return }
    c.start(queue: .global())
    receive(c, Data())
}
listener.stateUpdateHandler = { state in
    switch state {
    case .ready: log("eSCL scanner \"\(serviceName)\" on port \(port)\(allowLAN ? " (LAN allowed)" : " (this Mac only)")")
    case .failed(let e): log("listener failed: \(e)"); exit(1)
    default: break
    }
}
listener.start(queue: .main)
dispatchMain()
