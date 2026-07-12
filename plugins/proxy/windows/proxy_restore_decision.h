#ifndef FLUTTER_PLUGIN_PROXY_RESTORE_DECISION_H_
#define FLUTTER_PLUGIN_PROXY_RESTORE_DECISION_H_

namespace proxy::internal {

inline bool ShouldRestoreOwnedState(
    bool current_exists,
    bool matches_before,
    bool matches_applied,
    bool matches_pending) {
  return current_exists && !matches_before &&
      (matches_applied || matches_pending);
}

inline bool ShouldCommitPending(bool abandoned, bool has_pending) {
  return !abandoned && has_pending;
}

inline bool ShouldRestoreOwnedField(
    bool matches_before,
    bool matches_applied,
    bool matches_pending) {
  return !matches_before && (matches_applied || matches_pending);
}

}  // namespace proxy::internal

#endif  // FLUTTER_PLUGIN_PROXY_RESTORE_DECISION_H_