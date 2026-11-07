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

SigLIP 2 base (Google's `google/siglip2-base-patch16-224`, Apache-2.0), converted to Core ML by `scripts/convert-siglip.py`: an image encoder (88 MB, 8-bit) and a text encoder (270 MB, mostly its vocabulary), with Gemma's tokenizer. It's too big for the repository, so it's made locally: the first `make app` makes it (`scripts/search-model.sh`: once, into a Python environment of its own in `.build/siglip-venv`, downloading SigLIP 2 and the converter's packages, a few GB, for a few minutes) and every `make app` builds it in. Without Python or the network, the app is built without it and says so, and it's tried again next time; `SEARCH_MODEL=0 make app` skips it. By hand:

```sh
python3 -m venv /tmp/siglip
/tmp/siglip/bin/pip install "torch==2.7.0" "numpy<2.3" transformers coremltools sentencepiece Pillow
/tmp/siglip/bin/python scripts/convert-siglip.py                     # writes models/search/
/tmp/siglip/bin/python scripts/convert-siglip.py --check PICTURE     # and compares it with PyTorch's on a picture
make app                                                             # builds it in (Contents/Resources/Search)
```

The script records reference values (phrases' tokens and embeddings, a picture's embedding) that the Swift side is tested against when the model is present (`swift test --filter SigLIPTests`). A copy of Pond without it searches by what was found and the sentences.

### For releases and CI (not done yet)

Making the model on each machine suits a developer's first build, not releases: the converter's packages are mostly unpinned (only torch and numpy are), so two machines converting a month apart can make slightly different models, and a release's embeddings must stay comparable with those its users' databases already hold; and a clean CI runner would download a few GB and depend on Hugging Face for every release. What releases need instead:

- **One model, made once, published.** The four files (`siglip2-image.mlpackage`, `siglip2-text.mlpackage`, `siglip2-tokenizer.json`, `siglip2.json`) converted on purpose and published as one archive with a version of its own (a GitHub release used only for it, such as `search-model-siglip2-v1`), never remade by a build.
- **Pinned in the repository.** A small lock file (such as `models/search.lock`) naming the archive's URL and SHA-256. `make app` downloads it (about 390 MB, seconds), checks the hash and unpacks it into `models/search/`, and refuses one that doesn't match; converting stays as a fallback for a fork without access, or is dropped.
- **Cached by CI**, keyed by the lock file's hash, so a runner downloads it once.
- **A new version only on purpose.** `scripts/search-model.sh` (or a `--convert` of it) makes a new one: convert, check with `convert-siglip.py --check`, run `SigLIPTests`, publish, bump the lock file. A change of model, or of its conversion, changes its embeddings. The database already keeps the manifest's name beside each embedding (`embedder`, now `SigLIP 2 base`) and the service embeds an event again when it differs; so the published model's name has to carry its version (`SigLIP 2 base v1`), or a new conversion under the same name would be compared with the old one's embeddings.
- **Its licence with it.** SigLIP 2 is Apache-2.0: the archive and the app carry its licence and a NOTICE saying it was converted to Core ML and quantized, and by whom.
- **In the app or on first use**, as the signed release settles (roadmap: A signed, notarized release): built in, a release is about 390 MB bigger; downloaded on first use, the same lock file says what the app fetches and checks.

MobileCLIP, which this was first planned with, is left out: Apple's licence for its weights is for research.

## From the command line

```sh
pond describe                    # the sentences for the last three events (--last N), and how long each took
pond describe EVENT-ID|PICTURE   # for one event, or any picture
pond search "a dog on the couch" # how it's read, then the events, best first, each with its sentence
pond search "…" --plain          # read by the plain rules
pond events                      # each event's sentence under it, once it has one
```

`pond search` asks the running service, as the app does. The service finds the models in the app, or in `POND_SEARCH_MODELS` (a folder, such as the repository's `models/search`, for running it from a build).
