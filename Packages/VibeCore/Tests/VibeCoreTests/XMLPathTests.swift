import Foundation
import Testing
@testable import VibeCore

@Suite struct XMLPathTests {
    private let pom = """
    <?xml version="1.0"?>
    <!-- <fake> -->
    <project xmlns="http://maven.apache.org/POM/4.0.0">
      <name>vibe</name>
      <dependencies>
        <dependency>
          <artifactId>a</artifactId>
        </dependency>
        <!-- <dependency> in a comment -->
        <dependency scope="test" note="a > b">
          <artifactId>b</artifactId>
          <version>1.0</version>
        </dependency>
        <dependency/>
      </dependencies>
      <build><![CDATA[<dependency>]]></build>
    </project>
    """

    private func path(at marker: String, offset: Int = 0) -> XMLPath? {
        let text = pom as NSString
        let range = text.range(of: marker)
        precondition(range.location != NSNotFound, marker)
        return XMLPath.at(range.location + offset, in: text)
    }

    @Test func elementsAndSiblingIndexes() throws {
        // In the text of the second <version>: only repeated names get an index.
        let version = try #require(path(at: ">1.0<", offset: 2))
        #expect(version.xpath == "/project/dependencies/dependency[2]/version")
        #expect(version.elements.map(\.step) == ["project", "dependencies", "dependency[2]", "version"])
        #expect(version.attribute == nil)
        // Its element runs from "<version>" through "</version>".
        let text = pom as NSString
        let element = try #require(version.elementRange)
        #expect(text.substring(with: element) == "<version>1.0</version>")
        // The first dependency, in the whitespace of its content.
        #expect(path(at: "<artifactId>a", offset: -1)?.xpath == "/project/dependencies/dependency[1]")
        // A self-closing one, from inside its tag; comments and CDATA don't count.
        #expect(path(at: "<dependency/>", offset: 3)?.xpath == "/project/dependencies/dependency[3]")
        #expect(path(at: "CDATA", offset: 0)?.xpath == "/project/build")
    }

    @Test func attributesAndTagEdges() {
        #expect(path(at: "scope=", offset: 2)?.xpath == "/project/dependencies/dependency[2]/@scope")
        #expect(path(at: "a > b", offset: 2)?.xpath == "/project/dependencies/dependency[2]/@note")
        #expect(path(at: "xmlns=")?.xpath == "/project/@xmlns")
        // On the tag's name: the element itself, no attribute.
        #expect(path(at: "<name>", offset: 2)?.xpath == "/project/name")
        // Right before a tag: still in the parent; inside an end tag: in its element; after it: out.
        #expect(path(at: "<name>")?.xpath == "/project")
        #expect(path(at: "</name>", offset: 3)?.xpath == "/project/name")
        #expect(path(at: "</name>", offset: 7)?.xpath == "/project")
    }

    @Test func outsideTheRoot() {
        #expect(path(at: "<?xml") == nil)
        #expect(path(at: "<fake>", offset: 2) == nil) // in the comment before the root
        #expect(XMLPath.at(0, in: "" as NSString) == nil)
        // Unclosed elements still give a path.
        #expect(XMLPath.at(9, in: "<a>\n  <b>\n    x" as NSString)?.xpath == "/a/b")
    }
}
