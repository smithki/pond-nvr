// What the commands need from the terminal. The executable provides a real one; tests a recording one.

public protocol Console: AnyObject {
    /// Normal output (stdout).
    func out(_ line: String)
    /// Warnings and errors (stderr).
    func err(_ line: String)
    /// True when a person is at the terminal, so prompting is possible.
    var interactive: Bool { get }
    /// Asks for a secret without echoing it. Nil if there is no terminal or input ended.
    func readSecret(_ prompt: String) -> String?
    /// Asks for a line. Nil if there is no terminal or input ended.
    func ask(_ prompt: String) -> String?
    /// All of standard input, for --password-stdin.
    func readAllInput() -> String?
}
