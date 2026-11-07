defmodule YomimaEx.ThumbProxyTest do
  # /thumbnail のプロキシ: 外部ホストへ内部トークンを送らない・HTML を素通ししない、
  # の判断部分（Platform.platform_origin?/1 と Platform.image_media_type/1）の単体テスト。
  use ExUnit.Case, async: false

  alias YomimaEx.Platform

  setup do
    old = System.get_env("PLATFORM_BASE_URL")
    System.put_env("PLATFORM_BASE_URL", "http://localhost:8000")

    on_exit(fn ->
      if old, do: System.put_env("PLATFORM_BASE_URL", old), else: System.delete_env("PLATFORM_BASE_URL")
    end)
  end

  describe "image_media_type/1" do
    test "画像の型だけ通し、パラメータと大文字小文字は正規化する" do
      assert Platform.image_media_type(["image/png"]) == "image/png"
      assert Platform.image_media_type(["image/jpeg"]) == "image/jpeg"
      assert Platform.image_media_type(["image/webp"]) == "image/webp"
      assert Platform.image_media_type(["image/gif"]) == "image/gif"
      assert Platform.image_media_type(["image/png; foo=bar"]) == "image/png"
      assert Platform.image_media_type(["IMAGE/JPEG"]) == "image/jpeg"
      assert Platform.image_media_type("image/png") == "image/png"
    end

    test "HTML・SVG・不明な型・欠落は nil" do
      assert Platform.image_media_type(["text/html"]) == nil
      assert Platform.image_media_type(["text/html; charset=utf-8"]) == nil
      assert Platform.image_media_type(["image/svg+xml"]) == nil
      assert Platform.image_media_type(["application/octet-stream"]) == nil
      assert Platform.image_media_type([]) == nil
      assert Platform.image_media_type(nil) == nil
    end
  end

  describe "platform_origin?/1（thumb URL の宛先判定）" do
    test "プラットフォームのオリジンは true" do
      assert Platform.platform_origin?("http://localhost:8000/api/public/thumb/1/2/3/0")
      assert Platform.platform_origin?("HTTP://LOCALHOST:8000/api/public/thumb/1/2/3/0")
    end

    test "既定ポートの省略は同じオリジンとして扱う" do
      System.put_env("PLATFORM_BASE_URL", "https://plat.example.com")
      assert Platform.platform_origin?("https://plat.example.com/api/public/thumb/1/2/3/0")
      assert Platform.platform_origin?("https://plat.example.com:443/api/public/thumb/1/2/3/0")
      refute Platform.platform_origin?("https://plat.example.com:444/api/public/thumb/1/2/3/0")
    end

    test "外部ホスト・まぎらわしいホスト・userinfo 付きは false" do
      refute Platform.platform_origin?("http://evil.example/api/public/thumb/1/2/3/0")
      refute Platform.platform_origin?("http://localhost:8000.evil.example/api/public/thumb/1/2/3/0")
      refute Platform.platform_origin?("http://localhost:8000@evil.example/api/public/thumb/1/2/3/0")
      refute Platform.platform_origin?("https://localhost:8000/api/public/thumb/1/2/3/0")
      refute Platform.platform_origin?("http://localhost:8000abc/api/public/thumb/1/2/3/0")
    end
  end
end
