export module xlings.core.notice;

import std;
import xlings.core.diag;
import xlings.core.config;

// Four call sites print "run xlings self doctor --fix" on every command, and
// a namespace-priority warning prints on every command too, because neither
// has cross-process memory: the process that decided to warn exits, and the
// next process re-derives the same warning from the same on-disk state with
// no memory that it already told the user.
//
// `Config::hint_seen` / `Config::mark_hint_seen` already persist a set of
// opaque ids under `.xlings.json["hintsSeen"]` -- that is the primitive. What
// was missing is the DECISION: given an id and a fingerprint of what
// triggered it, say it once per (id, fingerprint) pair, not once per id
// forever -- an upgrade to a NEWER version should announce again, and a
// namespace conflict with a DIFFERENT loser should announce again, but the
// same conflict on the next command must not.
//
// The memo is injected rather than reaching for `Config` directly so the
// decision table (seen -> false, unseen -> emit + mark) is testable without a
// real home -- see test_notice.cpp. Production call sites use the bound
// overload / `config_memo()`.
export namespace xlings::notice {

struct Memo {
    std::function<bool(std::string_view id)> seen;
    std::function<void(std::string_view id)> mark;   // may throw; swallowed
};

// Returns true when it printed. Key = id + "\x1f" + fingerprint: the ASCII
// unit separator can't appear in either half by construction (both are
// caller-controlled identifiers, never free text), so there is no collision
// between e.g. id="a\x1fb" fingerprint="c" and id="a" fingerprint="b\x1fc".
[[nodiscard]] bool notice_once(const Memo& memo, std::string_view id,
                               std::string_view fingerprint,
                               const diag::Diagnostic& d);

// Bound to Config::hint_seen / Config::mark_hint_seen.
[[nodiscard]] bool notice_once(std::string_view id, std::string_view fingerprint,
                               const diag::Diagnostic& d);

[[nodiscard]] Memo config_memo();

}  // namespace xlings::notice
