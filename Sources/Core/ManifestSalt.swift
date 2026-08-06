// HMAC salt shared with the manifest build tool (.manifest-src/build.mjs in the
// panura repo). Used only to hash the *frame's own hostname* natively and look
// it up in the manifest — it never enters a web view, so a page can't read it.
//
// ⚠️ BURNED — ROTATION PENDING. This repo went PUBLIC on 2026-08-06 while the
// real salt was committed, so this value is readable on GitHub and, via commit
// bafe014, is in the public history permanently. Deleting the line does not
// recover it. Anyone can now hash candidate domains and deanonymise every `id`
// in the deployed manifest, so the hashing currently protects nothing.
//
// Rotation is deliberately deferred until app testing is finished (changing the
// salt mid-test breaks every rule match). When testing is done:
//  1. New random 32-byte hex into .manifest-src/salt.txt in the panura repo.
//  2. Same value into the MANIFEST_SALT secret of THIS repo.
//  3. Blank the literal below to "" so the real salt lives only in the secret —
//     a committed salt in a public repo burns again on the very next push.
//  4. Rebuild the manifest (node .manifest-src/build.mjs) and deploy.
//
// The salt also ends up as a string in every build, so a shipped .ipa carries it
// regardless — even rotated, this keeps the domain list out of a casual fetch of
// manifest.json, not out of a disassembler.
//
// Keep this byte-identical to .manifest-src/salt.txt, or no site rule matches
// and detection silently falls back to generic.
//
// CI still overrides this file when the MANIFEST_SALT secret is set (see
// .github/workflows/ios-build.yml), so the secret remains the way to rotate
// without a commit.
enum ManifestSalt {
    static let value = "f6c3422c110b4e1d07941a08b6d502476f285b5bacbe977a7ccd0aae2310ee5c"
}
