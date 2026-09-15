# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'zlib'
require 'emerald'

# E7 · 字节底座对拍（docs/PLAN.md §3.10 / D5 同款纪律）：
# Inflate/Zip 是自研纯 Ruby 实现，测试侧用 Zlib 现场构造 fixture 对拍。
class PkgInflateTest < Minitest::Test
  I = Emerald::Pkg::Inflate

  def raw_deflate(data, level: 6, strategy: nil)
    z = strategy ? Zlib::Deflate.new(level, -15, 8, strategy) : Zlib::Deflate.new(level, -15)
    begin
      z.deflate(data, Zlib::FINISH)
    ensure
      z.close
    end
  end

  def assert_roundtrip(data, **kw)
    compressed = raw_deflate(data, **kw)
    assert_equal data.bytes, I.run(compressed.bytes),
                 "解压不一致（len=#{data.size}, #{kw.inspect}）"
  end

  def test_stored_blocks_level_zero
    assert_roundtrip('hello deflate', level: 0)
    assert_roundtrip(Random.new(1).bytes(50_000), level: 0)
  end

  def test_text_and_repetitive_payloads
    assert_roundtrip('a' * 10_000)                # 长匹配 + 重叠拷贝
    assert_roundtrip(('ab' * 5_000) + 'x' + ('ab' * 5_000))
    assert_roundtrip(("emerald " * 3_000) + 'END', level: 9)
  end

  def test_binary_all_byte_values
    assert_roundtrip(Array.new(256) { |i| i.chr }.join * 40)
  end

  def test_random_incompressible_large
    assert_roundtrip(Random.new(42).bytes(70_000), level: 1)
  end

  def test_fixed_huffman_strategy
    assert_roundtrip('fixed huffman blocks' * 20, strategy: Zlib::FIXED)
    assert_roundtrip(Random.new(7).bytes(2_000), strategy: Zlib::FIXED)
  end

  def test_empty_payload
    assert_equal [], I.run(raw_deflate('').bytes)
  end

  def test_truncated_stream_raises_corrupt
    e = assert_raises(I::Corrupt) { I.run(raw_deflate('hello world' * 100).bytes[0, 12]) }
    assert_includes e.message, '截断'
  end

  def test_garbage_raises_corrupt
    assert_raises(I::Corrupt) { I.run([0x07, 0xff, 0x00, 0xff, 0x12]) } # 块类型 3
  end
end

class PkgZipTest < Minitest::Test
  Z = Emerald::Pkg::Zip

  # ── fixture 构造：手写最小 zip writer（够测即可）──────
  def u16(v) = [v].pack('v').bytes
  def u32(v) = [v].pack('V').bytes

  def raw_deflate(data, level: 9)
    z = Zlib::Deflate.new(level, -15)
    begin
      z.deflate(data, Zlib::FINISH)
    ensure
      z.close
    end
  end

  # entries: [[name, content|nil]]（content nil 且 name 以 / 结尾 = 目录条目）
  def build_zip(entries, level: 9, flags: 0, comment: '')
    body = []
    central = []
    entries.each do |name, content|
      nb = name.b.bytes
      method = content.nil? || level.zero? ? 0 : 8 # 目录条目按惯例 stored
      raw = content.nil? ? [] : (method.zero? ? content.b.bytes : raw_deflate(content, level: level).bytes)
      crc = content.nil? ? 0 : Zlib.crc32(content)
      usize = content.nil? ? 0 : content.b.bytesize
      lho = body.size

      body += [0x50, 0x4b, 0x03, 0x04] + u16(20) + u16(flags) + u16(method) +
              u16(0) + u16(0) + u32(crc) + u32(raw.size) + u32(usize) +
              u16(nb.size) + u16(0) + nb + raw
      central << [nb, method, raw.size, usize, crc, lho, flags]
    end

    cd_offset = body.size
    central.each do |(nb, method, csize, usize, crc, lho, flags)|
      body += [0x50, 0x4b, 0x01, 0x02] + u16(20) + u16(20) + u16(flags) + u16(method) +
              u16(0) + u16(0) + u32(crc) + u32(csize) + u32(usize) +
              u16(nb.size) + u16(0) + u16(0) + u16(0) + u16(0) + u32(0) + u32(lho) + nb
    end
    cd_size = body.size - cd_offset
    body += [0x50, 0x4b, 0x05, 0x06] + u16(0) + u16(0) + u16(central.size) + u16(central.size) +
            u32(cd_size) + u32(cd_offset) + u16(comment.b.bytesize) + comment.b.bytes
    body
  end

  def names(zip)
    zip.map(&:name)
  end

  # ── Zip ─────────────────────────────────────────────
  def test_stored_and_deflate_entries
    zip = Z.read(build_zip([['a.txt', 'hello zip'], ['b.txt', 'z' * 5_000]], level: 0))
    assert_equal ['a.txt', 'b.txt'], names(zip)
    assert_equal 'hello zip', Emerald::Pkg::Bytes.to_utf8(zip[0].data)
    assert_equal 'z' * 5_000, Emerald::Pkg::Bytes.to_utf8(zip[1].data)
    refute zip[0].directory
  end

  def test_deflate_default_level
    zip = Z.read(build_zip([['src/main.rb', "class Foo\nend\n" * 300]]))
    assert_equal "class Foo\nend\n" * 300, Emerald::Pkg::Bytes.to_utf8(zip[0].data)
  end

  def test_directory_entries_skipped
    zip = Z.read(build_zip([['src/', nil], ['src/main.rb', 'x = 1']]))
    assert_equal ['src/main.rb'], names(zip)
  end

  def test_utf8_names
    zip = Z.read(build_zip([['文档/说明.txt', '内容']]))
    assert_equal '文档/说明.txt', zip[0].name
    assert_equal '内容', Emerald::Pkg::Bytes.to_utf8(zip[0].data)
  end

  def test_not_a_zip
    assert_raises(Z::Corrupt) { Z.read('definitely not a zip'.bytes) }
    assert_raises(Z::Corrupt) { Z.read([0x50, 0x4b, 0x05]) }
  end

  def test_truncated_zip
    full = build_zip([['a.txt', 'hello']])
    assert_raises(Z::Corrupt) { Z.read(full[0, full.size - 8]) }
  end

  def test_encrypted_flag_unsupported
    e = assert_raises(Z::Unsupported) do
      Z.read(build_zip([['a.txt', 'secret']], flags: 0x1))
    end
    assert_includes e.message, '加密'
  end

  def test_zip64_marker_unsupported
    zip = build_zip([['a.txt', 'x']])
    zip[-22 + 16, 4] = [0xffffffff].pack('V').bytes # EOCD cd_offset → ZIP64 标记
    e = assert_raises(Z::Unsupported) { Z.read(zip) }
    assert_includes e.message, 'ZIP64'
  end

  def test_unsupported_compression_method
    zip = build_zip([['a.txt', 'x']])
    cd = find_sub(zip, [0x50, 0x4b, 0x01, 0x02])
    lh = find_sub(zip, [0x50, 0x4b, 0x03, 0x04])
    zip[cd + 10, 2] = u16(99)  # central method
    zip[lh + 8, 2] = u16(99)   # local method
    assert_raises(Z::Unsupported) { Z.read(zip) }
  end

  # 子序列查找（Array#rindex 只匹配单元素，不能用于签名搜索）
  def find_sub(bytes, sig)
    (0...(bytes.size - 3)).reverse_each.find { |i| bytes[i, 4] == sig }
  end
end
