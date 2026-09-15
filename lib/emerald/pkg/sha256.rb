# frozen_string_literal: true

module Emerald
  module Pkg
    # 纯 Ruby SHA-256（FIPS 180-4）。opal 1.8.3 没有 digest 标准库，而包管线
    # 需要内容指纹（lock 的 content_sha256、编译缓存键），故自带实现。
    # 输入：Array<Integer>（0..255）或二进制 String；输出：64 位小写 hex。
    # 性能口径：应用源码是 KB 级文本，纯 Ruby 吞吐绰绰有余。
    # 正确性由 test/pkg_zip_test.rb 用 ::Digest::SHA256 随机对拍保证。
    module Sha256
      MASK = 0xffffffff

      K = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
      ].freeze

      H0 = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
      ].freeze

      def self.hexdigest(data)
        bytes = data.is_a?(String) ? data.bytes : data
        unless bytes.is_a?(Array) && bytes.all? { |b| b.is_a?(Integer) && b.between?(0, 255) }
          raise ArgumentError, '输入必须是字节 Array<Integer> 或二进制 String'
        end

        digest(padded(bytes)).map { |b| format('%02x', b) }.join
      end

      def self.padded(bytes)
        bit_len = bytes.size * 8
        msg = bytes + [0x80]
        msg << 0 while msg.size % 64 != 56
        8.times { |i| msg << ((bit_len >> (56 - 8 * i)) & 0xff) } # 64 位大端长度
        msg
      end

      def self.digest(msg)
        h = H0.dup
        (0...msg.size).step(64) do |off|
          w = expand_block(msg, off)
          a, b, c, d, e, f, g, hh = h
          64.times do |t|
            t1 = (hh + big_sigma1(e) + ch(e, f, g) + K[t] + w[t]) & MASK
            t2 = (big_sigma0(a) + maj(a, b, c)) & MASK
            hh = g
            g = f
            f = e
            e = (d + t1) & MASK
            d = c
            c = b
            b = a
            a = (t1 + t2) & MASK
          end
          h = [h[0] + a, h[1] + b, h[2] + c, h[3] + d,
               h[4] + e, h[5] + f, h[6] + g, h[7] + hh].map { |x| x & MASK }
        end
        h.flat_map { |x| [24, 16, 8, 0].map { |s| (x >> s) & 0xff } }
      end

      def self.expand_block(msg, off)
        w = Array.new(64)
        16.times do |t|
          i = off + 4 * t
          w[t] = (msg[i] << 24) | (msg[i + 1] << 16) | (msg[i + 2] << 8) | msg[i + 3]
        end
        16.upto(63) do |t|
          w[t] = (sig1(w[t - 2]) + w[t - 7] + sig0(w[t - 15]) + w[t - 16]) & MASK
        end
        w
      end

      def self.rotr(x, n)
        ((x >> n) | (x << (32 - n))) & MASK
      end

      def self.sig0(x)       # σ0
        rotr(x, 7) ^ rotr(x, 18) ^ (x >> 3)
      end

      def self.sig1(x)       # σ1
        rotr(x, 17) ^ rotr(x, 19) ^ (x >> 10)
      end

      def self.big_sigma0(x) # Σ0
        rotr(x, 2) ^ rotr(x, 13) ^ rotr(x, 22)
      end

      def self.big_sigma1(x) # Σ1
        rotr(x, 6) ^ rotr(x, 11) ^ rotr(x, 25)
      end

      def self.ch(x, y, z)
        (x & y) ^ (~x & z & MASK)
      end

      def self.maj(x, y, z)
        (x & y) ^ (x & z) ^ (y & z)
      end
    end
  end
end
