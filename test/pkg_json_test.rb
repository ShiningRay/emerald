# frozen_string_literal: true

require 'minitest/autorun'
require 'digest'
require 'emerald'

# E7 · pkg 基础层（docs/PLAN.md §3.10）：Json/Bytes/Sha256 的边界行为。
# Inflate/Zip 的对拍测试在 pkg_zip_test.rb（共用 Zlib fixture 构造器）。
class PkgJsonTest < Minitest::Test
  def test_parse_valid_object_returns_ruby_hash
    h = Emerald::Pkg::Json.parse('{"spec":1,"kind":"app","tags":[1,2],"deep":{"x":true}}')
    assert_kind_of Hash, h
    assert_equal 'app', h['kind']
    assert_equal [1, 2], h['tags']
    assert_equal({ 'x' => true }, h['deep'])
  end

  def test_parse_rejects_non_object_top_level
    e = assert_raises(Emerald::Pkg::Json::Invalid) do
      Emerald::Pkg::Json.parse('[1,2]')
    end
    assert_includes e.message, '顶层必须是 JSON 对象'
  end

  def test_parse_rejects_broken_json
    assert_raises(Emerald::Pkg::Json::Invalid) do
      Emerald::Pkg::Json.parse('{"spec":')
    end
  end

  def test_parse_rejects_non_string
    assert_raises(Emerald::Pkg::Json::Invalid) do
      Emerald::Pkg::Json.parse(42)
    end
  end
end

class PkgBytesTest < Minitest::Test
  def test_from_latin1_binary_string
    bin = [0x00, 0x7f, 0x80, 0xff, 0x41].pack('C*')
    assert_equal [0x00, 0x7f, 0x80, 0xff, 0x41], Emerald::Pkg::Bytes.from_latin1(bin)
  end

  def test_to_utf8_roundtrip_with_multibyte
    text = "中文内容 ✓ Ruby 源码"
    assert_equal text, Emerald::Pkg::Bytes.to_utf8(text.b.bytes)
  end

  def test_to_latin1_roundtrip
    bytes = Array.new(300) { |i| (i * 7 + 3) % 256 }
    assert_equal bytes, Emerald::Pkg::Bytes.from_latin1(Emerald::Pkg::Bytes.to_latin1(bytes))
  end

  def test_to_latin1_chunks_beyond_apply_limit
    bytes = Array.new(0x8000 + 100) { |i| i % 256 } # 跨 String.fromCharCode 分块边界
    assert_equal bytes, Emerald::Pkg::Bytes.from_latin1(Emerald::Pkg::Bytes.to_latin1(bytes))
  end
end

class PkgSha256Test < Minitest::Test
  def known_vector(msg, hex)
    assert_equal hex, Emerald::Pkg::Sha256.hexdigest(msg), "向量失败: #{msg[0, 24].inspect}"
  end

  def test_standard_vectors
    known_vector('', 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855')
    known_vector('abc', 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')
    known_vector('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq',
                 '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1')
    # 112 字节：跨两块（块长边界 55/56/64 的填充路径）
    known_vector('abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmno' \
                 'ijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu',
                 'cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1')
  end

  def test_random_payloads_against_digest
    rng = Random.new(20260915)
    40.times do
      data = rng.bytes(rng.rand(0..1000))
      assert_equal Digest::SHA256.hexdigest(data), Emerald::Pkg::Sha256.hexdigest(data)
    end
  end

  def test_accepts_byte_array_and_binary_string
    data = Random.new(1).bytes(100)
    assert_equal Emerald::Pkg::Sha256.hexdigest(data), Emerald::Pkg::Sha256.hexdigest(data.bytes)
  end

  def test_rejects_out_of_range_bytes
    assert_raises(ArgumentError) { Emerald::Pkg::Sha256.hexdigest([256]) }
    assert_raises(ArgumentError) { Emerald::Pkg::Sha256.hexdigest([-1]) }
  end
end
