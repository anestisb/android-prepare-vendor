#!/usr/bin/env bash

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && exit 1

command_exists() {
  type "$1" &> /dev/null
}

check_dir() {
  local dirPath="$1"
  local dirDesc="$2"

  if [[ "$dirPath" == "" || ! -d "$dirPath" ]]; then
    echo "[-] $dirDesc directory not found"
    usage
  fi
}

check_file() {
  local filePath="$1"
  local fileDesc="$2"

  if [[ "$filePath" == "" || ! -f "$filePath" ]]; then
    echo "[-] $fileDesc file not found"
    usage
  fi
}

check_opt_file() {
  local filePath="$1"
  local fileDesc="$2"

  if [[ "$filePath" != "" && ! -f "$filePath" ]]; then
    echo "[-] '$fileDesc' file not found"
    usage
  fi
}

array_contains() {
  local element
  for element in "${@:2}"; do [[ "$element" == "$1" ]] && return 0; done
  return 1
}

array_contains_rel() {
  local element
  for element in "${@:2}"; do [[ "$element" =~ $1 ]] && return 0; done
  return 1
}

isValidApiLevel() {
  local apiLevel="$1"
  if [[ ! "$apiLevel" = *[[:digit:]]* ]]; then
    echo "[-] Invalid API level '$apiLevel'"
    abort 1
  fi
}

isValidConfigType() {
  local confType="$1"
  if [[ "$confType" != "naked" && "$confType" != "full" ]]; then
    echo "[-] Invalid config type '$confType'"
    abort 1
  fi
}

jqRawStrTop() {
  local query="$1"
  local conf_file="$2"

  jq -r ".\"$query\"" "$conf_file" || {
    echo "[-] json raw top string parse failed" >&2
    abort 1
  }
}

jqIncRawArrayTop() {
  local query="$1"
  local conf_file="$2"

  jq -r ".\"$query\"[]" "$conf_file" || {
    echo "[-] json top raw string string parse failed" >&2
    abort 1
  }
}

jqRawStr() {
  local api="api-$1"
  local conf="$2"
  local query="$3"
  local conf_file="$4"

  jq -r ".\"$api\".\"$conf\".\"$query\"" "$conf_file" || {
    echo "[-] json raw string parse failed" >&2
    abort 1
  }
}

jqIncRawArray() {
  local api="api-$1"
  local conf="$2"
  local query="$3"
  local conf_file="$4"

  jq -r ".\"$api\".naked.\"$query\"[]" "$conf_file" || {
    echo "[-] json raw string array parse failed" >&2
    abort 1
  }

  if [[ "$conf" == "naked" ]]; then
    return
  fi

  jq -r ".\"$api\".full.\"$query\"[]" "$conf_file" || {
    echo "[-] json raw string array parse failed" >&2
    abort 1
  }

}
