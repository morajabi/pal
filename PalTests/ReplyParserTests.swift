import Testing

@Suite struct ReplyParserTests {
    @Test func splitsSpokenAndDetail() {
        let r = ParsedReply.parse("About **125 g** per cup.\n---\n- Spooned: 120 g\n- Scooped: 140 g", final: true)
        #expect(r.spoken == "About 125 g per cup.")
        #expect(r.detail == "- Spooned: 120 g\n- Scooped: 140 g")
        #expect(r.spokenComplete)
    }

    @Test func streamingWithoutSeparatorIsIncomplete() {
        let r = ParsedReply.parse("About 125", final: false)
        #expect(r.spoken == "About 125")
        #expect(!r.spokenComplete)
    }

    @Test func fallsBackToFirstSentenceWhenFormatIgnored() {
        let r = ParsedReply.parse("It's 3 teaspoons. That's 15 mL.", final: true)
        #expect(r.spoken == "It's 3 teaspoons.")
        #expect(r.detail == "That's 15 mL.")
    }

    @Test func stripsMarkdownForSpeech() {
        #expect(ParsedReply.plain("See [the docs](https://x.y) and **bold** `code`") == "See the docs and bold code")
    }
}
