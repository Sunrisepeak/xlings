module;
#include <ctime>

module xlings.core.xim.overlay;

import std;
import mcpplibs.xpkg;
import mcpplibs.xpkg.loader;
import xlings.core.config;
import xlings.core.version_order;
import xlings.core.xim.repo;
import xlings.libs.sha256;
import xlings.libs.json;
import xlings.platform;
import xlings.platform.target;

namespace xpkg = mcpplibs::xpkg;

namespace xlings::xim::overlay {

namespace fs = std::filesystem;

namespace detail_ {

// Every non-local repo directory this process has loaded, real-config-
// backed. Mirrors `PackageCatalog::repo_specs_()`'s global+sub-repo walk,
// minus project scope (the overlay is a global concept) and minus the
// "local" entry itself (this module IS the local entry).
std::vector<RepoDir> real_repo_dirs_() {
    std::vector<RepoDir> out;
    for (auto& repo : Config::global_index_repos()) {
        if (repo.name == "local") continue;
        out.push_back({repo.name, Config::repo_dir_for(repo, false)});
    }
    for (auto& repo : discovered_global_sub_repos()) {
        if (repo.name == "local") continue;
        out.push_back({repo.name, sub_repo_dir_for(repo, false)});
    }
    return out;
}

} // namespace detail_

std::string now_utc_iso() {
    auto now   = std::chrono::system_clock::now();
    auto nowTT = std::chrono::system_clock::to_time_t(now);
    char buf[32];
    std::strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%SZ", std::gmtime(&nowTT));
    return buf;
}

std::optional<std::string> declared_latest(const fs::path& recipeFile) {
    auto loaded = xpkg::load_package(recipeFile);
    if (!loaded) return std::nullopt;
    auto& pkg = *loaded;
    // Prefers the current platform (what THIS host would install) but falls
    // back to any platform that declares one, since a recipe's `latest` ref
    // is normally the same version string across platforms.
    auto fromPlatform = [&](const std::string& plat) -> std::optional<std::string> {
        auto platformIt = pkg.xpm.entries.find(plat);
        if (platformIt == pkg.xpm.entries.end()) return std::nullopt;
        auto latestIt = platformIt->second.find("latest");
        if (latestIt == platformIt->second.end() || latestIt->second.ref.empty())
            return std::nullopt;
        return latestIt->second.ref;
    };
    if (auto v = fromPlatform(std::string(platform::build_os()))) return v;
    for (auto& [plat, versions] : pkg.xpm.entries) {
        auto latestIt = versions.find("latest");
        if (latestIt != versions.end() && !latestIt->second.ref.empty())
            return latestIt->second.ref;
    }
    return std::nullopt;
}

fs::path dir() {
    return Config::global_data_dir() / "xim-pkgindex-local";
}

fs::path recipe_path(const fs::path& dir, std::string_view name) {
    std::string letter = name.empty()
        ? std::string("_")
        : std::string(1, static_cast<char>(
              std::tolower(static_cast<unsigned char>(name.front()))));
    return dir / "pkgs" / letter / (std::string(name) + ".lua");
}

std::map<std::string, Entry> load(const fs::path& dir) {
    std::map<std::string, Entry> entries;
    auto file = dir / ".overlay.json";
    std::error_code ec;
    if (!fs::is_regular_file(file, ec)) return entries;
    try {
        auto content = platform::read_file_to_string(file.string());
        auto json = nlohmann::json::parse(content, nullptr, false);
        if (json.is_discarded() || !json.is_object()) return entries;
        for (auto it = json.begin(); it != json.end(); ++it) {
            if (!it.value().is_object()) continue;
            Entry e;
            e.name    = it.key();
            e.source  = it.value().value("source", "");
            e.addedAt = it.value().value("addedAt", "");
            e.sha256  = it.value().value("sha256", "");
            e.version = it.value().value("version", "");
            entries.emplace(it.key(), std::move(e));
        }
    } catch (...) {
        return {};
    }
    return entries;
}

void save(const fs::path& dir, const std::map<std::string, Entry>& entries) {
    nlohmann::json json = nlohmann::json::object();
    for (auto& [name, e] : entries) {
        json[name] = {
            {"source",  e.source},
            {"addedAt", e.addedAt},
            {"sha256",  e.sha256},
            {"version", e.version},
        };
    }
    std::error_code ec;
    fs::create_directories(dir, ec);
    platform::write_string_to_file((dir / ".overlay.json").string(), json.dump(2));
}

std::string file_sha256(const fs::path& path) {
    return sha256::hex_file(path).value_or("");
}

std::vector<std::pair<std::string, fs::path>>
upstream_candidates(std::string_view name, std::span<const RepoDir> repos) {
    std::vector<std::pair<std::string, fs::path>> found;
    for (auto& r : repos) {
        if (r.repo == "local") continue;
        auto candidate = recipe_path(r.dir, name);
        std::error_code ec;
        if (fs::is_regular_file(candidate, ec)) found.emplace_back(r.repo, candidate);
    }
    return found;
}

std::vector<std::pair<std::string, fs::path>>
upstream_candidates(std::string_view name) {
    return upstream_candidates(name, detail_::real_repo_dirs_());
}

Status status_of(const Entry& entry, const fs::path& localFile,
                 std::span<const std::pair<std::string, fs::path>> candidates) {
    Status status;
    auto localSha = file_sha256(localFile);

    // 1. Byte-identical to any candidate wins outright — the recipe is
    //    fully caught up, whatever its recorded version says.
    for (auto& [repo, path] : candidates) {
        if (!localSha.empty() && file_sha256(path) == localSha) {
            status.kind = Status::Identical;
            status.upstreamRepo = repo;
            status.upstreamVersion = declared_latest(path).value_or("");
            return status;
        }
    }

    // 2. Not identical, but upstream declares a strictly newer version than
    //    this entry recorded at add time — "Behind" outranks "Modified"
    //    because that IS the interesting fact (the divergence is just age).
    if (!entry.version.empty()) {
        for (auto& [repo, path] : candidates) {
            auto upstreamLatest = declared_latest(path);
            if (!upstreamLatest) continue;
            if (version_order::compare(*upstreamLatest, entry.version)
                    == std::strong_ordering::greater) {
                status.kind = Status::Behind;
                status.upstreamRepo = repo;
                status.upstreamVersion = *upstreamLatest;
                return status;
            }
        }
    }

    // 3. A same-named upstream recipe exists, differs in bytes, and isn't
    //    simply newer — the user's own edit.
    if (!candidates.empty()) {
        status.kind = Status::Modified;
        status.upstreamRepo = candidates.front().first;
        status.upstreamVersion = declared_latest(candidates.front().second)
                                     .value_or("");
        return status;
    }

    status.kind = Status::Unique;
    return status;
}

Status status_of(const Entry& entry, const fs::path& localFile) {
    return status_of(entry, localFile, upstream_candidates(entry.name));
}

std::vector<std::string> gc_identical(const fs::path& dir, std::span<const RepoDir> repos) {
    auto entries = load(dir);
    std::vector<std::string> removed;
    for (auto it = entries.begin(); it != entries.end(); ) {
        auto localFile = recipe_path(dir, it->first);
        std::error_code ec;
        if (!fs::is_regular_file(localFile, ec)) { ++it; continue; }
        auto candidates = upstream_candidates(it->first, repos);
        auto status = status_of(it->second, localFile, candidates);
        if (status.kind == Status::Identical) {
            fs::remove(localFile, ec);
            auto letterDir = localFile.parent_path();
            if (fs::is_directory(letterDir, ec) && fs::is_empty(letterDir, ec))
                fs::remove(letterDir, ec);
            removed.push_back(it->first);
            it = entries.erase(it);
        } else {
            ++it;
        }
    }
    if (!removed.empty()) save(dir, entries);
    return removed;
}

std::vector<std::string> gc_identical(const fs::path& dir) {
    return gc_identical(dir, detail_::real_repo_dirs_());
}

} // namespace xlings::xim::overlay
