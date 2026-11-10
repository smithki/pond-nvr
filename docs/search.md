# Search

The Events view's search field takes a question in plain words: "cats in the living room last night", "a man in a red jacket", "packages this week", "who rang the doorbell yesterday", "a dog on the couch". The answer is the events that fit it, best first when it says how things looked. Everything is done on the Mac: nothing about your cameras' pictures, or your questions, goes anywhere else.

## How a question is read

The question is read into its parts, each shown as a chip under the field. Take one off with its × to widen the search without asking again:

- **Kinds and things**: people, vehicles, bikes, animals, packages, left items, the doorbell; and particular ones in the detector's words (cat, dog, car, truck, bus, bicycle…).
- **Cameras and zones**, by their names in the settings.
- **When**: "today", "yesterday afternoon", "last night", "this week", "last week", "on Monday", "Friday night", "in the last 3 hours", "two days ago"; or a part of every day ("at night", "in the mornings").
- **How they looked or what they did**: what's left when the rest is taken out ("a man in a red jacket", "carrying a white bag").

With Apple Intelligence on, the Mac's own language model reads the question (✦ beside the chips), which handles words the plain rules don't know ("a mail carrier"). What it reads is checked against the question: a camera, zone or time counts only if the question names it, and times are reckoned by Pond, never by the model. Without Apple Intelligence, plain rules read it the same way, minus the words they don't know.

## How events are matched

Kinds, things, cameras, zones and time filter the events. How they looked ranks them, by two things together:

- **The picture**: each event's picture, and a close-up of what began it, embedded by SigLIP 2; the question's words embedded alike; how well they go together, as SigLIP's own probability.
- **The sentence**: each event's description, written by the Mac's own model from its picture (a close-up too), with what the detector found as a hint. The words of the question it has, more for those side by side as they were asked.

An event is kept if either says it fits. With neither to go by yet (no picture model, no sentences), the question's words of how things looked aren't used, and the chips say so.

The sentences also stand for the events across the app: on their cards, in their details, on the timeline. Until an event has one (or without Apple Intelligence), it shows what was found ("A person and a dog.").

## Where it's done

In Pond's background service, which keeps what search takes ready: the words' model loaded, the Mac's language model warmed as it starts (with one question asked unseen, as being told to get ready isn't enough). The app's search field and `pond search` ask it over its control socket (`"action": "search"`), and get back how the question was read and the events' ids, best first. A search answers in well under a second, the first after the service starts too. With the service stopped, the search field says search needs it.

The words' model runs on the CPU (half a second to load, milliseconds a question); the picture model on the Neural Engine, in the service only, where readying it for the Neural Engine (some seconds, the first time each program loads it after an install or update) keeps no one waiting.

## Understanding events

The service describes and embeds each event once it ends, one at a time in the background, newest first, and works back through the events kept before, so search reaches as far back as events are kept. Settings › General › Descriptions and search says whether descriptions are being written (and why not: Apple Intelligence off, with Open Settings… to turn it on; still getting ready; a Mac that can't run it) and how many events are done. A sentence takes about a second on an M6; the first after starting, a few.

Sentences come from the on-device Foundation Models only, never Private Cloud Compute. They describe what can be seen, never who someone is.

## The picture model

SigLIP 2 base (Google's `google/siglip2-base-patch16-224`, Apache-2.0), converted to Core ML by `scripts/convert-siglip.py`: an image encoder (88 MB, 8-bit) and a text encoder (270 MB, mostly its vocabulary), with Gemma's tokenizer. It's too big for the repository, and it's converted once and published, not by each build ([Published versions](#published-versions)): builds download it, and Pond itself downloads it on first run. Converting one by hand, to work on the conversion (`SEARCH_MODEL=convert make app` does the same, into `.build/siglip-venv`), with the packages the published one was made with:

```sh
python3 -m venv /tmp/siglip
/tmp/siglip/bin/pip install -r scripts/siglip-requirements.txt   # torch 2.14.1, coremltools 9, numpy below 2.3
/tmp/siglip/bin/python scripts/convert-siglip.py                     # writes models/search/
/tmp/siglip/bin/python scripts/convert-siglip.py --check PICTURE     # and compares it with PyTorch's on a picture
make app                                                             # builds it in (Contents/Resources/Search)
```

The script records reference values (phrases' tokens and embeddings, a picture's embedding) that the Swift side is tested against when the model is present (`swift test --filter SigLIPTests`). A copy of Pond without it searches by what was found and the sentences.

### Published versions

The model Pond downloads is made once and published, never remade by a build: two conversions a month apart can
differ slightly, and a version's embeddings must stay comparable with those every Pond's database holds.

- **What a version is.** One Apple Archive of the folder Pond loads (the two models compiled for Core ML,
  `siglip2.json`, the tokenizer), with SigLIP 2's licence and a notice of how it was made, published as a release
  of [pond-models](https://github.com/smithki/pond-models) (`siglip2-v1`, …) and never changed after.
  `scripts/search-model-package.sh` makes it.
- **What it was made from**, in `models/search.lock`: SigLIP 2's revision on Hugging Face, the converter's SHA-256,
  its packages (`scripts/siglip-requirements.txt`, every one pinned, and its SHA-256), and the archive's URL, size
  and SHA-256.
- **Where Pond learns of it**: pond.camera's manifest, `pond.camera/api/search-model`, built with the site from
  `site/data/search-models.json`. Each entry (newest first) names a version, its format (the folder's layout) and the
  first Pond that reads it (`minimumApp`), its size and SHA-256, where to download it, and a signature.
- **Why Pond trusts it**: the signature. Pond carries the model signing key's public half
  (`models/search-signing.pub`: `YElDtEdmCu8Lu4WWaU4RHAxrtd86pvwdd/p/BDSPuUk=`, Ed25519) and takes an entry only if
  its signature verifies, then a file only if its SHA-256 is the entry's. Neither pond.camera nor the file's host can
  hand Pond a model the key didn't sign. What's signed is the entry's fields, one per line, in this order, so no JSON
  formatting changes it (`scripts/search-model-sign.swift`):

  ```
  pond search model
  id: siglip2-v1
  name: SigLIP 2 base
  format: 1
  minimumApp: 0.2.0
  size: 350310687
  sha256: eaae1d98dc24c66e725aa662b8909506ace61df1df83204fbf312cf62e1347b9
  ```

  The key is only in CI's `models` environment (and its owner's password manager): [ci-security.md](ci-security.md).
- **A new version, only when it's worth it.** The search model workflow (`.github/workflows/search-model.yml`)
  checks monthly whether anything the published version was made from has changed (`scripts/search-model-check.sh`).
  If something has, it converts again on macOS, runs `SigLIPTests`, and compares the new model's reference
  embeddings with the published one's (`scripts/search-model-compare.py`): when every one is practically the same
  (cosine 0.9995 or more), it publishes nothing, since a new version makes every Pond index its events again. When
  it's a real change, it publishes the archive to pond-models, signs its entry into the manifest
  (`scripts/search-model-publish.sh`), and opens a pull request with the manifest and the lock. No Pond uses it
  until that's merged, which deploys pond.camera. A new version's name carries its number (`SigLIP 2 base v2`):
  the database keeps the model's name beside each embedding and embeds an event again when it differs.
- **Its licence with it.** SigLIP 2 is Apache-2.0: each archive carries the licence, and its `NOTICE` says it was
  converted to Core ML and quantized, from which revision, and with what.
- **In builds**: `make app` downloads the published version `models/search.lock` names into `models/search/`
  (once, about 350 MB; `scripts/model-fetch.sh`, checked against its SHA-256) and builds it in, for development.
  `SEARCH_MODEL=convert make app` converts one on this Mac instead, at the lock's revision with the lock's packages,
  for working on the conversion. A release leaves it out (`SEARCH_BUILT_IN=0`): Pond downloads it.
- **Downloaded by Pond**: the service asks pond.camera once a week (`searchModelUpdates`, on unless set off), or when
  asked (`search-model.check` on its control socket: Settings › Search, Check for Updates), and if the version it
  should use (signed, in a format it reads, for its version) isn't on the Mac, downloads it into
  `~/Library/Application Support/Pond/Search/<id>/`: from where it got to if a download stopped, its size and
  SHA-256 checked against the signed entry, unpacked, and only then put in place (`SearchModelUpdater`). What it's
  doing is in `search-model-status.json` beside the settings, for the app. It asks for nothing but the manifest and
  the file: no cookies, nothing about the Mac or its owner. Not in demo mode.
- **Switching to a new version**: once one's in place, the service embeds events' pictures by it, every event again,
  newest first (each event's embedding keeps the name of the version that made it). Meanwhile search embeds the
  question by each version events are still embedded by, and compares each event by its own, so it keeps finding
  what it did; what's said of events ("this wasn't anything") is compared only with pictures embedded by the same
  version. Once every event is embedded by the new one, the feedback's embeddings are brought over to it (those whose
  events are gone are dropped: their learnt rules stay, not their likeness), and the older downloaded versions,
  used by nothing now, are deleted.

## From the command line

```sh
pond describe                    # the sentences for the last three events (--last N), and how long each took
pond describe EVENT-ID|PICTURE   # for one event, or any picture
pond search "a dog on the couch" # how it's read, then the events, best first, each with its sentence
pond search "…" --plain          # read by the plain rules
pond events                      # each event's sentence under it, once it has one
```

`pond search` asks the running service, as the app does. The service finds the models in the app, or in `POND_SEARCH_MODELS` (a folder, such as the repository's `models/search`, for running it from a build).
