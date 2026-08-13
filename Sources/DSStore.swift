import Foundation

// `.DS_Store` の読み書き。
//
// Finder がフォルダごとの表示設定を置くファイル。形式は公開されていないので、実物を解いて
// 合わせた（2026-08-14）。分かったことは3つ。
//
// - フォルダの表示設定は、そのフォルダの中ではなく **一つ上の `.DS_Store`** に、
//   フォルダ名を鍵にして入る。`Movies/.DS_Store` は存在せず、記録は親にあった
// - 中身は「バディアロケータ」で場所を管理する容れ物に、名前で並べた木を載せたもの
// - 節（ページ）の大きさは容れ物側に書いてあり、既定の 4KB より大きくしても Finder は読む
//   （301 フォルダ・1MB のファイルで確認）
//
// 壊すと利用者が積み上げた表示設定が消える。読めなかったファイルには触らない。

struct DSStoreRecord {
    let name: String
    /// 記録の種類。`icvp`（アイコン表示）、`lsvp`（リスト表示）など
    let id: String
    /// `blob` `long` `bool` など
    let type: String
    /// 型ごとの中身そのもの。`blob` や `ustr` の長さの前置きは含めない
    let payload: Data
}

enum DSStoreError: Error {
    case malformed(String)
}

enum DSStore {
    // MARK: - 読む

    static func read(_ path: String) throws -> [DSStoreRecord] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count >= 32 else { throw DSStoreError.malformed("短すぎる") }

        var header = Cursor(data, at: 0)
        guard try header.u32() == 1, try header.take(4) == Data("Bud1".utf8) else {
            throw DSStoreError.malformed("Bud1 ではない")
        }
        let infoOffset = Int(try header.u32())

        // ブロック表。値の下位5ビットが大きさの指数、残りが位置。位置はどれも +4 が実際の場所
        var info = Cursor(data, at: infoOffset + 4)
        let blockCount = Int(try info.u32())
        _ = try info.u32()
        var blocks: [(offset: Int, size: Int)] = []
        for _ in 0..<blockCount {
            let value = Int(try info.u32())
            blocks.append((offset: (value >> 5) << 5, size: 1 << (value & 0x1f)))
        }

        // ブロック表は 256 個単位で場所が取ってある。目録はその後ろ
        info = Cursor(data, at: infoOffset + 4 + 8 + ((blockCount + 255) / 256) * 256 * 4)
        let directoryCount = Int(try info.u32())
        var root: Int?
        for _ in 0..<directoryCount {
            let length = Int(try info.u8())
            let name = String(decoding: try info.take(length), as: UTF8.self)
            let block = Int(try info.u32())
            if name == "DSDB" { root = block }
        }
        guard let masterBlock = root, masterBlock < blocks.count else {
            throw DSStoreError.malformed("DSDB が無い")
        }

        var master = Cursor(data, at: blocks[masterBlock].offset + 4)
        let rootNode = Int(try master.u32())

        var records: [DSStoreRecord] = []
        try walk(rootNode, in: data, blocks: blocks, into: &records)
        return records
    }

    /// 節をたどる。先頭は「一番右の子」の番号で、0 なら葉
    private static func walk(
        _ node: Int, in data: Data, blocks: [(offset: Int, size: Int)],
        into records: inout [DSStoreRecord]
    ) throws {
        guard node < blocks.count else { throw DSStoreError.malformed("節が範囲の外") }
        var cursor = Cursor(data, at: blocks[node].offset + 4)

        let last = Int(try cursor.u32())
        let count = Int(try cursor.u32())
        for _ in 0..<count {
            if last != 0 {
                try walk(Int(try cursor.u32()), in: data, blocks: blocks, into: &records)
            }
            records.append(try record(&cursor))
        }
        if last != 0 {
            try walk(last, in: data, blocks: blocks, into: &records)
        }
    }

    private static func record(_ cursor: inout Cursor) throws -> DSStoreRecord {
        let length = Int(try cursor.u32())
        let name = utf16BE(try cursor.take(length * 2))
        let id = String(decoding: try cursor.take(4), as: UTF8.self)
        let type = String(decoding: try cursor.take(4), as: UTF8.self)

        let payload: Data
        switch type {
        case "bool": payload = try cursor.take(1)
        case "long", "shor", "type": payload = try cursor.take(4)
        case "comp", "dutc": payload = try cursor.take(8)
        case "blob", "ustr":
            let count = Int(try cursor.u32())
            payload = try cursor.take(type == "blob" ? count : count * 2)
        default:
            throw DSStoreError.malformed("知らない型 \(type)")
        }
        return DSStoreRecord(name: name, id: id, type: type, payload: payload)
    }

    // MARK: - 書く

    /// 木は葉ひとつにまとめて書く。段を作らずに済むよう、ページを必要なだけ大きくする。
    /// Finder は 4KB を超えるページも読む（1MB で確認済み）
    static func write(_ records: [DSStoreRecord], to path: String) throws {
        let sorted = records.sorted {
            let left = $0.name.lowercased(), right = $1.name.lowercased()
            return left == right ? $0.id < $1.id : left < right
        }

        var leaf = Data()
        leaf.append(be32(0))  // 葉なので子は無い
        leaf.append(be32(UInt32(sorted.count)))
        for record in sorted {
            let name = Array(record.name.utf16)
            leaf.append(be32(UInt32(name.count)))
            for unit in name { leaf.append(be16(unit)) }
            leaf.append(Data(record.id.utf8))
            leaf.append(Data(record.type.utf8))
            // 長さの前置きは型が決める。中身だけを持ち回り、書くときに付け直す
            switch record.type {
            case "blob": leaf.append(be32(UInt32(record.payload.count)))
            case "ustr": leaf.append(be32(UInt32(record.payload.count / 2)))
            default: break
            }
            leaf.append(record.payload)
        }

        // 位置は大きさに揃える。ブロック表は下位5ビットを指数に使うので、位置は32の倍数が要る
        var page = 0x1000
        while page < leaf.count { page <<= 1 }
        let leafOffset = page
        let infoOffset = page * 2
        let infoSize = 0x800
        let masterOffset = 0x40

        var out = Data(count: infoOffset + infoSize + 4)
        out.replaceSubrange(leafOffset + 4..<leafOffset + 4 + leaf.count, with: leaf)

        var master = Data()
        master.append(be32(2))  // 根は葉そのもの
        master.append(be32(0))  // 段は0
        master.append(be32(UInt32(sorted.count)))
        master.append(be32(1))  // 節は1つ
        master.append(be32(UInt32(page)))
        out.replaceSubrange(masterOffset + 4..<masterOffset + 4 + master.count, with: master)

        let blocks = [(infoOffset, infoSize), (masterOffset, 0x20), (leafOffset, page)]
        var info = Data()
        info.append(be32(UInt32(blocks.count)))
        info.append(be32(0))
        for (offset, size) in blocks {
            info.append(be32(UInt32(offset | (size.trailingZeroBitCount))))
        }
        info.append(Data(count: 256 * 4 - blocks.count * 4))
        info.append(be32(1))  // 目録は DSDB ひとつ
        info.append(Data([4]))
        info.append(Data("DSDB".utf8))
        info.append(be32(1))
        info.append(Data(count: 32 * 4))  // 空きリスト（どの大きさも空）
        out.replaceSubrange(infoOffset + 4..<infoOffset + 4 + info.count, with: info)

        var head = Data()
        head.append(be32(1))
        head.append(Data("Bud1".utf8))
        head.append(be32(UInt32(infoOffset)))
        head.append(be32(UInt32(info.count)))
        head.append(be32(UInt32(infoOffset)))
        out.replaceSubrange(0..<head.count, with: head)

        // 途中で止められても、書きかけのものを残さない。壊れた `.DS_Store` は
        // こちらが二度と触らなくなる（読めないものには手を出さない作りのため）
        try out.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    // MARK: - 部品

    /// 名前は UTF-16 の上位バイト先行で入っている
    private static func utf16BE(_ data: Data) -> String {
        var units: [UInt16] = []
        var index = data.startIndex
        while index + 1 < data.endIndex {
            units.append(UInt16(data[index]) << 8 | UInt16(data[index + 1]))
            index += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    private static func be32(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)])
    }

    private static func be16(_ value: UInt16) -> Data {
        Data([UInt8(value >> 8 & 0xff), UInt8(value & 0xff)])
    }

    private struct Cursor {
        private let data: Data
        private var index: Int

        init(_ data: Data, at index: Int) {
            self.data = data
            self.index = index
        }

        mutating func take(_ count: Int) throws -> Data {
            guard count >= 0, index >= 0, index + count <= data.count else {
                throw DSStoreError.malformed("読み過ぎ")
            }
            defer { index += count }
            return data.subdata(in: index..<index + count)
        }

        mutating func u8() throws -> UInt8 { try take(1)[0] }

        mutating func u32() throws -> UInt32 {
            let bytes = try take(4)
            return bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        }
    }
}
