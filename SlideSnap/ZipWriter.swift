//
//  ZipWriter.swift
//  SlideSnap
//
//  무압축(STORE) ZIP 작성기. PPTX 같은 OOXML 컨테이너를 만들 때 쓴다.
//  Foundation 만 사용하며 CRC32 는 테이블로 직접 계산한다. ZIP64 는 지원하지 않는다.
//

import Foundation

struct ZipWriter {
    // MARK: - 오류

    enum ZipError: LocalizedError {
        /// 전체 크기·항목 수가 ZIP64 없이 담을 수 있는 한도를 넘었다.
        case tooLarge
        /// 파일 경로가 비어 있거나 너무 길다.
        case invalidPath(String)

        var errorDescription: String? {
            switch self {
            case .tooLarge: return String(localized: "ZIP 파일이 4GB 한도를 넘었습니다.")
            case .invalidPath(let path): return String(localized: "잘못된 ZIP 항목 경로: \(path)")
            }
        }
    }

    // MARK: - 항목

    private struct Entry {
        let name: Data
        let data: Data
        let crc: UInt32
    }

    private var entries: [Entry] = []
    private let dosTime: UInt16
    private let dosDate: UInt16

    init() {
        // DOS 날짜/시간은 현재 시각(현지 시간) 기준. 1980년 이전은 표현할 수 없으므로 1980-01-01 로 고정.
        let comps = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: Date())
        let year = max((comps.year ?? 1980) - 1980, 0)
        dosDate = UInt16(truncatingIfNeeded: (min(year, 127) << 9) | ((comps.month ?? 1) << 5) | (comps.day ?? 1))
        dosTime = UInt16(truncatingIfNeeded: ((comps.hour ?? 0) << 11) | ((comps.minute ?? 0) << 5) | ((comps.second ?? 0) / 2))
    }

    /// 파일 하나를 추가한다. path 는 "ppt/slides/slide1.xml" 같은 상대경로(구분자 `/`).
    mutating func addFile(path: String, data: Data) {
        entries.append(Entry(name: Data(path.utf8), data: data, crc: Self.crc32(data)))
    }

    // MARK: - 쓰기

    /// 로컬 파일 헤더 + 데이터 → 중앙 디렉터리 → EOCD 순으로 기록한다.
    func write(to url: URL) throws {
        guard entries.count <= Int(UInt16.max) else { throw ZipError.tooLarge }

        var out = Data()
        var central = Data()

        for entry in entries {
            guard !entry.name.isEmpty, entry.name.count <= Int(UInt16.max) else {
                throw ZipError.invalidPath(String(decoding: entry.name, as: UTF8.self))
            }
            guard entry.data.count < Int(UInt32.max), out.count < Int(UInt32.max) else {
                throw ZipError.tooLarge
            }
            let offset = UInt32(out.count)
            let size = UInt32(entry.data.count)

            // 로컬 파일 헤더
            out.appendLE(UInt32(0x04034b50))
            out.appendLE(UInt16(20))            // 필요한 버전 2.0
            out.appendLE(UInt16(0x0800))        // 플래그: bit 11 = UTF-8 파일명
            out.appendLE(UInt16(0))             // 압축 방식: STORE
            out.appendLE(dosTime)
            out.appendLE(dosDate)
            out.appendLE(entry.crc)
            out.appendLE(size)                  // 압축 크기
            out.appendLE(size)                  // 원본 크기
            out.appendLE(UInt16(entry.name.count))
            out.appendLE(UInt16(0))             // extra 길이
            out.append(entry.name)
            out.append(entry.data)

            // 중앙 디렉터리 항목
            central.appendLE(UInt32(0x02014b50))
            central.appendLE(UInt16(20))        // 만든 버전 (MS-DOS, 2.0)
            central.appendLE(UInt16(20))        // 필요한 버전
            central.appendLE(UInt16(0x0800))
            central.appendLE(UInt16(0))
            central.appendLE(dosTime)
            central.appendLE(dosDate)
            central.appendLE(entry.crc)
            central.appendLE(size)
            central.appendLE(size)
            central.appendLE(UInt16(entry.name.count))
            central.appendLE(UInt16(0))         // extra 길이
            central.appendLE(UInt16(0))         // 주석 길이
            central.appendLE(UInt16(0))         // 디스크 번호
            central.appendLE(UInt16(0))         // 내부 속성
            central.appendLE(UInt32(0))         // 외부 속성
            central.appendLE(offset)
            central.append(entry.name)
        }

        let centralOffset = out.count
        guard centralOffset + central.count + 22 <= Int(UInt32.max) else { throw ZipError.tooLarge }
        out.append(central)

        // EOCD (End of Central Directory)
        out.appendLE(UInt32(0x06054b50))
        out.appendLE(UInt16(0))                 // 디스크 번호
        out.appendLE(UInt16(0))                 // 중앙 디렉터리 시작 디스크
        out.appendLE(UInt16(entries.count))
        out.appendLE(UInt16(entries.count))
        out.appendLE(UInt32(central.count))
        out.appendLE(UInt32(centralOffset))
        out.appendLE(UInt16(0))                 // 주석 길이

        try out.write(to: url, options: .atomic)
    }

    // MARK: - CRC32

    /// IEEE 802.3 다항식(0xEDB88320) 룩업 테이블.
    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for byte in buf {
                crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

// MARK: - 리틀엔디언 기록

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
