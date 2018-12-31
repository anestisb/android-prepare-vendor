#!/usr/bin/env bash
#
# sh-realpath implementation from mkropat
# https://github.com/mkropat/sh-realpath
#

set -e # fail on unhandled error

_realpath() {
  _canonicalize_path "$(_resolve_symlinks "$1")"
}

_resolve_symlinks() {
  __resolve_symlinks "$1"
}

__resolve_symlinks() {
  __assert_no_path_cycles "$@" || return

  local dir_context path
  path=$(readlink -- "$1")
  if [ $? -eq 0 ]; then
    dir_context=$(dirname -- "$1")
    __resolve_symlinks "$(__prepend_dir_context_if_necessary "$dir_context" "$path")" "$@"
  else
    printf '%s\n' "$1"
  fi
}

__prepend_dir_context_if_necessary() {
  if [ "$1" = . ]; then
    printf '%s\n' "$2"
  else
    __prepend_path_if_relative "$1" "$2"
  fi
}

__prepend_path_if_relative() {
  case "$2" in
    /* ) printf '%s\n' "$2" ;;
     * ) printf '%s\n' "$1/$2" ;;
  esac
}

__assert_no_path_cycles() {
  local target path

  target=$1
  shift

  for path in "$@"; do
    if [ "$path" = "$target" ]; then
      return 1
    fi
  done
}

_canonicalize_path() {
  if [ -d "$1" ]; then
    __canonicalize_dir_path "$1"
  else
    __canonicalize_file_path "$1"
  fi
}

__canonicalize_dir_path() {
  (cd "$1" 2>/dev/null && pwd -P)
}

__canonicalize_file_path() {
  local dir file
  dir=$(dirname -- "$1")
  file=$(basename -- "$1")
  (cd "$dir" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$file")
}
