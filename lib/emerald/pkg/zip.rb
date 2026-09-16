# frozen_string_literal: true

module Emerald
  module Pkg
    # 最小 ZIP 读取器/写出器（docs/SPEC-package-format.md §2 容器 .emz）。
    # 只读：解析 central directory → 逐条目回本地头取数据，
    # 支持 stored(0) / deflate(8)——覆盖常规打包工具（zip/7z/GitHub archive）
    # 的输出。写入侧为 dogfood 打包工具链补的最小实现（Zip.write）：
    # 只产 stored(0) 条目——纯 Ruby 无 Zlib 依赖（字节底座须 CRuby/Opal 同构，
    # 见 pkg.rb 头注），源文本包体积代价可接受；deflate 包的读取不受影响。
    # 不支持：ZIP64、加密、多卷、data descriptor 以外的极端形态——全部明确报错。
    # 输入输出均为字节 Array<Integer>（Entries 的 data 已解压）。
    class Zip
      Corrupt = Class.new(StandardError)
      Unsupported = Class.new(StandardError)

      # name: UTF-8 文件名；directory: 目录条目；data: 已解压字节
      Entry = Struct.new(:name, :directory, :data)

      SIG_LOCAL = [0x50, 0x4b, 0x03, 0x04].freeze   # 'PK\x03\x04'
      SIG_CENTRAL = [0x50, 0x4b, 0x01, 0x02].freeze # 'PK\x01\x02'
      SIG_EOCD = [0x50, 0x4b, 0x05, 0x06].freeze    # 'PK\x05\x06'
      EOCD_MIN = 22
      COMMENT_MAX = 0xffff
      FLAG_UTF8 = 0x0800 # 通用标志 bit 11：文件名/注释为 UTF-8

      class << self
        # 字节 Array<Integer>（.emz 全量内容）=> [Entry]（跳过目录条目）
        def read(bytes)
          eocd = find_eocd(bytes)
          count = u16(bytes, eocd + 10)
          cd_offset = u32(bytes, eocd + 16)
          raise_unsupported_zip64 if cd_offset == 0xffffffff || count == 0xffff

          pos = cd_offset
          entries = []
          count.times do
            entry, pos = read_central_entry(bytes, pos)
            entries << entry unless entry.directory
          end
          entries
        end

        # [Entry]（name UTF-8 名 / data 字节 Array）=> 字节 Array（合法 zip）。
        # stored-only：CRC-32 用纯 Ruby 的 Crc32 计算；目录条目（data 为空、
        # 名以 / 结尾）按 zip 惯例写 stored，读取侧本就跳过它们。
        def write(entries)
          body = []
          central = []
          Array(entries).each do |entry|
            data = entry.data || []
            nb = entry.name.to_s.b.bytes
            raise Unsupported, '条目名含 NUL，无法写入 zip' if nb.include?(0)

            crc = Crc32.of(data)
            lho = body.size
            body.concat(SIG_LOCAL)
                .concat(u16le(20))                # version needed
                .concat(u16le(FLAG_UTF8))
                .concat(u16le(0))                 # method: stored
                .concat(u16le(0)).concat(u16le(0)) # mod time/date（不保留时间戳）
                .concat(u32le(crc))
                .concat(u32le(data.size))         # csize
                .concat(u32le(data.size))         # usize
                .concat(u16le(nb.size))
                .concat(u16le(0))                 # extra len
                .concat(nb)
                .concat(data)
            central << [nb, data.size, crc, lho]
          end

          cd_offset = body.size
          central.each do |nb, size, crc, lho|
            body.concat(SIG_CENTRAL)
                .concat(u16le(20))                # version made by
                .concat(u16le(20))                # version needed
                .concat(u16le(FLAG_UTF8))
                .concat(u16le(0))                 # method: stored
                .concat(u16le(0)).concat(u16le(0)) # mod time/date
                .concat(u32le(crc))
                .concat(u32le(size)).concat(u32le(size))
                .concat(u16le(nb.size))
                .concat(u16le(0)).concat(u16le(0)) # extra/comment len
                .concat(u16le(0)).concat(u16le(0)) # disk/internal attr
                .concat(u32le(0))                 # external attr
                .concat(u32le(lho))
                .concat(nb)
          end
          cd_size = body.size - cd_offset
          body.concat(SIG_EOCD)
              .concat(u16le(0)).concat(u16le(0))   # disk / cd 起始 disk
              .concat(u16le(central.size)).concat(u16le(central.size))
              .concat(u32le(cd_size)).concat(u32le(cd_offset))
              .concat(u16le(0))                   # comment len
          body
        end

        private

        # 从尾部扫描 EOCD（含 comment；长度一致性校验排除误命中）
        def find_eocd(bytes)
          size = bytes.size
          raise Corrupt, '内容太小，不是 zip' if size < EOCD_MIN

          low = [size - EOCD_MIN - COMMENT_MAX, 0].max
          (size - EOCD_MIN).downto(low) do |i|
            next unless sig_at?(bytes, i, SIG_EOCD)

            comment_len = u16(bytes, i + 20)
            return i if i + EOCD_MIN + comment_len == size
          end
          raise Corrupt, '找不到 EOCD（不是 zip 或已损坏）'
        end

        def read_central_entry(bytes, pos)
          raise Corrupt, "central directory 签名不符（偏移 #{pos}）" unless sig_at?(bytes, pos, SIG_CENTRAL)

          flags = u16(bytes, pos + 8)
          method = u16(bytes, pos + 10)
          csize = u32(bytes, pos + 20)
          nlen = u16(bytes, pos + 28)
          elen = u16(bytes, pos + 30)
          clen = u16(bytes, pos + 32)
          lho = u32(bytes, pos + 42)
          raise_unsupported_zip64 if [csize, lho].include?(0xffffffff)
          raise Unsupported, 'zip 已加密，不支持' if flags & 0x1 != 0

          name = Bytes.to_utf8(bytes[pos + 46, nlen] || [])
          data = extract_local(bytes, lho, method, csize)
          [Entry.new(name, name.end_with?('/'), data), pos + 46 + nlen + elen + clen]
        end

        # 回本地头取数据：数据段长度取 central 的 csize（本地头在
        # data descriptor 形态下可能填 0，不可信）
        def extract_local(bytes, lho, method, csize)
          raise Corrupt, "本地头签名不符（偏移 #{lho}）" unless sig_at?(bytes, lho, SIG_LOCAL)

          lnlen = u16(bytes, lho + 26)
          lelen = u16(bytes, lho + 28)
          start = lho + 30 + lnlen + lelen
          raw = bytes[start, csize]
          raise Corrupt, '本地数据段截断（zip 损坏）' if raw.nil? || raw.size < csize

          case method
          when 0 then raw
          when 8 then Inflate.run(raw)
          else raise Unsupported, "压缩方法 #{method} 不支持（仅 stored/deflate）"
          end
        end

        def sig_at?(bytes, pos, sig)
          pos >= 0 && bytes[pos, 4] == sig
        end

        def u16(bytes, pos)
          bytes[pos] | (bytes[pos + 1] << 8)
        end

        def u32(bytes, pos)
          bytes[pos] | (bytes[pos + 1] << 8) | (bytes[pos + 2] << 16) | (bytes[pos + 3] << 24)
        end

        # 小端编码（写出侧；Opal 无 Array#pack——字节底座纪律同 pkg.rb 头注）
        def u16le(v)
          [v & 0xff, (v >> 8) & 0xff]
        end

        def u32le(v)
          [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]
        end

        def raise_unsupported_zip64
          raise Unsupported, 'ZIP64 包不支持（>4GB 或超 65535 条目）'
        end
      end
    end

    # CRC-32（ISO 3309 / IEEE 802.3，ZIP 的 CRC 形态）：表驱动纯 Ruby 实现。
    # Opal 无 Zlib——与 Inflate/Sha256 同构（CRuby 测试用 Zlib.crc32 对拍）。
    module Crc32
      POLY = 0xEDB88320
      TABLE = (0..255).map do |i|
        c = i
        8.times { c = (c & 1).zero? ? c >> 1 : (c >> 1) ^ POLY }
        c
      end.freeze

      def self.of(bytes)
        crc = 0xFFFFFFFF
        bytes.each { |b| crc = (crc >> 8) ^ TABLE[(crc ^ b) & 0xFF] }
        (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF
      end
    end
  end
end
