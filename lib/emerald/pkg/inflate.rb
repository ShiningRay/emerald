# frozen_string_literal: true

module Emerald
  module Pkg
    # 纯 Ruby DEFLATE（RFC 1951）解码器——zip 管线的解压底座。
    # Opal 无 Zlib；CRuby 测试用 Zlib::Deflate(level, -15) 的裸 deflate 流对拍。
    # 输入输出均为 Array<Integer>，同步无 Promise，CRuby/Opal 同构。
    module Inflate
      class Corrupt < StandardError; end

      MAX_BITS = 15

      LENGTH_BASE = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                     35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258].freeze
      LENGTH_EXTRA = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                      3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0].freeze
      DIST_BASE = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                   257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
                   8193, 12289, 16385, 24577].freeze
      DIST_EXTRA = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                    7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13].freeze
      # code-length 码的固定重排序（RFC 1951 §3.2.7）
      CLEN_ORDER = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15].freeze

      # 裸 deflate 流 → 原始字节
      def self.run(bytes)
        r = BitReader.new(bytes)
        out = []
        loop do
          final = r.read_bit == 1
          case r.read_bits(2)
          when 0 then stored_block(r, out)
          when 1 then huffman_block(r, out, fixed_lit_table, fixed_dist_table)
          when 2 then dynamic_block(r, out)
          else raise Corrupt, 'DEFLATE 块类型 3 非法（数据损坏）'
          end
          break if final
        end
        out
      end

      # ── 三种块 ─────────────────────────────────────────

      # BTYPE=00 stored：对齐到字节 → LEN/NLEN → 原样拷贝
      def self.stored_block(r, out)
        r.align!
        len = r.read_u16le
        nlen = r.read_u16le
        raise Corrupt, "stored 块 LEN/NLEN 校验失败（#{len}/#{nlen}）" if (len ^ 0xffff) != nlen

        out.concat(r.read_bytes(len))
      end

      # BTYPE=01/10 共用的 Huffman 主循环
      def self.huffman_block(r, out, lit_table, dist_table)
        loop do
          sym = decode_sym(lit_table, r)
          if sym < 256
            out << sym
          elsif sym == 256
            return
          else
            copy_match(r, out, sym, dist_table)
          end
        end
      end

      def self.copy_match(r, out, sym, dist_table)
        li = sym - 257
        raise Corrupt, "长度符号越界: #{sym}" if li >= LENGTH_BASE.size

        length = LENGTH_BASE[li] + r.read_bits(LENGTH_EXTRA[li])
        dsym = decode_sym(dist_table, r)
        raise Corrupt, "距离符号越界: #{dsym}" if dsym >= DIST_BASE.size

        dist = DIST_BASE[dsym] + r.read_bits(DIST_EXTRA[dsym])
        raise Corrupt, '距离越出已解压窗口（数据损坏）' if dist > out.size

        # 逐字节拷贝：dist < length 的重叠区必须看到本次写入（LZ77 语义）
        length.times { out << out[-dist] }
      end

      def self.dynamic_block(r, out)
        hlit = r.read_bits(5) + 257
        hdist = r.read_bits(5) + 1
        hclen = r.read_bits(4) + 4

        clen_lengths = Array.new(19, 0)
        hclen.times { |i| clen_lengths[CLEN_ORDER[i]] = r.read_bits(3) }
        clen_table = build_table(clen_lengths)

        lengths = []
        total = hlit + hdist
        while lengths.size < total
          sym = decode_sym(clen_table, r)
          case sym
          when 0..15 then lengths << sym
          when 16
            raise Corrupt, 'code-length 16 无前值' if lengths.empty?

            (3 + r.read_bits(2)).times { lengths << lengths[-1] }
          when 17 then (3 + r.read_bits(3)).times { lengths << 0 }
          when 18 then (11 + r.read_bits(7)).times { lengths << 0 }
          else raise Corrupt, "code-length 符号越界: #{sym}"
          end
        end
        raise Corrupt, '码长表超长（数据损坏）' if lengths.size > total

        lit_table = build_table(lengths[0, hlit])
        dist_table = build_table(lengths[hlit, hdist] || [])
        raise Corrupt, '字面量 Huffman 表为空' if lit_table.empty?

        huffman_block(r, out, lit_table, dist_table)
      end

      # ── canonical Huffman 表（码长 → 符号）──────────────
      # 表结构：{ [码长, 码值] => 符号 }；解码按位喂入、逐长度查表。
      def self.build_table(lengths)
        max = lengths.max
        return {} if max.nil? || max.zero?

        kraft = 0
        counts = Array.new(max + 1, 0)
        lengths.each do |l|
          counts[l] += 1 if l.positive?
          kraft += (1 << (MAX_BITS - l)) if l.positive?
        end
        raise Corrupt, 'Huffman 表过订阅（数据损坏）' if kraft > (1 << MAX_BITS)

        next_code = Array.new(max + 1, 0)
        code = 0
        (1..max).each do |bits|
          code = (code + counts[bits - 1]) << 1
          next_code[bits] = code
        end

        table = {}
        lengths.each_with_index do |l, sym|
          next if l.zero?

          table[[l, next_code[l]]] = sym
          next_code[l] += 1
        end
        table
      end

      def self.decode_sym(table, r)
        code = 0
        (1..MAX_BITS).each do |len|
          code = (code << 1) | r.read_bit
          sym = table[[len, code]]
          return sym unless sym.nil?
        end
        raise Corrupt, 'Huffman 码越界（数据损坏）'
      end

      # ── 固定表（BTYPE=01）──────────────────────────────
      def self.fixed_lit_table
        @fixed_lit_table ||= build_table(
          [8] * 144 + [9] * 112 + [7] * 24 + [8] * 8
        )
      end

      def self.fixed_dist_table
        @fixed_dist_table ||= build_table([5] * 32) # 30/31 号码非法但码型存在（RFC §3.2.6）
      end

      # ── LSB-first 位读取器（RFC 1951：非 Huffman 字段低位在前）──
      class BitReader
        def initialize(bytes)
          @bytes = bytes
          @pos = 0    # 下一字节的下标
          @cur = 0    # 当前字节剩余位（已右移对齐）
          @cnt = 0    # 剩余位数
        end

        def read_bit
          refill if @cnt.zero?
          bit = @cur & 1
          @cur >>= 1
          @cnt -= 1
          bit
        end

        def read_bits(n)
          v = 0
          n.times { |i| v |= read_bit << i }
          v
        end

        # stored 块前丢弃当前字节剩余位
        def align!
          @cnt = 0
        end

        def read_u16le
          read_bits(16)
        end

        def read_bytes(n)
          raise Corrupt, '输入截断（数据损坏）' if @pos + n > @bytes.size

          slice = @bytes[@pos, n]
          @pos += n
          slice
        end

        private

        def refill
          raise Corrupt, '输入截断（数据损坏）' if @pos >= @bytes.size

          @cur = @bytes[@pos]
          @pos += 1
          @cnt = 8
        end
      end
    end
  end
end
