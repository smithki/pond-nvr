#!/usr/bin/env python3
"""Whether a new conversion of search's picture model is worth publishing: compares its manifest (siglip2.json) with
the published version's. Each holds the embeddings of the same phrases and picture, as SigLIP 2's own code made them
and (the picture's) as the converted model does; if every one is practically the same, the new model would find
what the old one does, and publishing it would only make every Pond index its events again for nothing.

    python3 scripts/search-model-compare.py OLD/siglip2.json NEW/siglip2.json

Prints each similarity, then worth=true|false and similarity= (the lowest), for GITHUB_OUTPUT.
"""
import json
import sys

# Below this, something real changed: a different model, or a conversion that changes what's found.
SAME = 0.9995


def dot(a, b):
    """The cosine of the angle between two embeddings (stored ones aren't always exactly unit length)."""
    return sum(x * y for x, y in zip(a, b)) / (sum(x * x for x in a) * sum(y * y for y in b)) ** 0.5


def main():
    old, new = (json.load(open(path)) for path in sys.argv[1:3])
    pairs = []
    if old["dimensions"] != new["dimensions"]:
        print("dimensions differ: a different model")
        print("worth=true")
        print("similarity=0")
        return
    olds = {r["text"]: r["embedding"] for r in old.get("references", [])}
    for r in new.get("references", []):
        if r["text"] in olds:
            pairs.append((f"text {r['text']!r}", dot(olds[r["text"]], r["embedding"])))
    for key in ("embedding", "converted"):
        a, b = old.get("pictureReference", {}).get(key), new.get("pictureReference", {}).get(key)
        if a and b:
            pairs.append((f"picture ({key})", dot(a, b)))
    if not pairs:
        print("nothing to compare: publish only after a look")
        print("worth=true")
        print("similarity=0")
        return
    for name, similarity in pairs:
        print(f"{similarity:.6f}  {name}", file=sys.stderr)
    lowest = min(s for _, s in pairs)
    print(f"worth={'true' if lowest < SAME else 'false'}")
    print(f"similarity={lowest:.6f}")


if __name__ == "__main__":
    main()
