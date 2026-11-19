import SwiftUI

// An AI chat or a prototype builder at work on an answer, in a tab you have
// left: a small spinner at its mark's bottom corner while it is, a blue dot
// once it is done and you haven't come back, and the card's line, "Answering
// · 1m", "Answer ready 2m ago" (docs/tab-cards.md).
//
// Heard from the page itself: a small script on these sites watches the
// site's own Stop control (chat-busy.js). It there, the page is at work; it
// gone, done. One list of what that control is for each site; a site whose
// control isn't found says nothing, and the tab is as it was.
//
// A page out of sight is a hidden page to WebKit: no animation frames, slow
// timers. The script uses neither: a MutationObserver is called as the
// answer's words land, and the control going is a change like those.

@MainActor
enum ChatBusy {
    /// What a site's page is doing, and since when.
    struct Busy: Equatable {
        var since: Date
        /// "Answering", "Researching", "Building".
        var word: String
    }

    /// An answer that came while you were elsewhere.
    struct Done: Equatable {
        var at: Date
        /// "Answer ready", or a builder's "Done".
        var word: String
    }

    /// One site: where its Stop control is, and what its work is called.
    struct Site: Equatable {
        /// Any of these on the page, the page is at work.
        var stop: [String]
        var word: String
        /// Any of these too, the longer kind of work and its word:
        /// ChatGPT's deep research.
        var longer: [String] = []
        var longerWord = ""
        var done: String

        /// What chat-busy.js is given.
        var json: String {
            let object: [String: Any] = ["stop": stop.joined(separator: ", "), "word": word,
                                         "longer": longer.joined(separator: ", "), "longerWord": longerWord]
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
            return String(decoding: data, as: UTF8.self)
        }
    }

    static let chat = "Answering", built = "Building"

    /// Each site's Stop control, as its page draws it while it works. Each
    /// has a saved page in evals/chat-busy/fixtures, the control as the site
    /// had it, to tell when one changes.
    static let sites: [String: Site] = {
        let claude = Site(stop: ["button[aria-label^=\"Stop response\"]", "[data-is-streaming=\"true\"]"],
                          word: chat, done: "Answer ready")
        // Seen live 2026-10-15: data-stop-generating, "Stop generating".
        let chatgpt = Site(stop: ["button[data-stop-generating]", "button[aria-label^=\"Stop generating\"]",
                                  "button[data-testid=\"stop-button\"]", "button[aria-label=\"Stop streaming\"]"],
                           word: chat,
                           longer: ["[data-testid*=\"deep-research\"]", "[data-message-model-slug*=\"research\"]"],
                           longerWord: "Researching", done: "Answer ready")
        // Seen live 2026-10-15: "Stop response (Esc)".
        let perplexity = Site(stop: ["button[aria-label^=\"Stop response\"]", "button[aria-label=\"Stop\"]",
                                     "button[data-testid=\"stop-generating-response-button\"]"],
                              word: chat, done: "Answer ready")
        let v0 = Site(stop: ["button[aria-label=\"Stop\"]", "button[aria-label=\"Stop generating\"]",
                             "button[data-testid=\"stop-button\"]"],
                      word: built, done: "Done")
        let lovable = Site(stop: ["button[aria-label=\"Stop\"]", "button[aria-label=\"Stop generation\"]",
                                  "form button[aria-label^=\"Stop\"]"],
                           word: built, done: "Done")
        let bolt = Site(stop: ["button[aria-label=\"Stop\"]", "button[title=\"Stop\"]",
                               "button[aria-label=\"Stop generation\"]"],
                        word: built, done: "Done")
        return ["claude.ai": claude, "chatgpt.com": chatgpt, "chat.openai.com": chatgpt,
                "perplexity.ai": perplexity, "v0.dev": v0, "v0.app": v0,
                "lovable.dev": lovable, "bolt.new": bolt]
    }()

    /// A --test run's say over which site a page on this Mac's own server
    /// is, so a saved page can stand in for the site (bench chat-busy).
    static var pretend: String?

    /// The site, by its host as PageScripts arms it: lower case, no "www.".
    static func site(_ host: String?) -> Site? {
        guard let host else { return nil }
        if let site = sites[host] { return site }
        if Store.testing, host == "127.0.0.1" || host == "localhost", let pretend { return sites[pretend] }
        return nil
    }

    /// What the page said: at work, with its word, or not.
    static func heard(_ tab: Tab, on: Bool, word: String?, inFront: Bool) {
        if on {
            let word = word.flatMap { $0.isEmpty ? nil : $0 } ?? chat
            if tab.chatBusy == nil {
                tab.chatBusy = Busy(since: Date(), word: word)
            } else if tab.chatBusy?.word != word {
                tab.chatBusy?.word = word
            }
            tab.chatDone = nil
            return
        }
        guard let busy = tab.chatBusy else { return }
        tab.chatBusy = nil
        // Done in front of you: you saw it, nothing to come back to.
        guard !inFront else { return }
        let done = site(PageScripts.host(of: tab.address))?.done
        tab.chatDone = Done(at: Date(), word: done ?? (busy.word == built ? "Done" : "Answer ready"))
    }

    /// The page went: a new document, a tab put to sleep or closed.
    static func left(_ tab: Tab) {
        if tab.chatBusy != nil { tab.chatBusy = nil }
    }
}

/// The mark's bottom corner for a chat at work, the call's dot's place and
/// cut (MarkCorners): the loading ring, small, while it works; a blue dot
/// once it is done and you haven't come back. A call's dot wins over both.
struct ChatCorner: View {
    var tab: Tab

    var body: some View {
        if tab.camera == .none, tab.microphone == .none {
            if tab.chatBusy != nil {
                Ring(size: CaptureDot.size)
                    .frame(width: CaptureDot.size, height: CaptureDot.size)
                    .transition(.opacity.animation(Motion.quick))
            } else if tab.chatDone != nil {
                // Blue, as unread is in Mail and Messages: red is the microphone's.
                Circle()
                    .fill(Color(nsColor: .systemBlue))
                    .frame(width: CaptureDot.size, height: CaptureDot.size)
                    .transition(.scale(scale: 0.4).combined(with: .opacity).animation(Motion.quick))
            }
        }
    }
}
