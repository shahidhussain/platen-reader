#!/usr/bin/env python3
"""Builds read aloud's natural-voice pack (docs/read-aloud.md) from pinned
sources, each checked against its SHA-256, into build/kokoro-pack/:

  kokoro-weights.bin   Kokoro-82M v1.0 (hexgrad), Apache-2.0: the weights,
  kokoro-weights.json  converted from the original PyTorch checkpoint (read
                       without PyTorch), weight normalisation folded in, the
                       large ones as 8-bit integers with a scale per row
  config.json       Kokoro's symbol table (hexgrad/Kokoro-82M), Apache-2.0
  us_gold.json …    Misaki's English lexicons (hexgrad/misaki), Apache-2.0
  cmudict.dict      CMU Pronouncing Dictionary, BSD 2-clause
  voices/*.bin      Kokoro voices (onnx-community), Apache-2.0
  LICENSES/         each source's licence, and NOTICE

and build/kokoro-pack.zip with its SHA-256: the file published as a GitHub
release, which the app downloads and pins (KokoroVoiceRelease; see
docs/read-aloud.md, "Hosting the voice").

The app runs the model with its own code on Accelerate (KokoroModel.swift),
which reads kokoro-weights.json for each weight's shape, type and place.

Usage: python3 scripts/make-kokoro-pack.py   (needs numpy)
"""
import hashlib
import json
import os
import pickle
import shutil
import sys
import urllib.request
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "build", "kokoro-pack")
CACHE = os.path.join(ROOT, "build", "kokoro-sources")

ONNX = "https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX/resolve/1939ad2a8e416c0acfeecc08a694d14ef25f2231"
KOKORO = "https://huggingface.co/hexgrad/Kokoro-82M/resolve/f3ff3571791e39611d31c381e3a41a3af07b4987"
MISAKI = "https://raw.githubusercontent.com/hexgrad/misaki/fba1236595f2d2bf21d414ba6e57d25256afada3"
CMUDICT = "https://raw.githubusercontent.com/cmusphinx/cmudict/74790861f652b15e4ac49015a90074ad62a27690"

# Kokoro's weights, converted rather than copied into the pack.
CHECKPOINT = ("kokoro-v1_0.pth", f"{KOKORO}/kokoro-v1_0.pth", "496dba118d1a58f5f3db2efc88dbdc216e0483fc89fe6e47ee1f2c53f18ad1e4")

# (file in the pack, source URL, SHA-256)
FILES = [
    ("config.json", f"{KOKORO}/config.json", "5abb01e2403b072bf03d04fde160443e209d7a0dad49a423be15196b9b43c17f"),
    ("us_gold.json", f"{MISAKI}/misaki/data/us_gold.json", "dc414872a49a28ae6c141463d502fd945f3b2fde040484fdc47d00cc4612686f"),
    ("us_silver.json", f"{MISAKI}/misaki/data/us_silver.json", "de8f67be911bb6c659187b4a65fd966b6a30e56350e0f790d763210b053ac475"),
    ("gb_gold.json", f"{MISAKI}/misaki/data/gb_gold.json", "29e62f4b60261c88f7f3c2c7811ca3825978948090b72d2b27d565b729282f71"),
    ("gb_silver.json", f"{MISAKI}/misaki/data/gb_silver.json", "48131e2d92ccc41655f4543e87e0f938e71463eb5a54be7f0693bb712ebb6bce"),
    ("cmudict.dict", f"{CMUDICT}/cmudict.dict", "81917843c7f44ce2b094ac63873c2c7a4cf802040792c455ba3ca406891c3d22"),
    ("voices/bf_emma.bin", f"{ONNX}/voices/bf_emma.bin", "669fe0647f9dd04fcab92f1439a40eeb4c8b4ab1f82e4996fe3d918ce4a63b73"),
    ("voices/bf_isabella.bin", f"{ONNX}/voices/bf_isabella.bin", "3754352c4aaa46d17f27654ab7518d65b62ad6163a0f55a5f4330c2da2c4e94f"),
    ("voices/bm_george.bin", f"{ONNX}/voices/bm_george.bin", "c4b235a4c1f2cd3b939fed08b899ce9385638b763f7b73a59616c4fc9bd6c9bc"),
    ("voices/bm_lewis.bin", f"{ONNX}/voices/bm_lewis.bin", "b8f671cef828c30e66fdf0b0756a76bba58f6bb3398cbbf27058642acbcedb97"),
    ("voices/af_heart.bin", f"{ONNX}/voices/af_heart.bin", "d583ccff3cdca2f7fae535cb998ac07e9fcb90f09737b9a41fa2734ec44a8f0b"),
    ("voices/af_bella.bin", f"{ONNX}/voices/af_bella.bin", "f69d836209b78eb8c66e75e3cda491e26ea838a3674257e9d4e5703cbaf55c8b"),
    ("voices/am_michael.bin", f"{ONNX}/voices/am_michael.bin", "1d1f21dd8da39c30705cd4c75d039d265e9bc4a2a93ed09bc9e1b1225eb95ba1"),
    ("voices/am_fenrir.bin", f"{ONNX}/voices/am_fenrir.bin", "c27989f741f7ee34d273a39d8a595cc0837d35f5ced9a29b7cc162614616df43"),
]

LICENSES = [
    ("LICENSES/misaki-LICENSE", f"{MISAKI}/LICENSE"),
    ("LICENSES/cmudict-LICENSE", f"{CMUDICT}/LICENSE"),
]

NOTICE = """Platen Reader: natural voice for read aloud

Kokoro-82M v1.0 (hexgrad), weights and voices, Apache License 2.0;
  the weights converted to 8-bit integers (kokoro-weights.bin); the
  voices as exported by onnx-community (voices/*.bin).
  https://huggingface.co/hexgrad/Kokoro-82M
  https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX
Misaki English lexicons (hexgrad/misaki), Apache License 2.0.
  https://github.com/hexgrad/misaki
CMU Pronouncing Dictionary, Copyright (C) 1993-2015 Carnegie Mellon
  University, BSD 2-clause licence (LICENSES/cmudict-LICENSE).
  https://github.com/cmusphinx/cmudict

Nothing here is GPL. No eSpeak NG data is used.
"""


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch(url, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with urllib.request.urlopen(url) as response, open(path, "wb") as f:
        shutil.copyfileobj(response, f)


def read_checkpoint(path):
    """The checkpoint's tensors as numpy arrays, by name, read without
    PyTorch: a zip holding a pickle (refusing anything but tensors and
    dictionaries) and the raw float32 data."""
    import numpy as np
    z = zipfile.ZipFile(path)
    prefix = z.namelist()[0].split("/")[0]

    class Storage:
        def __init__(self, key, kind):
            self.key, self.kind = key, kind

    def rebuild(storage, offset, size, stride, *_):
        assert storage.kind == "FloatStorage", storage.kind
        data = np.frombuffer(z.read(f"{prefix}/data/{storage.key}"), dtype="<f4")
        return np.lib.stride_tricks.as_strided(data[offset:], shape=tuple(size),
                                               strides=tuple(4 * s for s in stride)).copy()

    class Unpickler(pickle.Unpickler):
        def find_class(self, module, name):
            if name == "_rebuild_tensor_v2":
                return rebuild
            if module == "torch" and name.endswith("Storage"):
                return name
            if module == "collections" and name == "OrderedDict":
                import collections
                return collections.OrderedDict
            raise pickle.UnpicklingError(f"refusing {module}.{name}")

        def persistent_load(self, pid):
            return Storage(pid[2], pid[1])

    state = Unpickler(z.open(f"{prefix}/data.pkl")).load()
    tensors = {}
    for part, weights in state.items():
        for key, value in weights.items():
            # "module.encode.conv1.weight_v" in "decoder" → "decoder.encode.conv1.weight_v"
            tensors[f"{part}.{key.removeprefix('module.')}"] = value
    return tensors


def convert_weights(checkpoint, out):
    """Writes kokoro-weights.bin and .json: weight normalisation folded in
    (w = g · v / ‖v‖, the norm over every dimension but the first), and each
    weight of two or more dimensions with at least 4096 values stored as
    int8 with a float32 scale per row; the rest as float32. Each tensor
    starts on a 16-byte boundary."""
    import numpy as np
    tensors = read_checkpoint(checkpoint)
    folded = {}
    for name, value in tensors.items():
        if name.endswith(".weight_g"):
            continue
        if name.endswith(".weight_v"):
            g = tensors[name[:-1] + "g"]
            norm = np.sqrt((value.reshape(value.shape[0], -1) ** 2).sum(axis=1)).reshape(g.shape)
            folded[name[:-2]] = (g * value / norm).astype(np.float32)
        else:
            folded[name] = value.astype(np.float32)
    index = {}
    with open(os.path.join(out, "kokoro-weights.bin"), "wb") as f:
        def align():
            f.write(b"\0" * (-f.tell() % 16))
        for name in sorted(folded):
            value = folded[name]
            align()
            entry = {"shape": list(value.shape), "offset": f.tell()}
            if value.ndim >= 2 and value.size >= 4096:
                rows = value.reshape(value.shape[0], -1)
                scales = np.abs(rows).max(axis=1) / 127
                scales[scales == 0] = 1
                f.write(np.round(rows / scales[:, None]).clip(-127, 127).astype(np.int8).tobytes())
                align()
                entry.update(type="q8", scales=f.tell())
                f.write(scales.astype("<f4").tobytes())
            else:
                entry["type"] = "f32"
                f.write(value.astype("<f4").tobytes())
            index[name] = entry
    with open(os.path.join(out, "kokoro-weights.json"), "w") as f:
        json.dump(index, f, indent=0, sort_keys=True)
    print(f"{len(index)} weights converted")


def cached(name, url, expected):
    path = os.path.join(CACHE, name)
    if not os.path.exists(path) or sha256(path) != expected:
        print(f"fetching {name}")
        fetch(url, path)
    actual = sha256(path)
    if actual != expected:
        sys.exit(f"{name}: SHA-256 {actual}, expected {expected}")
    return path


def main():
    try:
        import numpy  # noqa: F401
    except ImportError:
        sys.exit("needs numpy (python3 -m pip install numpy)")
    shutil.rmtree(OUT, ignore_errors=True)
    os.makedirs(OUT)
    convert_weights(cached(*CHECKPOINT), OUT)
    for name, url, expected in FILES:
        target = os.path.join(OUT, name)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copyfile(cached(name, url, expected), target)
    for name, url in LICENSES:
        fetch(url, os.path.join(OUT, name))
    # Kokoro's licence is Apache-2.0, the same text as misaki's.
    shutil.copyfile(os.path.join(OUT, "LICENSES/misaki-LICENSE"), os.path.join(OUT, "LICENSES/Apache-2.0"))
    with open(os.path.join(OUT, "NOTICE"), "w") as f:
        f.write(NOTICE)

    archive = os.path.join(ROOT, "build", "kokoro-pack.zip")
    if os.path.exists(archive):
        os.remove(archive)
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as z:
        for folder, _, files in os.walk(OUT):
            for file in sorted(files):
                path = os.path.join(folder, file)
                z.write(path, os.path.relpath(path, OUT))
    total = sum(os.path.getsize(os.path.join(d, f)) for d, _, fs in os.walk(OUT) for f in fs)
    print(f"{OUT}: {total / 1e6:.1f} MB")
    print(f"{archive}: {os.path.getsize(archive) / 1e6:.1f} MB, SHA-256 {sha256(archive)}")


if __name__ == "__main__":
    main()
