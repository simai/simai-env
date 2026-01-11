#!/usr/bin/env bash

doctor_results_init() {
  DOCTOR_STATUS=()
  DOCTOR_AREA=()
  DOCTOR_TITLE=()
  DOCTOR_DETAILS=()
  DOCTOR_HINTS=()
}

doctor_to_bytes() {
  local val="$1" num unit
  num=${val%[kmg]}
  unit=${val#$num}
  unit=${unit,,}
  case "$unit" in
    k) echo $((num*1024)) ;;
    m) echo $((num*1024*1024)) ;;
    g) echo $((num*1024*1024*1024)) ;;
    *) echo "$num" ;;
  esac
}

doctor_add_result() {
  local status="$1" area="$2" title="$3" details="$4" hint="${5:-}"
  DOCTOR_STATUS+=("$status")
  DOCTOR_AREA+=("$area")
  DOCTOR_TITLE+=("$title")
  DOCTOR_DETAILS+=("$details")
  DOCTOR_HINTS+=("$hint")
}

doctor_print_report() {
  local pass=0 warn=0 fail=0 skip=0
  local i
  for i in "${DOCTOR_STATUS[@]}"; do
    case "$i" in
      PASS) ((pass++)) ;;
      WARN) ((warn++)) ;;
      FAIL) ((fail++)) ;;
      SKIP) ((skip++)) ;;
    esac
  done
  local sep="+-------+------+\n"
  printf "$sep"
  printf "| %-5s | %4s |\n" "STAT" "CNT"
  printf "$sep"
  printf "| %-5s | %4d |\n" "PASS" "$pass"
  printf "| %-5s | %4d |\n" "WARN" "$warn"
  printf "| %-5s | %4d |\n" "FAIL" "$fail"
  printf "| %-5s | %4d |\n" "SKIP" "$skip"
  printf "$sep"
  local total=${#DOCTOR_STATUS[@]}
  local idx
  for idx in $(seq 0 $((total-1))); do
    local st="${DOCTOR_STATUS[$idx]}"
    local ttl="${DOCTOR_TITLE[$idx]}"
    local det="${DOCTOR_DETAILS[$idx]}"
    local hnt="${DOCTOR_HINTS[$idx]}"
    printf "[%s] %s — %s\n" "$st" "$ttl" "$det"
    if [[ -n "$hnt" && "$st" != "PASS" ]]; then
      printf "      Hint: %s\n" "$hnt"
    fi
  done
}

doctor_exit_code() {
  local strict="$1"
  local has_fail=0
  local st
  for st in "${DOCTOR_STATUS[@]}"; do
    [[ "$st" == "FAIL" ]] && has_fail=1
  done
  if [[ "${strict,,}" == "yes" && $has_fail -eq 1 ]]; then
    return 1
  fi
  return 0
}

doctor_php_modules() {
  local php_bin="$1"
  if [[ -z "$php_bin" ]]; then
    return 1
  fi
  "$php_bin" -m 2>/dev/null | tr '[:upper:]' '[:lower:]' | sed '/^\[/d;/^$/d' | sort -u
}

doctor_php_ini_get() {
  local php_bin="$1" key="$2"
  "$php_bin" -d detect_unicode=0 -r "echo ini_get('$key');" 2>/dev/null
}

doctor_normalize_bool() {
  local v="${1,,}"
  case "$v" in
    1|true|on|yes) echo "1" ;;
    0|false|off|no|"") echo "0" ;;
    *) echo "$1" ;;
  esac
}

doctor_parse_ini_expectation() {
  local line="$1"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [[ -z "$line" ]] && return 1
  if [[ "$line" != *=* ]]; then
    return 1
  fi
  local key="${line%%=*}"
  local val="${line#*=}"
  key="${key%"${key##*[![:space:]]}"}"
  val="${val#"${val%%[![:space:]]*}"}"
  echo "${key}|${val}"
}

doctor_compare_ini() {
  local key="$1" expected="$2" actual="$3"
  expected="${expected#"${expected%%[![:space:]]*}"}"
  expected="${expected%"${expected##*[![:space:]]}"}"
  actual="${actual#"${actual%%[![:space:]]*}"}"
  actual="${actual%"${actual##*[![:space:]]}"}"
  if [[ -z "$expected" || -z "$actual" ]]; then
    echo "unknown"
    return
  fi
  local ne na
  ne=$(doctor_normalize_bool "$expected")
  na=$(doctor_normalize_bool "$actual")
  if [[ "$ne" == "1" || "$ne" == "0" ]]; then
    [[ "$ne" == "$na" ]] && echo "ok" || echo "bad"
    return
  fi
  if [[ "$expected" =~ ^-?[0-9]+[KkMmGg]?$ && "$actual" =~ ^-?[0-9]+[KkMmGg]?$ ]]; then
    local exp_b act_b
    exp_b=$(doctor_to_bytes "$expected")
    act_b=$(doctor_to_bytes "$actual")
    if [[ "$exp_b" == "-1" ]]; then echo "ok"; return; fi
    if [[ "$act_b" == "-1" ]]; then echo "ok"; return; fi
    if (( act_b >= exp_b )); then echo "ok"; else echo "bad"; fi
    return
  fi
  if [[ "$expected" =~ ^-?[0-9]+$ && "$actual" =~ ^-?[0-9]+$ ]]; then
    local exp_i act_i
    exp_i="$expected"
    act_i="$actual"
    if (( act_i >= exp_i )); then echo "ok"; else echo "bad"; fi
    return
  fi
  if [[ "${expected,,}" == "${actual,,}" ]]; then
    echo "ok"
  else
    echo "bad"
  fi
}

doctor_ini_equals() {
  local expected="$1" actual="$2"
  expected="${expected#"${expected%%[![:space:]]*}"}"
  expected="${expected%"${expected##*[![:space:]]}"}"
  actual="${actual#"${actual%%[![:space:]]*}"}"
  actual="${actual%"${actual##*[![:space:]]}"}"
  if [[ -z "$expected" || -z "$actual" ]]; then
    echo "unknown"
    return
  fi
  local exp_lc="${expected,,}" act_lc="${actual,,}"
  local nb na
  nb=$(doctor_normalize_bool "$exp_lc")
  na=$(doctor_normalize_bool "$act_lc")
  if [[ "$nb" == "1" || "$nb" == "0" || "$na" == "1" || "$na" == "0" ]]; then
    [[ "$nb" == "$na" ]] && echo "yes" || echo "no"
    return
  fi
  if [[ "$exp_lc" =~ ^-?[0-9]+[kmg]?$ && "$act_lc" =~ ^-?[0-9]+[kmg]?$ ]]; then
    to_bytes() {
      local val="$1" num unit
      num=${val%[kmg]}
      unit=${val#$num}
      case "$unit" in
        k) echo $((num*1024)) ;;
        m) echo $((num*1024*1024)) ;;
        g) echo $((num*1024*1024*1024)) ;;
        *) echo "$num" ;;
      esac
    }
    local exp_b act_b
    exp_b=$(to_bytes "$exp_lc")
    act_b=$(to_bytes "$act_lc")
    if [[ "$exp_b" == "$act_b" ]]; then echo "yes"; else echo "no"; fi
    return
  fi
  if [[ "$exp_lc" =~ ^-?[0-9]+$ && "$act_lc" =~ ^-?[0-9]+$ ]]; then
    local exp_i act_i
    exp_i="$exp_lc"
    act_i="$act_lc"
    if (( act_i == exp_i )); then echo "yes"; else echo "no"; fi
    return
  fi
  if [[ "$exp_lc" == "$act_lc" ]]; then
    echo "yes"
  else
    echo "no"
  fi
}

doctor_ext_to_apt_pkg() {
  local ver="$1" ext="$2"
  case "$ext" in
    pdo_mysql|mysqli) echo "php${ver}-mysql" ;;
    curl) echo "php${ver}-curl" ;;
    mbstring) echo "php${ver}-mbstring" ;;
    xml|dom|simplexml|xmlreader|xmlwriter) echo "php${ver}-xml" ;;
    zip) echo "php${ver}-zip" ;;
    gd) echo "php${ver}-gd" ;;
    intl) echo "php${ver}-intl" ;;
    bcmath) echo "php${ver}-bcmath" ;;
    opcache) echo "php${ver}-opcache" ;;
    redis) echo "php${ver}-redis" ;;
    soap) echo "php${ver}-soap" ;;
    exif) echo "php${ver}-exif" ;;
    gmp) echo "php${ver}-gmp" ;;
    imagick) echo "php${ver}-imagick" ;;
    *) echo "" ;;
  esac
}
