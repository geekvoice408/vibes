import Testing
import Foundation
@testable import ServerLife

/// tests/tags.test.mjs — the query language: what the filter box finds, what
/// a fan-out targets, and what a folder rule claims.
@Suite struct SidebarTagsTests {
    static let hosts: [ServerLife.Host] = [
        sbNode("web-01", ["env": "prod", "role": "web", "aws/Name": "prod-web-01"]),
        sbNode("web-2", ["env": "prod", "role": "web"]),
        sbNode("api-1", ["env": "prod", "role": "api"]),
        sbNode("db-1", ["env": "dev", "role": "db", "teleport.internal/resource-id": "xyz"]),
        sbNode("lone", [:]),
        sbSshHost("plain"),
    ]

    func names(_ q: String) -> [String] {
        let c = Tags.compileQuery(q)
        return Self.hosts.filter(c.match).map { $0.name }
    }

    // labels

    @Test func labelsAreSortedAndInternalOnesKeptOutOfTheWay() {
        let e = Tags.labelEntries(Self.hosts[3])
        #expect(e.map(\.key) == ["env", "role"])
        #expect(e.map(\.value) == ["dev", "db"])
        #expect(Tags.labelCount(Self.hosts[3]) == 2)
        #expect(Tags.labelEntries(Self.hosts[3], includeInternal: true).map(\.key).contains("teleport.internal/resource-id"))
        #expect(Tags.isInternalLabel("teleport.internal/x"))
        #expect(!Tags.isInternalLabel("env"))
    }

    @Test func aLabelWithNoValueSurvivesAsAnEmptyString() {
        #expect(Tags.labelEntries(sbNode("x", ["flag": ""])).map(\.value) == [""])
    }

    @Test func collectTagsCountsEveryValueOfEveryKey() {
        let tags = Tags.collectTags(Self.hosts)
        func count(_ k: String, _ v: String) -> Int? { tags.first { $0.key == k }?.values.first { $0.value == v }?.count }
        #expect(count("env", "prod") == 3)
        #expect(count("role", "web") == 2)
        #expect(count("env", "dev") == 1)
        #expect(tags.map(\.key) == tags.map(\.key).sorted())
    }

    // plain terms

    @Test func anEmptyQueryMatchesEverything() {
        #expect(names("").count == Self.hosts.count)
        #expect(Tags.compileQuery("   ").empty)
    }

    @Test func bareTextMatchesNameLabelsAndAddress() {
        #expect(names("web") == ["web-01", "web-2"])
        #expect(names("rhel") == [])
        #expect(names("db") == ["db-1"])
    }

    @Test func keyEqualsIsExactKeyColonIsContains() {
        #expect(names("env=prod") == ["web-01", "web-2", "api-1"])
        #expect(names("env=pro") == [])
        #expect(names("env:pro") == ["web-01", "web-2", "api-1"])
    }

    @Test func aCommaListIsEither() { #expect(names("env=prod,dev").count == 4) }

    @Test func aBareKeyAsksOnlyThatTheLabelExists() {
        #expect(names("role:") == ["web-01", "web-2", "api-1", "db-1"])
    }

    @Test func aGlobOnEquals() {
        #expect(names("name=web-*") == ["web-01", "web-2"])
        #expect(names("name=*-1") == ["api-1", "db-1"])
    }

    @Test func tagSearchesEveryKeyAndValue() {
        #expect(names("tag:role") == ["web-01", "web-2", "api-1", "db-1"])
        #expect(names("tag:api") == ["api-1"])
    }

    @Test func nonLabelFieldsAreAddressable() {
        #expect(names("cluster=c1").count == 5)
        #expect(names("type=ssh") == ["plain"])
        #expect(names("alias=plain") == ["plain"])
        #expect(names("tunnel=true").count == 5)
    }

    @Test func aLeadingMinusExcludes() { #expect(names("-env=prod") == ["db-1", "lone", "plain"]) }

    @Test func aLabelDoesNotHideAFieldOfTheSameName() {
        #expect(names("name=web-01") == ["web-01"])
        #expect(names("name=prod-web-01") == ["web-01"])
        #expect(names("name:web") == ["web-01", "web-2"])
    }

    @Test func aSuffixOfAPrefixedKeyAnswers() {
        let h = sbNode("e", ["aws/location": "east"])
        #expect(Tags.compileQuery("location=east").match(h))
    }

    // regular expressions

    @Test func tildeIsARegexCaseInsensitive() {
        #expect(names(#"name~^web-\d+$"#) == ["web-01", "web-2"])
        #expect(names("name~^WEB") == ["web-01", "web-2"])
        #expect(names("name~^(web|api)") == ["web-01", "web-2", "api-1"])
    }

    @Test func theBracketsInAPatternBelongToThePattern() {
        #expect(names(#"name~^(web|api)-\d+$"#) == ["web-01", "web-2", "api-1"])
        #expect(names("(name~^web) and env=prod") == ["web-01", "web-2"])
    }

    @Test func aCommaInsideAPatternIsNotAnAlternativeList() {
        #expect(names(#"name~^web-\d{1,2}$"#) == ["web-01", "web-2"])
        #expect(names(#"name~^web-\d{2}$"#) == ["web-01"])
    }

    @Test func aPatternThatWillNotCompileIsReported() {
        let c = Tags.compileQuery("name~[oops")
        #expect(c.error?.contains("will not compile") == true)
        #expect(Tags.regexError("[oops") != nil)
        #expect(Tags.regexError("^ok$") == nil)
        #expect(Tags.regexError("(") == "Invalid regular expression: /(/: Unterminated group")
        #expect(Tags.regexError("[oops")?.hasSuffix("Unterminated character class") == true)
        #expect(Tags.regexError("*a")?.hasSuffix("Nothing to repeat") == true)
    }

    @Test func aRegexCanBeAskedOfLabelsToo() {
        #expect(names("env~^pro") == ["web-01", "web-2", "api-1"])
        #expect(names("tag~^role$") == ["web-01", "web-2", "api-1", "db-1"])
    }

    // boolean logic

    @Test func spaceStillMeansAnd() {
        #expect(names("env=prod role:web") == ["web-01", "web-2"])
        #expect(names("env=prod and role:web") == ["web-01", "web-2"])
    }

    @Test func orNotAndBrackets() {
        #expect(names("role=web or role=db") == ["web-01", "web-2", "db-1"])
        #expect(names("not env=prod") == ["db-1", "lone", "plain"])
        #expect(names("env=prod and (role:web or role:api)") == ["web-01", "web-2", "api-1"])
        #expect(names("env=prod and not name=web-01") == ["web-2", "api-1"])
    }

    @Test func andBindsTighterThanOr() {
        #expect(names("role=db or env=prod and role=api") == ["api-1", "db-1"])
    }

    @Test func operatorsAreCaseInsensitiveAndQuotingTakesOneOut() {
        #expect(names("ENV=PROD AND ROLE:WEB") == ["web-01", "web-2"])
        #expect(names("\"or\"") == [])
        #expect(Tags.isBooleanQuery("a or b"))
        #expect(!Tags.isBooleanQuery("env=prod"))
        #expect(!Tags.isBooleanQuery("\"or\""))
    }

    @Test func aHalfWrittenQueryStillFilters() {
        let c = Tags.compileQuery("env=prod and")
        #expect(c.error != nil)
        #expect(Self.hosts.filter(c.match).map(\.name) == ["web-01", "web-2", "api-1"])
        let c2 = Tags.compileQuery("env=prod and (role:web")
        #expect(c2.error != nil)
        #expect(Self.hosts.filter(c2.match).map(\.name) == ["web-01", "web-2"])
    }

    @Test func aStrayClosingBracketIsAnError() {
        #expect(Tags.compileQuery("env=prod)").error != nil)
    }

    // chip helpers

    @Test func parseQueryReturnsAFlatList() {
        #expect(Tags.parseQuery("env=prod -role:db") == [.keyed("env", "=", "prod"), .keyed("role", ":", "db", neg: true)])
    }

    @Test func termForQuotesAValueWithSpaces() {
        #expect(Tags.termFor("env", "prod") == "env=prod")
        #expect(Tags.termFor("region", "us east") == "\"region=us east\"")
        #expect(Tags.termFor("env", "") == "env:")
    }

    @Test func toggleTermAddsRemovesAndFolds() {
        #expect(Tags.toggleTerm("", "env=prod") == "env=prod")
        #expect(Tags.toggleTerm("env=prod", "env=staging") == "env=prod,staging")
        #expect(Tags.toggleTerm("env=prod,staging", "env=prod") == "env=staging")
        #expect(Tags.toggleTerm("env=prod", "env=prod") == "")
        #expect(Tags.toggleTerm("env=prod role:web", "role:web") == "env=prod")
    }

    @Test func hasTermSeesAValueInsideACommaList() {
        #expect(Tags.hasTerm("env=prod,staging", "env=staging"))
        #expect(!Tags.hasTerm("env=prod,staging", "env=dev"))
        #expect(Tags.hasTerm("env=prod", "env:"))
    }

    @Test func aQuotedValueSurvivesARoundTrip() {
        let q = Tags.toggleTerm("", Tags.termFor("region", "us east"))
        #expect(Tags.hasTerm(q, Tags.termFor("region", "us east")))
        #expect(Tags.compileQuery(q).match(sbNode("e", ["region": "us east"])))
    }
}
