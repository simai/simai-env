#!/usr/bin/env bash
# Package upgrades never stop on a configuration file question (1.59.2): a
# package whose changed conffile ships a new version upgrades without a
# terminal under simai-env's environment, keeps the changed file and puts
# the new default next to it; the same upgrade without it fails as the php
# update of a panel job did.
set -uo pipefail
rm -rf /root/simai-env-apt
cp -r /src /root/simai-env-apt
cd /root/simai-env-apt || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
w=$(mktemp -d)
mkpkg() {
  local v="$1" d="$w/simai-conf-$1"
  mkdir -p "$d/DEBIAN" "$d/etc/simai-conf-test"
  printf 'Package: simai-conf-test\nVersion: %s\nArchitecture: all\nMaintainer: test <t@example.test>\nDescription: conffile test\n' "$v" >"$d/DEBIAN/control"
  echo /etc/simai-conf-test/app.conf >"$d/DEBIAN/conffiles"
  echo "setting=$v" >"$d/etc/simai-conf-test/app.conf"
  dpkg-deb -b "$d" "$w/simai-conf-test_$v.deb" >/dev/null
}
mkpkg 1.0; mkpkg 2.0; mkpkg 3.0
dpkg -i "$w/simai-conf-test_1.0.deb" >/dev/null 2>&1 || bad 'install 1.0'
echo 'setting=local' >/etc/simai-conf-test/app.conf

# Without the environment the question cannot be answered.
(unset DPKG_FORCE UCF_FORCE_CONFFOLD; DEBIAN_FRONTEND=noninteractive apt-get install -y "$w/simai-conf-test_2.0.deb" </dev/null >/tmp/apt-plain 2>&1) \
  && bad 'plain upgrade passed: the control case shows nothing' || ok 'control: a plain upgrade stops on the conffile question'
dpkg --configure -a --force-confold </dev/null >/dev/null 2>&1

# With simai-env's environment (what every command and panel job gets).
env -i PATH="$PATH" HOME=/root bash -c 'source ./admin/core.sh >/dev/null 2>&1; apt-get install -y "$1" </dev/null' _ "$w/simai-conf-test_3.0.deb" >/tmp/apt-simai 2>&1 \
  && ok 'upgrade under simai-env needs no answer' || { bad 'upgrade under simai-env'; tail -8 /tmp/apt-simai; }
[[ "$(dpkg-query -W -f '${Version} ${Status}' simai-conf-test)" == "3.0 install ok installed" ]] && ok 'the package is configured' || bad "state: $(dpkg-query -W -f '${Version} ${Status}' simai-conf-test)"
[[ "$(cat /etc/simai-conf-test/app.conf)" == setting=local && -f /etc/simai-conf-test/app.conf.dpkg-dist ]] \
  && ok 'the changed file is kept, the new default is .dpkg-dist' || bad "files: $(ls /etc/simai-conf-test)"
dpkg --audit | grep -q . && bad 'dpkg --audit reports problems' || ok 'dpkg --audit is clean'
dpkg -P simai-conf-test >/dev/null 2>&1; rm -rf /etc/simai-conf-test "$w"
echo "failures=$fails"; exit "$fails"
