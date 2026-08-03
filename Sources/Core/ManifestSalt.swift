// HMAC salt shared with the manifest build tool (.manifest-src/build.mjs in the
// panura repo). Used only to hash the *frame's own hostname* natively and look
// it up in the manifest — it never enters a web view, so a page can't read it.
//
// Committed deliberately: this repo is PRIVATE, and the panura repo already
// commits the same value in .manifest-src/salt.txt. The salt also ends up as a
// string in every build, so a shipped .ipa carries it regardless — it keeps the
// domain list out of a casual fetch of manifest.json, not out of a disassembler.
//
// Two rules:
//  • Keep this byte-identical to .manifest-src/salt.txt, or no site rule matches
//    and detection silently falls back to generic.
//  • If this repo is ever made public, rotate the salt HERE and in the panura
//    repo, and rebuild the manifest.
//
// CI still overrides this file when the MANIFEST_SALT secret is set (see
// .github/workflows/ios-build.yml), so the secret remains the way to rotate
// without a commit.
enum ManifestSalt {
    static let value = "f6c3422c110b4e1d07941a08b6d502476f285b5bacbe977a7ccd0aae2310ee5c"
}
