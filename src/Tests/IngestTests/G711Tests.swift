import Testing
@testable import Ingest

/// G.711 as ITU-T defines it: the values every decoder expects for silence and the loudest samples.
@Suite struct G711Tests {
    @Test func muLaw() {
        #expect(G711.muLaw(0) == 0xFF)
        #expect(G711.muLaw(.max) == 0x80)
        #expect(G711.muLaw(-.max) == 0x00)
        // Louder, further from silence, on each side.
        #expect(G711.muLaw(1000) < G711.muLaw(100))
        #expect(G711.muLaw(-1000) < G711.muLaw(-100))
    }

    @Test func aLaw() {
        #expect(G711.aLaw(0) == 0xD5)
        #expect(G711.aLaw(.max) == 0xAA)
        #expect(G711.aLaw(.min) == 0x2A)
    }
}
