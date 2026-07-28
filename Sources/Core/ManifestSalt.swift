// HMAC salt shared with the manifest build tool (.manifest-src/build.mjs in the
// private panura repo). Used only to hash the *frame's own hostname* natively and
// look it up in the manifest — it never enters a web view, so a page can't read it.
//
// CI overwrites this file from the `MANIFEST_SALT` GitHub Actions secret before
// building (see .github/workflows/ios-build.yml). This committed value is a
// placeholder so the project compiles; a build without the secret simply matches
// no site rule and detection falls back to generic — never a crash. Keep the
// secret in sync with .manifest-src/salt.txt.
enum ManifestSalt {
    static let value = "DEV_PLACEHOLDER_SALT"
}
