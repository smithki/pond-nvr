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

## Understanding events

The service describes and embeds each event once it ends, one at a time in the background, newest first, and works back through the events kept before, so search reaches as far back as events are kept. Settings › General › Descriptions and search says whether descriptions are being written (and why not: Apple Intelligence off, with Open Settings… to turn it on; still getting ready; a Mac that can't run it) and how many events are done. A sentence takes about a second on an M6; the first after starting, a few.

Sentences come from the on-device Foundation Models only, never Private Cloud Compute. They describe what can be seen, never who someone is.

## The picture model

SigLIP 2 base (Google's `google/siglip2-base-patch16-224`, Apache-2.0), converted to Core ML by `scripts/convert-siglip.py`: an image encoder (88 MB, 8-bit) and a text encoder (270 MB, mostly its vocabulary), with Gemma's tokenizer. It's too big for the repository, so it's made locally and built into the app when it's there:

```sh
python3 -m venv /tmp/siglip
/tmp/siglip/bin/pip install "torch==2.7.0" "numpy<2.3" transformers coremltools sentencepiece Pillow
/tmp/siglip/bin/python scripts/convert-siglip.py                     # writes models/search/
/tmp/siglip/bin/python scripts/convert-siglip.py --check PICTURE     # and compares it with PyTorch's on a picture
make app                                                             # builds it in (Contents/Resources/Search)
```

The script records reference values (phrases' tokens and embeddings, a picture's embedding) that the Swift side is tested against when the model is present (`swift test --filter SigLIPTests`). A copy of Pond without it searches by what was found and the sentences.

MobileCLIP, which this was first planned with, is left out: Apple's licence for its weights is for research.

## From the command line

```sh
pond describe                    # the sentences for the last three events (--last N), and how long each took
pond describe EVENT-ID|PICTURE   # for one event, or any picture
pond search "a dog on the couch" # how it's read, then the events, best first, each with its sentence
pond search "…" --plain          # read by the plain rules
pond events                      # each event's sentence under it, once it has one
```

`pond search` uses the app's picture model, or `POND_SEARCH_MODELS` (a folder, such as the repository's `models/search`).
