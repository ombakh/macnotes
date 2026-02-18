class Macnotes < Formula
  desc "Transparent macOS menu bar notes app with folders and rich text"
  homepage "https://github.com/ombakh/macnotes"
  head "https://github.com/ombakh/macnotes.git", branch: "main"

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"
    bin.install ".build/release/macnotes"
  end

  test do
    assert_predicate bin/"macnotes", :exist?
  end
end
