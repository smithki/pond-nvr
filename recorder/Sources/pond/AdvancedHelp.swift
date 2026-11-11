// `pond advanced`'s own help.

/// `pond advanced`'s own help: its tools are for trying models and checking new versions, not everyday use.
enum AdvancedHelp {
    static let text = """
Usage: pond advanced <command> [options]

Testing tools: for trying detection models and checking a new version against this Pond's own events. Test scenes
are kept with beta and test features and Keep test scenes on (Settings › Advanced).

Detection
  advanced detect FILE.mp4 … [--model ID] [--every S] [--pictures DIR] [--compute all|ane|gpu|cpu]
                                               run a detection model over recordings: how fast, and what it found
                  [--camera ID] [--closer]     with that camera's zones, and as the recorder looks (closer up at motion)
  advanced detect models                       the models there are (built in, and added to the Models folder)

Test scenes
  advanced scenes [FOLDER …] [--model ID] [--compute all|ane|gpu|cpu] [--json]
                                               replay test scenes through this version's detection and score them
                                               (none given: this Pond's own; --json: the scores alone, to share)
"""
}
