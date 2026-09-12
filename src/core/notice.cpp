module xlings.core.notice;

import std;
import xlings.core.diag;
import xlings.core.config;

namespace xlings::notice {

namespace {

std::string key_(std::string_view id, std::string_view fingerprint) {
    std::string k(id);
    k += '\x1f';
    k += fingerprint;
    return k;
}

}  // namespace

bool notice_once(const Memo& memo, std::string_view id,
                  std::string_view fingerprint, const diag::Diagnostic& d) {
    const auto key = key_(id, fingerprint);
    if (memo.seen && memo.seen(key)) return false;

    diag::Diagnostic note = d;
    note.level = diag::Level::Note;
    diag::emit(note);

    // A read-only home must not turn a note into a crash: the note was
    // already shown, so failing to remember it means showing it again next
    // time, not failing this command.
    try {
        if (memo.mark) memo.mark(key);
    } catch (...) {}

    return true;
}

bool notice_once(std::string_view id, std::string_view fingerprint,
                  const diag::Diagnostic& d) {
    return notice_once(config_memo(), id, fingerprint, d);
}

Memo config_memo() {
    return Memo{
        .seen = [](std::string_view id) { return Config::hint_seen(id); },
        .mark = [](std::string_view id) { Config::mark_hint_seen(id); },
    };
}

}  // namespace xlings::notice
