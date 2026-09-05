#!/usr/bin/env bash
# Sourced only by build_and_run.sh. Keep preparation before host termination;
# the independently installed Selection Helper is outside this transaction.

install_stable_app() {
  local install_lock result=0
  mkdir -p "$STABLE_APP_DIR" || return 1
  install_lock="$STABLE_APP_DIR/.Blocks-install.lock"
  if ! mkdir "$install_lock"; then
    echo "error: another or interrupted Blocks install owns $install_lock; verify its state before retrying." >&2
    return 1
  fi
  if stage_and_replace_stable_app; then
    result=0
  else
    result=$?
  fi
  # An uncatchable interruption deliberately leaves the lock and any previous
  # bundle for inspection; never guess that an existing install lock is stale.
  if ! rmdir "$install_lock"; then
    echo "error: could not release the Blocks installation lock." >&2
    return 1
  fi
  return "$result"
}

stage_and_replace_stable_app() {
  local install_root staged_app previous_app
  if [[ -L "$APP_BUNDLE" || ( -e "$APP_BUNDLE" && ! -d "$APP_BUNDLE" ) ]]; then
    echo "error: stable app destination is not a regular bundle directory; refusing replacement." >&2
    return 1
  fi
  install_root="$(mktemp -d "$STABLE_APP_DIR/.Blocks-install.XXXXXX")" || return 1
  staged_app="$install_root/Blocks.app"
  previous_app="$install_root/previous.app"

  # A copy, disk-space or signing failure must leave the installed App intact
  # and must not stop the user's current host.
  if ! ditto "$BUILT_APP_BUNDLE" "$staged_app" \
    || [[ ! -x "$staged_app/Contents/MacOS/$APP_NAME" ]] \
    || ! codesign --verify --deep --strict "$staged_app"; then
    echo "error: candidate staging/verification failed; installed Blocks was not replaced." >&2
    rm -rf "$install_root"
    return 1
  fi

  if ! stop_stable_app; then
    rm -rf "$install_root"
    return 1
  fi
  # Recheck after preparation: do not replace a destination redirected while
  # the copy or process-exit verification was in progress.
  if [[ -L "$APP_BUNDLE" || ( -e "$APP_BUNDLE" && ! -d "$APP_BUNDLE" ) ]]; then
    echo "error: stable app destination changed; refusing replacement." >&2
    rm -rf "$install_root"
    return 1
  fi
  if [[ -e "$APP_BUNDLE" ]]; then
    if ! mv "$APP_BUNDLE" "$previous_app"; then
      echo "error: could not preserve the installed Blocks bundle; replacement stopped." >&2
      rm -rf "$install_root"
      return 1
    fi
  fi
  if ! mv "$staged_app" "$APP_BUNDLE"; then
    echo "error: candidate promotion failed; attempting to restore the previous bundle." >&2
    if [[ -e "$previous_app" ]]; then
      if [[ -e "$APP_BUNDLE" || -L "$APP_BUNDLE" ]] \
        || ! mv "$previous_app" "$APP_BUNDLE"; then
        echo "error: automatic restore could not complete; previous bundle retained at $previous_app." >&2
        return 1
      fi
    fi
    rm -rf "$install_root"
    return 1
  fi
  # Only discard the previous copy once the complete, verified candidate has
  # reached the stable path. This is not a crash-atomic directory swap.
  if ! rm -rf "$install_root"; then
    echo "warning: installed Blocks successfully, but staging cleanup is incomplete at $install_root." >&2
  fi
}
