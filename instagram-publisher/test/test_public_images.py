import io
import unittest
import urllib.request
from PIL import Image

CASES = {
  "SHAKIRA": "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/trends/instagram-images/ig-3ff255e46d90-r1-3efa0c8a287a.jpg",
  "REAL_MADRID": "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/ttittulares/instagram-images/ig-1dc952e6340e-r1-2d9b8fae4f17.jpg",
}

class ImageAvailabilityTest(unittest.TestCase):
    def test_public_instagram_jpegs(self):
        for label, url in CASES.items():
            with self.subTest(label=label):
                req = urllib.request.Request(url, headers={"User-Agent": "TTActualidad-image-diagnostic"})
                with urllib.request.urlopen(req, timeout=30) as resp:
                    status = resp.status
                    mime = resp.headers.get("Content-Type", "")
                    data = resp.read(5000000)
                is_jpeg = data.startswith(bytes((255,216,255)))
                print("INSTAGRAM_ASSET", label, "HTTP", status, "MIME", mime,
                      "BYTES", len(data), "JPEG", is_jpeg, flush=True)
                self.assertEqual(status, 200)
                self.assertTrue(is_jpeg)
                with Image.open(io.BytesIO(data)) as image:
                    print("INSTAGRAM_IMAGE", label, image.format, image.size, flush=True)
                    self.assertEqual(image.format, "JPEG")
                    self.assertGreaterEqual(image.width, 320)
                    self.assertGreaterEqual(image.height, 320)
