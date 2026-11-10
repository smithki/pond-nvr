#!/usr/bin/env python3
"""Converts SigLIP 2 (Google, Apache-2.0) to the Core ML models Pond's search uses: an image encoder and a text
encoder whose embeddings, compared with a dot product, say how well a picture and a phrase go together.

    python3 -m venv /tmp/siglip
    /tmp/siglip/bin/pip install -r scripts/siglip-requirements.txt                                        # (macOS)
    /tmp/siglip/bin/python scripts/convert-siglip.py                    # writes models/search/siglip2-*
    /tmp/siglip/bin/python scripts/convert-siglip.py --check PICTURE    # and checks them against PyTorch

(Pinned in scripts/siglip-requirements.txt: torch 2.14.1 with coremltools 9; numpy below 2.3, whose stricter scalar
conversion coremltools 9 fails on.)

Writes, into models/search/ (too big for the repository, so ignored by git; make app builds them in when they're
there):
    siglip2-image.mlpackage   picture (224×224 RGB) → embedding (768, unit length)
    siglip2-text.mlpackage    token ids (64) → embedding (768, unit length)
    siglip2-tokenizer.json    the text side's tokenizer (Gemma's)
    siglip2.json              the manifest: model, sizes, the logit scale and bias (a match's probability is
                              sigmoid(scale · similarity + bias)), and reference values the Swift side is tested on
"""
import json
import os
import sys

import coremltools as ct
import numpy as np
import torch
from transformers import AutoModel, AutoTokenizer

NAME = "google/siglip2-base-patch16-224"
# The model's revision on Hugging Face (models/search.lock names the published one); its latest without it.
REVISION = os.environ.get("SIGLIP_REVISION") or None
SIZE = 224
TOKENS = 64
# Where it writes (SIGLIP_OUT names another folder, to try a conversion beside the one in use).
OUT = os.environ.get("SIGLIP_OUT") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "models", "search")

# Phrases the reference values are taken for: what search is asked, roughly.
PHRASES = ["a person", "a man in a red jacket", "a delivery truck", "a black cat on the sofa",
           "someone carrying a package to the door", "Two dogs!"]


def converted_picture_embedding(picture):
    """The picture's embedding by the converted image encoder, as Core ML runs it."""
    from PIL import Image as PILImage
    model = ct.models.MLModel(os.path.join(OUT, "siglip2-image.mlpackage"))
    return [round(float(x), 6) for x in model.predict({"image": PILImage.fromarray(picture)})["embedding"][0]]


def gradient_picture():
    """SIZE×SIZE RGB: red rising left to right, green top to bottom, blue at 128."""
    ramp = np.round(np.arange(SIZE) * 255 / (SIZE - 1)).astype(np.uint8)
    picture = np.zeros((SIZE, SIZE, 3), dtype=np.uint8)
    picture[:, :, 0] = ramp[None, :]
    picture[:, :, 1] = ramp[:, None]
    picture[:, :, 2] = 128
    return picture


def pooled(out):
    """The features (newer transformers return them in an output object; older, as they are)."""
    return out.pooler_output if hasattr(out, "pooler_output") else out


def main():
    os.makedirs(OUT, exist_ok=True)
    model = AutoModel.from_pretrained(NAME, revision=REVISION, torch_dtype=torch.float32).eval()
    tokenizer = AutoTokenizer.from_pretrained(NAME, revision=REVISION)

    class Image(torch.nn.Module):
        def __init__(self, m):
            super().__init__()
            self.m = m

        def forward(self, pixels):
            e = pooled(self.m.get_image_features(pixel_values=pixels))
            return e / e.norm(dim=-1, keepdim=True)

    class Text(torch.nn.Module):
        def __init__(self, m):
            super().__init__()
            self.m = m

        def forward(self, ids):
            e = pooled(self.m.get_text_features(input_ids=ids))
            return e / e.norm(dim=-1, keepdim=True)

    # The image encoder takes a picture: Core ML scales its pixels as SigLIP was trained ([-1, 1]); Pond squashes the
    # picture to 224×224 (no crop), as SigLIP 2's processor does.
    pixels = torch.rand(1, 3, SIZE, SIZE) * 2 - 1
    traced = torch.jit.trace(Image(model).eval(), pixels)
    image = ct.convert(traced,
                       inputs=[ct.ImageType(name="image", shape=(1, 3, SIZE, SIZE), scale=2 / 255, bias=[-1, -1, -1],
                                            color_layout=ct.colorlayout.RGB)],
                       outputs=[ct.TensorType(name="embedding")],
                       minimum_deployment_target=ct.target.macOS15, convert_to="mlprogram")
    image = ct.optimize.coreml.linear_quantize_weights(image, ct.optimize.coreml.OptimizationConfig(
        global_config=ct.optimize.coreml.OpLinearQuantizerConfig(mode="linear_symmetric")))
    image.short_description = "SigLIP 2 base (google/siglip2-base-patch16-224, Apache-2.0): image encoder"
    image.save(os.path.join(OUT, "siglip2-image.mlpackage"))

    ids = torch.zeros(1, TOKENS, dtype=torch.int32)
    traced = torch.jit.trace(Text(model).eval(), ids)
    text = ct.convert(traced,
                      inputs=[ct.TensorType(name="ids", shape=(1, TOKENS), dtype=np.int32)],
                      outputs=[ct.TensorType(name="embedding")],
                      minimum_deployment_target=ct.target.macOS15, convert_to="mlprogram")
    text = ct.optimize.coreml.linear_quantize_weights(text, ct.optimize.coreml.OptimizationConfig(
        global_config=ct.optimize.coreml.OpLinearQuantizerConfig(mode="linear_symmetric")))
    text.short_description = "SigLIP 2 base (google/siglip2-base-patch16-224, Apache-2.0): text encoder"
    text.save(os.path.join(OUT, "siglip2-text.mlpackage"))

    tokenizer.backend_tokenizer.save(os.path.join(OUT, "siglip2-tokenizer.json"))

    # Reference values: each phrase's ids (as the model's own tokenizer makes them, padded to 64), and its embedding
    # from PyTorch, at full precision (the Core ML one, quantized, is near it, not equal).
    references = []
    with torch.no_grad():
        for phrase in PHRASES:
            encoded = tokenizer(phrase.lower(), padding="max_length", max_length=TOKENS, truncation=True)["input_ids"]
            embedding = Text(model)(torch.tensor([encoded], dtype=torch.int32))[0]
            references.append({"text": phrase, "ids": encoded, "embedding": [round(float(x), 6) for x in embedding]})

    # And a picture's: one anyone can make again exactly (red across, green down, blue half), at the model's size,
    # so the Swift side's way of giving it pictures (their colours, their scale) is checked too.
    gradient = gradient_picture()
    with torch.no_grad():
        pixels = torch.tensor(gradient.astype(np.float32) / 255 * 2 - 1).permute(2, 0, 1)[None]
        picture = Image(model)(pixels)[0]

    manifest = {
        "name": "SigLIP 2 base", "source": NAME, "license": "Apache-2.0",
        "imageSize": SIZE, "tokens": TOKENS, "dimensions": int(model.config.text_config.hidden_size),
        "padID": int(tokenizer.pad_token_id), "eosID": int(tokenizer.eos_token_id) if tokenizer.eos_token_id is not None else None,
        "lowercase": True,
        "logitScale": float(model.logit_scale.exp()), "logitBias": float(model.logit_bias),
        "references": references,
        # (And as the converted model has it: quantized, it's only near PyTorch's; the Swift side's way of giving it
        # pictures is checked against this one, which it should all but equal.)
        "pictureReference": {"kind": "gradient", "embedding": [round(float(x), 6) for x in picture],
                             "converted": converted_picture_embedding(gradient)},
    }
    with open(os.path.join(OUT, "siglip2.json"), "w") as f:
        json.dump(manifest, f, indent=1)
    print("✓ models/search/: siglip2-image.mlpackage, siglip2-text.mlpackage, siglip2-tokenizer.json, siglip2.json")
    if "--check" in sys.argv:
        check(model, manifest, sys.argv[sys.argv.index("--check") + 1])


def check(model, manifest, picture):
    """The Core ML models against PyTorch's: each phrase's embedding, and a picture's; and the picture against the
    phrases, as a match's probability, for a look at whether it makes sense."""
    from PIL import Image as PILImage
    text = ct.models.MLModel(os.path.join(OUT, "siglip2-text.mlpackage"))
    image = ct.models.MLModel(os.path.join(OUT, "siglip2-image.mlpackage"))
    for r in manifest["references"]:
        got = text.predict({"ids": np.array([r["ids"]], dtype=np.int32)})["embedding"][0]
        print(f"text  {r['text']!r:44} similarity to PyTorch {float(np.dot(got, r['embedding'])):.4f}")
    squashed = PILImage.open(picture).convert("RGB").resize((SIZE, SIZE), PILImage.BICUBIC)
    got = image.predict({"image": squashed})["embedding"][0]
    pixels = torch.tensor(np.asarray(squashed, dtype=np.float32) / 255 * 2 - 1).permute(2, 0, 1)[None]
    with torch.no_grad():
        want = pooled(model.get_image_features(pixel_values=pixels))[0]
        want = (want / want.norm()).numpy()
    print(f"image similarity to PyTorch {float(np.dot(got, want)):.4f}")
    for r in manifest["references"]:
        e = text.predict({"ids": np.array([r["ids"]], dtype=np.int32)})["embedding"][0]
        p = 1 / (1 + np.exp(-(manifest["logitScale"] * float(np.dot(got, e)) + manifest["logitBias"])))
        print(f"  {r['text']!r:44} {p:.3f}")


if __name__ == "__main__":
    sys.exit(main())
