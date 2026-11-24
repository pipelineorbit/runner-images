#!/usr/bin/env bash
# Smoke test for a server started from a new image. It runs as the runner user,
# usually through run-smoke.sh:
#
#   ssh runner@<server> bash -s < images/ubuntu/tests/smoke.sh
#
# Every check runs; the script exits non-zero if any of them failed.
set -uo pipefail

manifest_file=/etc/runner-image/manifest.json
passed=0
failed=0

# check <description> <command...>: runs one check and prints ok or FAIL, with
# the command's output when it fails.
check() {
  local description=$1 output
  shift
  if output=$("$@" 2>&1); then
    echo "ok    $description"
    passed=$((passed + 1))
  else
    echo "FAIL  $description"
    [[ -z $output ]] || awk '{ print "        " $0 }' <<<"$output"
    failed=$((failed + 1))
  fi
}

# manifest <jq filter>: a value from the image manifest.
manifest() { jq -r "$1" "$manifest_file"; }

# same <what> <actual> <expected>
same() {
  [[ $2 == "$3" ]] || {
    echo "$1 is '$2', expected '$3'"
    return 1
  }
}

cloud_init_done() {
  cloud-init status --long
}

no_failed_units() {
  local units
  units=$(systemctl --failed --no-legend --plain)
  [[ -z $units ]] || {
    echo "$units"
    return 1
  }
}

user_data_applied() {
  # This script logging in as runner with the test key already shows it worked.
  sudo cloud-init query userdata | grep -q '^#cloud-config'
}

tools_match_manifest() {
  diff <(manifest '.tools | to_entries[] | "\(.key) \(.value)"') \
    <(/usr/local/libexec/runner-image/tool-versions)
}

image_variables() {
  same ImageOS "${ImageOS:-}" "$(manifest .image)" &&
    same ImageVersion "${ImageVersion:-}" "$(manifest .version)"
}

tool_cache_writable() {
  same RUNNER_TOOL_CACHE "${RUNNER_TOOL_CACHE:-}" /opt/hostedtoolcache &&
    same AGENT_TOOLSDIRECTORY "${AGENT_TOOLSDIRECTORY:-}" /opt/hostedtoolcache &&
    touch /opt/hostedtoolcache/.smoke-test &&
    rm /opt/hostedtoolcache/.smoke-test
}

apt_updates_off() {
  local unit state bad=0
  for unit in apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service motd-news.timer; do
    state=$(systemctl is-enabled "$unit" 2>/dev/null)
    [[ $state == masked ]] || {
      echo "$unit is ${state:-missing}, not masked"
      bad=1
    }
  done
  if dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null | grep -q 'ok installed'; then
    echo "unattended-upgrades is installed"
    bad=1
  fi
  return "$bad"
}

apt_not_locked() {
  # Both fail at once, instead of waiting, if another process holds the lock.
  sudo dpkg --configure -a && sudo apt-get update -qq
}

runner_config_help() {
  cd ~/actions-runner && ./config.sh --help >/dev/null
}

swap_on() {
  local bytes
  bytes=$(swapon --show=SIZE --bytes --noheadings | awk '{ total += $1 } END { print total + 0 }')
  # Rounded to whole GiB: the kernel doesn't count the swap header page.
  same "swap (GiB)" $(((bytes + 512 * 1024 * 1024) / 1024 / 1024 / 1024)) "$(manifest .config.swap_size_gb)"
}

tmp_mode() {
  local fstype mode=disk
  fstype=$(findmnt -n -o FSTYPE --target /tmp)
  [[ $fstype != tmpfs ]] || mode=tmpfs
  same "/tmp ($fstype)" "$mode" "$(manifest .config.tmp_mode)"
}

machine_id_new() {
  local id
  id=$(cat /etc/machine-id)
  [[ $id =~ ^[0-9a-f]{32}$ ]] || {
    echo "machine ID '$id' is not valid"
    return 1
  }
  [[ $id != "$(manifest .build_host.machine_id)" ]] || {
    echo "machine ID $id was copied from the build server"
    return 1
  }
}

ssh_host_keys_new() {
  local keys copied
  keys=$(for key in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$key" | awk '{ print $2 }'; done)
  [[ -n $keys ]] || {
    echo "no SSH host keys"
    return 1
  }
  copied=$(grep -Fxf <(manifest '.build_host.ssh_host_keys[]') <<<"$keys")
  [[ -z $copied ]] || {
    echo "copied from the build server: $copied"
    return 1
  }
}

hostname_new() {
  [[ $(hostname) != "$(manifest .build_host.hostname)" ]] || {
    echo "hostname $(hostname) is the build server's"
    return 1
  }
}

runner_jit_idle() {
  same "runner-jit.service enabled" "$(systemctl is-enabled runner-jit.service)" enabled &&
    same "runner-jit.service state" "$(systemctl show -p ActiveState --value runner-jit.service)" inactive &&
    same "runner-jit.service start condition met" "$(systemctl show -p ConditionResult --value runner-jit.service)" no
}

snapd_removed() {
  ! command -v snap
}

echo "Image $(manifest .image) $(manifest .version) ($(manifest .arch)), commit $(manifest .commit)"
echo "Waiting for the boot to finish..."
cloud-init status --wait >/dev/null
systemctl is-system-running --wait >/dev/null

check "cloud-init finished without errors" cloud_init_done
check "cloud-init applied the user data" user_data_applied
check "tool versions match manifest.json" tools_match_manifest
check "docker run --rm hello-world" docker run --rm hello-world
check "docker buildx version" docker buildx version
check "passwordless sudo" sudo -n true
check "apt timers, unattended-upgrades and motd-news are off" apt_updates_off
check "apt is not locked" apt_not_locked
check "/opt/hostedtoolcache is writable and set as the tool cache" tool_cache_writable
check "ImageOS and ImageVersion are set" image_variables
check "runner: ./config.sh --help" runner_config_help
check "swap is on" swap_on
check "/tmp is $(manifest .config.tmp_mode)" tmp_mode
check "machine ID is new" machine_id_new
check "SSH host keys are new" ssh_host_keys_new
check "hostname is new" hostname_new
check "runner-jit.service is enabled and idle" runner_jit_idle
check "snapd is removed" snapd_removed
# Last, so it also covers the interfaces that `docker run` added.
check "no failed systemd units" no_failed_units

echo
echo "smoke test: $passed passed, $failed failed"
((failed == 0))
