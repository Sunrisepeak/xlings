// tests/unit/test_xim_overlay.cpp — xlings.core.xim.overlay: provenance,
// status classification (Unique/Identical/Modified/Behind), and the GC that
// removes overlay recipes byte-identical to the synced index.
//
// Context: `config --add-xpkg` writes into a local index directory with no
// attribution and no way to list, attribute, or clear what has accumulated
// there. On a real machine 159 recipes had built up this way, 157 of them
// byte-identical to what the synced index now ships. This is the module
// that gives that overlay a provenance record and a status question.

#include <gtest/gtest.h>

import std;
import xlings.core.xim.overlay;
import xlings.platform;

namespace overlay = xlings::xim::overlay;
namespace fs = std::filesystem;

namespace {

fs::path make_temp_dir(std::string_view tag) {
    auto root = fs::temp_directory_path()
        / std::format("xlings-overlay-test-{}-{}", tag,
                      std::chrono::steady_clock::now()
                          .time_since_epoch().count());
    fs::create_directories(root);
    return root;
}

// Every platform gets the same version — real recipes do this too (see
// windows-acp.lua / the entry_binary_and_isolation_test.sh fixtures) so a
// unit test doesn't have to special-case the build host's platform.
std::string recipe_lua(std::string_view name, std::string_view version,
                       std::string_view extraComment = "") {
    return std::format(R"(package = {{
    spec = "1",
    name = "{0}",
    description = "overlay test fixture{1}",
    type = "config",
    archs = {{"x86_64"}},
    status = "dev",
    xpm = {{
        linux   = {{ ["latest"] = {{ ref = "{2}" }}, ["{2}"] = {{}} }},
        macosx  = {{ ["latest"] = {{ ref = "{2}" }}, ["{2}"] = {{}} }},
        windows = {{ ["latest"] = {{ ref = "{2}" }}, ["{2}"] = {{}} }},
    }},
}}
function install() return true end
function config() return true end
function uninstall() return true end
)", name, extraComment, version);
}

void write_recipe(const fs::path& dir, std::string_view name,
                  std::string_view version, std::string_view extraComment = "") {
    auto file = overlay::recipe_path(dir, name);
    fs::create_directories(file.parent_path());
    xlings::platform::write_string_to_file(file.string(),
        recipe_lua(name, version, extraComment));
}

} // namespace

// ── file_sha256 / recipe_path ───────────────────────────────────────

TEST(OverlayPaths, RecipePathIsLetterBucketed) {
    auto root = make_temp_dir("paths");
    EXPECT_EQ(overlay::recipe_path(root, "alpha"),
              root / "pkgs" / "a" / "alpha.lua");
    fs::remove_all(root);
}

TEST(OverlaySha256, MissingFileIsEmpty) {
    auto root = make_temp_dir("sha-missing");
    EXPECT_EQ(overlay::file_sha256(root / "nope.lua"), "");
    fs::remove_all(root);
}

TEST(OverlaySha256, SameBytesSameHash) {
    auto root = make_temp_dir("sha-same");
    write_recipe(root, "alpha", "1.0.0");
    auto a = overlay::recipe_path(root, "alpha");
    auto b = root / "copy.lua";
    fs::copy_file(a, b);
    auto ha = overlay::file_sha256(a);
    auto hb = overlay::file_sha256(b);
    EXPECT_FALSE(ha.empty());
    EXPECT_EQ(ha, hb);
    fs::remove_all(root);
}

// ── load / save round trip ───────────────────────────────────────────

TEST(OverlayLoadSave, MissingFileIsEmptyMap) {
    auto root = make_temp_dir("load-missing");
    auto entries = overlay::load(root);
    EXPECT_TRUE(entries.empty());
    fs::remove_all(root);
}

TEST(OverlayLoadSave, LoadSaveRoundTrip) {
    auto root = make_temp_dir("roundtrip");
    std::map<std::string, overlay::Entry> entries;
    entries["alpha"] = overlay::Entry{
        .name = "alpha", .source = "/some/path/alpha.lua",
        .addedAt = "2026-09-12T00:00:00Z", .sha256 = "deadbeef",
        .version = "1.0.0",
    };
    entries["beta"] = overlay::Entry{
        .name = "beta", .source = "https://example.test/beta.lua",
        .addedAt = "2026-09-12T01:00:00Z", .sha256 = "",
        .version = "",
    };
    overlay::save(root, entries);

    auto loaded = overlay::load(root);
    ASSERT_EQ(loaded.size(), 2u);
    ASSERT_TRUE(loaded.contains("alpha"));
    EXPECT_EQ(loaded["alpha"].source, "/some/path/alpha.lua");
    EXPECT_EQ(loaded["alpha"].addedAt, "2026-09-12T00:00:00Z");
    EXPECT_EQ(loaded["alpha"].sha256, "deadbeef");
    EXPECT_EQ(loaded["alpha"].version, "1.0.0");
    ASSERT_TRUE(loaded.contains("beta"));
    EXPECT_EQ(loaded["beta"].version, "");
    fs::remove_all(root);
}

// ── declared_latest ───────────────────────────────────────────────────

TEST(OverlayDeclaredLatest, ReadsTheRef) {
    auto root = make_temp_dir("declared-latest");
    write_recipe(root, "alpha", "3.2.1");
    auto v = overlay::declared_latest(overlay::recipe_path(root, "alpha"));
    ASSERT_TRUE(v.has_value());
    EXPECT_EQ(*v, "3.2.1");
    fs::remove_all(root);
}

TEST(OverlayDeclaredLatest, UnparseableFileIsNullopt) {
    auto root = make_temp_dir("declared-latest-bad");
    auto file = root / "junk.lua";
    xlings::platform::write_string_to_file(file.string(), "not lua {{{");
    EXPECT_FALSE(overlay::declared_latest(file).has_value());
    fs::remove_all(root);
}

// ── upstream_candidates (injected repo list) ─────────────────────────

TEST(OverlayUpstreamCandidates, FindsSameNameAcrossInjectedRepos) {
    auto root = make_temp_dir("candidates");
    auto upstreamDir = root / "xim";
    auto subDir = root / "sub";
    write_recipe(upstreamDir, "alpha", "1.0.0");
    write_recipe(subDir, "gamma", "1.0.0");
    fs::create_directories(root / "overlay");

    std::vector<overlay::RepoDir> repos = {
        {"xim", upstreamDir}, {"awesome-sub", subDir},
        {"local", root / "overlay"},  // must be excluded
    };

    auto alpha = overlay::upstream_candidates("alpha", repos);
    ASSERT_EQ(alpha.size(), 1u);
    EXPECT_EQ(alpha[0].first, "xim");
    EXPECT_EQ(alpha[0].second, overlay::recipe_path(upstreamDir, "alpha"));

    auto gamma = overlay::upstream_candidates("gamma", repos);
    ASSERT_EQ(gamma.size(), 1u);
    EXPECT_EQ(gamma[0].first, "awesome-sub");

    EXPECT_TRUE(overlay::upstream_candidates("nope", repos).empty());
    fs::remove_all(root);
}

// ── status_of ─────────────────────────────────────────────────────────

class OverlayStatusTest : public ::testing::Test {
protected:
    fs::path root_, upstreamDir_, overlayDir_;

    void SetUp() override {
        root_ = make_temp_dir("status");
        upstreamDir_ = root_ / "xim";
        overlayDir_ = root_ / "overlay";
        fs::create_directories(upstreamDir_);
        fs::create_directories(overlayDir_);
    }
    void TearDown() override { fs::remove_all(root_); }

    std::vector<std::pair<std::string, fs::path>> candidates(
        std::string_view name) {
        return {{"xim", overlay::recipe_path(upstreamDir_, name)}};
    }
};

TEST_F(OverlayStatusTest, UniqueWhenNoUpstreamRecipe) {
    write_recipe(overlayDir_, "solo", "1.0.0");
    overlay::Entry entry{.name = "solo", .version = "1.0.0"};
    auto status = overlay::status_of(
        entry, overlay::recipe_path(overlayDir_, "solo"), {});
    EXPECT_EQ(status.kind, overlay::Status::Unique);
}

TEST_F(OverlayStatusTest, IdenticalBySha) {
    write_recipe(upstreamDir_, "alpha", "1.0.0");
    fs::create_directories(overlayDir_ / "pkgs" / "a");
    fs::copy_file(overlay::recipe_path(upstreamDir_, "alpha"),
                 overlay::recipe_path(overlayDir_, "alpha"));

    overlay::Entry entry{.name = "alpha", .version = "1.0.0"};
    auto status = overlay::status_of(
        entry, overlay::recipe_path(overlayDir_, "alpha"), candidates("alpha"));
    EXPECT_EQ(status.kind, overlay::Status::Identical);
    EXPECT_EQ(status.upstreamRepo, "xim");
    EXPECT_EQ(status.upstreamVersion, "1.0.0");
}

TEST_F(OverlayStatusTest, ModifiedWhenBytesDiffer) {
    write_recipe(upstreamDir_, "alpha", "1.0.0");
    // Same declared version, different bytes (a comment the user added).
    write_recipe(overlayDir_, "alpha", "1.0.0", " (edited by hand)");

    overlay::Entry entry{.name = "alpha", .version = "1.0.0"};
    auto status = overlay::status_of(
        entry, overlay::recipe_path(overlayDir_, "alpha"), candidates("alpha"));
    EXPECT_EQ(status.kind, overlay::Status::Modified);
    EXPECT_EQ(status.upstreamRepo, "xim");
}

TEST_F(OverlayStatusTest, BehindWhenUpstreamNewer) {
    // Upstream has moved on to 2.0.0; the overlay's recorded version is
    // still 1.0.0, and its bytes necessarily differ from upstream's now.
    write_recipe(upstreamDir_, "alpha", "2.0.0");
    write_recipe(overlayDir_, "alpha", "1.0.0");

    overlay::Entry entry{.name = "alpha", .version = "1.0.0"};
    auto status = overlay::status_of(
        entry, overlay::recipe_path(overlayDir_, "alpha"), candidates("alpha"));
    EXPECT_EQ(status.kind, overlay::Status::Behind);
    EXPECT_EQ(status.upstreamRepo, "xim");
    EXPECT_EQ(status.upstreamVersion, "2.0.0");
}

TEST_F(OverlayStatusTest, NoRecordedVersionNeverReportsBehind) {
    // Brief: "declared latest ... 没有则空 (Status 退化为
    // Unique/Identical/Modified)" — an entry with no recorded version can
    // never be classified Behind, only Modified (or Identical/Unique).
    write_recipe(upstreamDir_, "alpha", "9.9.9");
    write_recipe(overlayDir_, "alpha", "1.0.0");

    overlay::Entry entry{.name = "alpha", .version = ""};
    auto status = overlay::status_of(
        entry, overlay::recipe_path(overlayDir_, "alpha"), candidates("alpha"));
    EXPECT_EQ(status.kind, overlay::Status::Modified);
}

TEST_F(OverlayStatusTest, MissingWhenFileIsGone) {
    // A TRACKED entry (`.overlay.json` has a record) whose file was deleted
    // out from under it -- `load_with_files` still yields a `DiscoveredEntry`
    // for this (path is `recipe_path(dir, name)` unconditionally), so
    // without a dedicated Kind this degraded to Unique off an empty sha.
    overlay::Entry entry{.name = "ghost", .version = "1.0.0"};
    auto status = overlay::status_of(
        entry, overlay::recipe_path(overlayDir_, "ghost"), candidates("ghost"));
    EXPECT_EQ(status.kind, overlay::Status::Missing);
}

TEST_F(OverlayStatusTest, MissingOutranksUpstreamComparisons) {
    // Even when an upstream candidate exists and declares a newer version
    // (what would otherwise classify as Behind), a gone local file must
    // still report Missing -- there is nothing on disk to compare.
    write_recipe(upstreamDir_, "ghost", "2.0.0");
    overlay::Entry entry{.name = "ghost", .version = "1.0.0"};
    auto status = overlay::status_of(
        entry, overlay::recipe_path(overlayDir_, "ghost"), candidates("ghost"));
    EXPECT_EQ(status.kind, overlay::Status::Missing);
}

// ── find_entry ────────────────────────────────────────────────────────

TEST(OverlayFindEntry, FindsATrackedEntryByName) {
    auto root = make_temp_dir("find-tracked");
    write_recipe(root, "alpha", "1.0.0");
    std::map<std::string, overlay::Entry> entries;
    entries["alpha"] = {.name = "alpha", .version = "1.0.0"};
    overlay::save(root, entries);

    auto discovered = overlay::load_with_files(root);
    auto found = overlay::find_entry(discovered, "alpha");
    ASSERT_TRUE(found.has_value());
    EXPECT_TRUE(found->tracked);
    EXPECT_EQ(found->entry.name, "alpha");
    fs::remove_all(root);
}

TEST(OverlayFindEntry, FindsAnUntrackedEntryByName) {
    // The exact case `--remove-xpkg` on an untracked overlay recipe needs:
    // no `.overlay.json` record at all, only a file on disk.
    auto root = make_temp_dir("find-untracked");
    write_recipe(root, "beta", "1.0.0");

    auto discovered = overlay::load_with_files(root);
    auto found = overlay::find_entry(discovered, "beta");
    ASSERT_TRUE(found.has_value());
    EXPECT_FALSE(found->tracked);
    EXPECT_EQ(found->entry.name, "beta");
    fs::remove_all(root);
}

TEST(OverlayFindEntry, NulloptWhenNameIsNotThere) {
    auto root = make_temp_dir("find-missing");
    write_recipe(root, "gamma", "1.0.0");

    auto discovered = overlay::load_with_files(root);
    EXPECT_FALSE(overlay::find_entry(discovered, "no-such-name").has_value());
    fs::remove_all(root);
}

// ── gc_identical ──────────────────────────────────────────────────────

TEST(OverlayGc, RemovesOnlyIdentical) {
    auto root = make_temp_dir("gc");
    auto upstreamDir = root / "xim";
    auto overlayDir = root / "overlay";

    // alpha: byte-identical to upstream -> should be GC'd.
    write_recipe(upstreamDir, "alpha", "1.0.0");
    fs::create_directories(overlayDir / "pkgs" / "a");
    fs::copy_file(overlay::recipe_path(upstreamDir, "alpha"),
                 overlay::recipe_path(overlayDir, "alpha"));

    // beta: differs from upstream (still Modified) -> must survive.
    write_recipe(upstreamDir, "beta", "1.0.0");
    write_recipe(overlayDir, "beta", "1.0.0", " (kept on purpose)");

    // gamma: no upstream recipe at all (Unique) -> must survive.
    write_recipe(overlayDir, "gamma", "1.0.0");

    std::map<std::string, overlay::Entry> entries;
    entries["alpha"] = {.name = "alpha", .version = "1.0.0"};
    entries["beta"]  = {.name = "beta",  .version = "1.0.0"};
    entries["gamma"] = {.name = "gamma", .version = "1.0.0"};
    overlay::save(overlayDir, entries);

    std::vector<overlay::RepoDir> repos = {{"xim", upstreamDir}};
    auto removed = overlay::gc_identical(overlayDir, repos);

    ASSERT_EQ(removed.size(), 1u);
    EXPECT_EQ(removed[0], "alpha");

    EXPECT_FALSE(fs::exists(overlay::recipe_path(overlayDir, "alpha")));
    EXPECT_TRUE(fs::exists(overlay::recipe_path(overlayDir, "beta")));
    EXPECT_TRUE(fs::exists(overlay::recipe_path(overlayDir, "gamma")));

    auto remaining = overlay::load(overlayDir);
    EXPECT_EQ(remaining.size(), 2u);
    EXPECT_FALSE(remaining.contains("alpha"));
    EXPECT_TRUE(remaining.contains("beta"));
    EXPECT_TRUE(remaining.contains("gamma"));

    fs::remove_all(root);
}

TEST(OverlayGc, NoOpWhenNothingIdentical) {
    auto root = make_temp_dir("gc-noop");
    auto overlayDir = root / "overlay";
    write_recipe(overlayDir, "solo", "1.0.0");
    std::map<std::string, overlay::Entry> entries;
    entries["solo"] = {.name = "solo", .version = "1.0.0"};
    overlay::save(overlayDir, entries);

    std::vector<overlay::RepoDir> repos;  // no upstream repos at all
    auto removed = overlay::gc_identical(overlayDir, repos);
    EXPECT_TRUE(removed.empty());
    EXPECT_TRUE(fs::exists(overlay::recipe_path(overlayDir, "solo")));
    fs::remove_all(root);
}

TEST(OverlayGc, RemovesAMissingTrackedEntry) {
    // A tracked entry whose file was deleted out from under the overlay's
    // own bookkeeping: no bytes to compare (so it can never be Identical),
    // but it is still provenance garbage -- `gc_identical` must drop the
    // `.overlay.json` record even though there is no file left to delete.
    auto root = make_temp_dir("gc-missing");
    auto overlayDir = root / "overlay";
    // A healthy sibling, to prove the blast radius is just the one entry.
    write_recipe(overlayDir, "healthy", "1.0.0");

    std::map<std::string, overlay::Entry> entries;
    entries["ghost"]   = {.name = "ghost", .version = "1.0.0"};  // no file
    entries["healthy"] = {.name = "healthy", .version = "1.0.0"};
    overlay::save(overlayDir, entries);

    ASSERT_FALSE(fs::exists(overlay::recipe_path(overlayDir, "ghost")));

    std::vector<overlay::RepoDir> repos;  // no upstream repos needed
    auto removed = overlay::gc_identical(overlayDir, repos);

    ASSERT_EQ(removed.size(), 1u);
    EXPECT_EQ(removed[0], "ghost");

    auto remaining = overlay::load(overlayDir);
    EXPECT_FALSE(remaining.contains("ghost"));
    EXPECT_TRUE(remaining.contains("healthy"));
    EXPECT_TRUE(fs::exists(overlay::recipe_path(overlayDir, "healthy")));
    fs::remove_all(root);
}

// ── load_with_files: the untracked case (fix round 1, Finding 1) ────────
//
// A pre-2026.9.12 `--add-xpkg` never wrote a `.overlay.json` entry. On a
// real machine that is 159 of 159 recipes. `load_with_files` is what makes
// `--list-xpkg`, `--clear-xpkg`, and `gc_identical` see those too.

TEST(OverlayLoadWithFiles, EmptyOverlayIsEmpty) {
    auto root = make_temp_dir("lwf-empty");
    EXPECT_TRUE(overlay::load_with_files(root).empty());
    fs::remove_all(root);
}

TEST(OverlayLoadWithFiles, SynthesizesAnEntryForAnUntrackedFile) {
    auto root = make_temp_dir("lwf-untracked");
    write_recipe(root, "orphan", "2.5.0");
    // Deliberately no .overlay.json at all -- the 157-of-159 shape.

    auto discovered = overlay::load_with_files(root);
    ASSERT_EQ(discovered.size(), 1u);
    auto& item = discovered.front();
    EXPECT_EQ(item.entry.name, "orphan");
    EXPECT_EQ(item.entry.source, "");
    EXPECT_FALSE(item.entry.addedAt.empty());   // synthesized from mtime
    EXPECT_FALSE(item.entry.sha256.empty());
    EXPECT_EQ(item.entry.version, "2.5.0");     // read fresh from the file
    EXPECT_EQ(item.path, overlay::recipe_path(root, "orphan"));
    EXPECT_FALSE(item.tracked);
    fs::remove_all(root);
}

TEST(OverlayLoadWithFiles, DoesNotDuplicateATrackedFile) {
    auto root = make_temp_dir("lwf-tracked");
    write_recipe(root, "alpha", "1.0.0");
    std::map<std::string, overlay::Entry> entries;
    entries["alpha"] = {.name = "alpha", .source = "user gave this",
                        .version = "1.0.0"};
    overlay::save(root, entries);

    auto discovered = overlay::load_with_files(root);
    ASSERT_EQ(discovered.size(), 1u);
    EXPECT_EQ(discovered.front().entry.name, "alpha");
    EXPECT_EQ(discovered.front().entry.source, "user gave this");
    EXPECT_TRUE(discovered.front().tracked);
    fs::remove_all(root);
}

TEST(OverlayLoadWithFiles, MixesTrackedAndUntracked) {
    auto root = make_temp_dir("lwf-mixed");
    write_recipe(root, "tracked_one", "1.0.0");
    write_recipe(root, "untracked_one", "1.0.0");
    std::map<std::string, overlay::Entry> entries;
    entries["tracked_one"] = {.name = "tracked_one", .version = "1.0.0"};
    overlay::save(root, entries);

    auto discovered = overlay::load_with_files(root);
    ASSERT_EQ(discovered.size(), 2u);
    bool sawTracked = false, sawUntracked = false;
    for (auto& item : discovered) {
        if (item.entry.name == "tracked_one") sawTracked = item.tracked;
        if (item.entry.name == "untracked_one") sawUntracked = !item.tracked;
    }
    EXPECT_TRUE(sawTracked);
    EXPECT_TRUE(sawUntracked);
    fs::remove_all(root);
}

// ── the two scenarios the review named explicitly ────────────────────

TEST(OverlayGc, RemovesAnUntrackedIdenticalFile) {
    auto root = make_temp_dir("gc-untracked-identical");
    auto upstreamDir = root / "xim";
    auto overlayDir = root / "overlay";

    write_recipe(upstreamDir, "orphan", "1.0.0");
    fs::create_directories(overlayDir / "pkgs" / "o");
    fs::copy_file(overlay::recipe_path(upstreamDir, "orphan"),
                 overlay::recipe_path(overlayDir, "orphan"));
    // No .overlay.json at all -- this recipe was never added through
    // this feature's `--add-xpkg`.
    ASSERT_FALSE(fs::exists(overlayDir / ".overlay.json"));

    std::vector<overlay::RepoDir> repos = {{"xim", upstreamDir}};
    auto removed = overlay::gc_identical(overlayDir, repos);

    ASSERT_EQ(removed.size(), 1u);
    EXPECT_EQ(removed[0], "orphan");
    EXPECT_FALSE(fs::exists(overlay::recipe_path(overlayDir, "orphan")));
    // GC must not have adopted it into provenance on the way out.
    EXPECT_TRUE(overlay::load(overlayDir).empty());

    fs::remove_all(root);
}

TEST(OverlayLoadWithFiles, AnUntrackedModifiedFileReportsModified) {
    auto root = make_temp_dir("lwf-untracked-modified");
    auto upstreamDir = root / "xim";
    auto overlayDir = root / "overlay";

    write_recipe(upstreamDir, "orphan", "1.0.0");
    // Same declared version, different bytes -- an untracked recipe someone
    // hand-edited, not simply behind.
    write_recipe(overlayDir, "orphan", "1.0.0", " (hand-edited, untracked)");

    std::vector<overlay::RepoDir> repos = {{"xim", upstreamDir}};
    auto discovered = overlay::load_with_files(overlayDir);
    ASSERT_EQ(discovered.size(), 1u);
    auto& item = discovered.front();
    EXPECT_FALSE(item.tracked);

    auto candidates = overlay::upstream_candidates("orphan", repos);
    auto status = overlay::status_of(item.entry, item.path, candidates);
    EXPECT_EQ(status.kind, overlay::Status::Modified);

    // `gc_identical` must leave it alone -- Modified, not Identical.
    auto removed = overlay::gc_identical(overlayDir, repos);
    EXPECT_TRUE(removed.empty());
    EXPECT_TRUE(fs::exists(overlay::recipe_path(overlayDir, "orphan")));

    fs::remove_all(root);
}

// ── remove_recipe_file (fix round 1, Finding 2: one shared implementation) ──

TEST(OverlayRemoveRecipeFile, RemovesFileAndEmptyLetterDir) {
    auto root = make_temp_dir("remove-file");
    write_recipe(root, "solo", "1.0.0");
    auto file = overlay::recipe_path(root, "solo");
    ASSERT_TRUE(fs::exists(file));

    EXPECT_TRUE(overlay::remove_recipe_file(file));
    EXPECT_FALSE(fs::exists(file));
    EXPECT_FALSE(fs::exists(file.parent_path()));  // the now-empty letter dir
    fs::remove_all(root);
}

TEST(OverlayRemoveRecipeFile, LeavesTheLetterDirIfNotEmpty) {
    auto root = make_temp_dir("remove-file-shared-dir");
    write_recipe(root, "alpha", "1.0.0");
    write_recipe(root, "another", "1.0.0");  // shares the "a" letter dir
    auto file = overlay::recipe_path(root, "alpha");

    EXPECT_TRUE(overlay::remove_recipe_file(file));
    EXPECT_FALSE(fs::exists(file));
    EXPECT_TRUE(fs::exists(file.parent_path()));  // "another" is still there
    EXPECT_TRUE(fs::exists(overlay::recipe_path(root, "another")));
    fs::remove_all(root);
}

TEST(OverlayRemoveRecipeFile, MissingFileIsNotAnError) {
    auto root = make_temp_dir("remove-file-missing");
    EXPECT_FALSE(overlay::remove_recipe_file(root / "pkgs" / "n" / "nope.lua"));
    fs::remove_all(root);
}
