// `notice_once` is the primitive behind "say it once per home": four sites
// printed "run xlings self doctor --fix" on every command and a
// namespace-priority warning printed on every command, because neither had
// cross-process memory. These tests exercise the decision table against a
// fake Memo, without touching a real home.
#include <gtest/gtest.h>

import std;
import xlings.core.diag;
import xlings.core.notice;

using xlings::diag::Action;
using xlings::diag::Diagnostic;
using xlings::diag::Level;
using xlings::notice::Memo;
using xlings::notice::notice_once;

namespace {

// A fake home: a set of seen keys plus a mark count, so a test can assert
// "emitted once" without capturing a log stream.
struct FakeHome {
    std::set<std::string, std::less<>> seenKeys;
    int markCalls = 0;
    bool markThrows = false;

    Memo memo() {
        return Memo{
            .seen = [this](std::string_view id) { return seenKeys.contains(id); },
            .mark = [this](std::string_view id) {
                ++markCalls;
                if (markThrows) throw std::runtime_error("read-only home");
                seenKeys.emplace(id);
            },
        };
    }
};

Diagnostic sample_() {
    return Diagnostic{
        .level   = Level::Warn,  // deliberately not Note: notice_once must force it
        .code    = "test.notice",
        .summary = "this is a test notice",
        .actions = { Action{ "do something", "xlings do-something" } },
    };
}

}  // namespace

TEST(Notice, PrintsOnceThenRemembers) {
    FakeHome home;
    auto memo = home.memo();

    EXPECT_TRUE(notice_once(memo, "test.id", "fp1", sample_()));
    EXPECT_EQ(home.markCalls, 1);

    EXPECT_FALSE(notice_once(memo, "test.id", "fp1", sample_()));
    // No second mark: the second call short-circuits on `seen` before
    // reaching emit/mark at all.
    EXPECT_EQ(home.markCalls, 1);
}

TEST(Notice, DifferentFingerprintPrintsAgain) {
    FakeHome home;
    auto memo = home.memo();

    EXPECT_TRUE(notice_once(memo, "test.id", "fp1", sample_()));
    // A different fingerprint is a different fact to report -- an upgrade to
    // a newer version, or a namespace conflict with a different loser -- so
    // it must print again even though the id repeats.
    EXPECT_TRUE(notice_once(memo, "test.id", "fp2", sample_()));
    EXPECT_EQ(home.markCalls, 2);
}

TEST(Notice, MarkThrowingDoesNotPropagate) {
    FakeHome home;
    home.markThrows = true;
    auto memo = home.memo();

    // A read-only home must not turn a note into a crash: the emit already
    // happened, so notice_once still reports "printed" (true) even though
    // remembering it failed.
    EXPECT_TRUE(notice_once(memo, "test.id", "fp1", sample_()));
    EXPECT_EQ(home.markCalls, 1);
}
