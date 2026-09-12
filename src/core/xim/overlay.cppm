module;
#include <ctime>

export module xlings.core.xim.overlay;

import std;
import mcpplibs.xpkg;
import xlings.core.config;
import xlings.core.version_order;

// The local index used to be a write-only drawer: `config --add-xpkg` copied
// a recipe in, and nothing after that could say what was in there, where it
// came from, or whether the synced index had already caught up with it. On
// the maintainer's own machine 159 recipes had accumulated this way, 157 of
// them byte-identical to what `xim` now ships — every one of them a bare
// name that resolves ambiguously and prints a namespace-priority warning,
// with no command to find out why or clean it up.
//
// This module gives the overlay a provenance record (`.overlay.json`, one
// entry per recipe: where it came from, when, and what it looked like at
// add time) and a status question that can be asked of any entry against
// the synced index it shadows:
//
//   Unique      no same-named recipe in any non-local repo
//   Identical   byte-identical to a same-named upstream recipe — the index
//               has caught up; safe to garbage-collect
//   Modified    an upstream recipe with the same name exists, differs in
//               bytes, and isn't simply a newer upstream release
//   Behind      upstream declares a newer version than this entry recorded
//
// `upstream_candidates` and `gc_identical` each come in two shapes: the
// plain one answers from the real index_repos this process has loaded
// (`Config::global_index_repos()` + discovered sub-repos), and the
// `std::span<const RepoDir>` overload takes an injected list instead — so a
// unit test can build a fake "upstream" directory without a real home.
export namespace xlings::xim::overlay {

struct Entry {
    std::string name;
    std::string source;    // the path or URL the user gave `--add-xpkg`
    std::string addedAt;   // ISO-8601 UTC, e.g. "2026-09-12T00:00:00Z"
    std::string sha256;    // of the recipe file, at add time
    std::string version;   // declared latest at add time, "" if none
};

// One non-local repo this process knows a directory for, by name — the
// shape `upstream_candidates`/`gc_identical` need to search for a same-named
// recipe. Built from real config for normal use; a test builds its own.
struct RepoDir {
    std::string repo;
    std::filesystem::path dir;
};

struct Status {
    enum Kind { Unique, Identical, Modified, Behind } kind = Unique;
    std::string upstreamRepo;
    std::string upstreamVersion;
};

// Where the overlay lives: Config::global_data_dir()/"xim-pkgindex-local".
std::filesystem::path dir();

// pkgs/<lowercase first letter>/<name>.lua under `dir` — the same layout
// `cmd_add_xpkg` already writes and `PackageCatalog` already reads.
std::filesystem::path recipe_path(const std::filesystem::path& dir,
                                  std::string_view name);

// Read `.overlay.json` under `dir`. A missing or unreadable file reads as
// no entries, never as an error — provenance is a record of what
// `--add-xpkg` did, not a gate on whether the recipe works.
std::map<std::string, Entry> load(const std::filesystem::path& dir);

void save(const std::filesystem::path& dir,
         const std::map<std::string, Entry>& entries);

// Lowercase hex sha256 of a file's bytes; "" if it can't be read.
std::string file_sha256(const std::filesystem::path& path);

// UTC "YYYY-MM-DDTHH:MM:SSZ", for provenance's `addedAt`.
std::string now_utc_iso();

// The version a recipe file declares as "latest"
// (xpm.entries[*]["latest"].ref), preferring the current platform; empty if
// the recipe (or an unparseable file) declares none. Shared by `--add-xpkg`
// (to record `Entry::version`) and `status_of` (to detect "Behind").
std::optional<std::string> declared_latest(const std::filesystem::path& recipeFile);

// Every non-local global repo (plus discovered sub-repos) that ships a
// same-named recipe, real-config-backed.
std::vector<std::pair<std::string, std::filesystem::path>>
upstream_candidates(std::string_view name);

// Same question, against an injected repo list — the seam a unit test uses.
std::vector<std::pair<std::string, std::filesystem::path>>
upstream_candidates(std::string_view name, std::span<const RepoDir> repos);

// Compares `localFile`'s current bytes and declared latest version against
// every upstream candidate for `entry.name` (real-config-backed).
Status status_of(const Entry& entry, const std::filesystem::path& localFile);

// Same question, against an already-computed candidate list — what
// `gc_identical`'s injectable overload, and unit tests, use.
Status status_of(const Entry& entry, const std::filesystem::path& localFile,
                 std::span<const std::pair<std::string, std::filesystem::path>> candidates);

// Removes every overlay entry (file + provenance record) whose status is
// Identical, real-config-backed. Returns the names removed.
std::vector<std::string> gc_identical(const std::filesystem::path& dir);

// Same operation, against an injected repo list.
std::vector<std::string> gc_identical(const std::filesystem::path& dir,
                                      std::span<const RepoDir> repos);

} // namespace xlings::xim::overlay
