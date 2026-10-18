import Foundation

let updaterTests: [(String, @MainActor () throws -> Void)] = [
    ("сравнение версий", {
        expect(Updater.isNewer("0.4.0", than: "0.3.0"))
        expect(Updater.isNewer("0.10.0", than: "0.9.9"))
        expect(Updater.isNewer("1.0", than: "0.99.1"))
        expect(!Updater.isNewer("0.3.0", than: "0.3.0"))
        expect(!Updater.isNewer("0.3", than: "0.3.0"))
        expect(!Updater.isNewer("0.2.9", than: "0.3.0"))
    }),
    ("пререлизы по SemVer", {
        expect(Updater.isNewer("0.6.0", than: "0.6.0-beta.2"))
        expect(!Updater.isNewer("0.6.0-beta.2", than: "0.6.0"))
        expect(Updater.isNewer("0.6.0-beta.2", than: "0.6.0-beta.1"))
        expect(Updater.isNewer("0.6.0-beta.10", than: "0.6.0-beta.9"))
        expect(Updater.isNewer("0.6.0-rc.0", than: "0.6.0-beta.5"))
        expect(Updater.isNewer("0.6.0-beta.0", than: "0.5.0"))
        expect(Updater.isNewer("0.6.0-beta.1", than: "0.6.0-beta"))
        expect(!Updater.isNewer("0.6.0-beta.1", than: "0.6.0-beta.1"))
        expect(!Updater.isNewer("0.6.0+build.5", than: "0.6.0"))
    }),
]
