#! /usr/bin/env bash

###############################################################################
# Copyright 2020 The Apollo Authors. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
###############################################################################

set -e

TOP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${TOP_DIR}/scripts/apollo_base.sh"

ARCH="$(uname -m)"

: ${USE_ESD_CAN:=false}

CMDLINE_OPTIONS=
SHORTHAND_TARGETS=
DISABLED_TARGETS=

function _determine_drivers_disabled() {
  if ! ${USE_ESD_CAN}; then
    warning "ESD CAN library supplied by ESD Electronics doesn't exist."
    warning "If you need ESD CAN, please refer to:"
    warning "  third_party/can_card_library/esd_can/README.md"
    DISABLED_TARGETS="${DISABLED_TARGETS} except //modules/drivers/canbus/can_client/esd/..."
  fi
}

function _determine_perception_disabled() {
  if [ "${USE_GPU}" -eq 0 ]; then
    warning "Perception module can not work without GPU, all targets skipped"
    DISABLED_TARGETS="${DISABLED_TARGETS} except //modules/perception/..."
  fi
}

function _determine_localization_disabled() {
  if [ "${ARCH}" != "x86_64" ]; then
    # Skip msf for non-x86_64 platforms
    DISABLED_TARGETS="${disabled} except //modules/localization/msf/..."
  fi
}

function _determine_planning_disabled() {
  if [ "${USE_GPU}" -eq 0 ]; then
    DISABLED_TARGETS="${DISABLED_TARGETS} except //modules/planning/open_space/trajectory_smoother:planning_block \
                      except //modules/planning/learning_based/..."
  fi
}

function _determine_map_disabled() {
  if [ "${USE_GPU}" -eq 0 ]; then
    DISABLED_TARGETS="${DISABLED_TARGETS} except //modules/map/pnc_map:cuda_pnc_util \
                      except //modules/map/pnc_map:cuda_util_test"
  fi
}

function determine_disabled_build_targets() {
  DISABLED_TARGETS=""
  local component="$1"
  if [ -z "${component}" ]; then
    _determine_drivers_disabled
    _determine_localization_disabled
    _determine_perception_disabled
    _determine_planning_disabled
    _determine_map_disabled
  else
    case "${component}" in
      drivers)
        _determine_drivers_disabled
        ;;
      localization)
        _determine_localization_disabled
        ;;
      perception)
        _determine_perception_disabled
        ;;
      planning)
        _determine_planning_disabled
        ;;
      map)
        _determine_map_disabled
        ;;
    esac
  fi

  echo "${DISABLED_TARGETS}"
  # DISABLED_CYBER_MODULES="except //cyber/record:record_file_integration_test"
}

# components="$(echo -e "${@// /\\n}" | sort -u)"
# if [ ${PIPESTATUS[0]} -ne 0 ]; then ... ; fi

function determine_build_targets() {
  local targets_all
  local exceptions
  if [[ "$#" -eq 0 ]]; then
    exceptions="$(determine_disabled_build_targets)"
    targets_all="//modules/... union //cyber/... ${exceptions}"
    echo "${targets_all}"
    return
  fi

  for component in $@; do
    local build_targets
    local exceptions
    if [[ "${component}" == "cyber" ]]; then
      build_targets="//cyber/... union //modules/tools/visualizer/..."
    elif [[ -d "${APOLLO_ROOT_DIR}/modules/${component}" ]]; then
      exceptions="$(determine_disabled_build_targets ${component})"
      build_targets="//modules/${component}/... ${exceptions}"
    else
      error "Oops, no such component '${component}' under <APOLLO_ROOT_DIR>/modules/ . Exiting ..."
      exit 1
    fi
    if [ -z "${targets_all}" ]; then
      targets_all="${build_targets}"
    else
      targets_all="${targets_all} union ${build_targets}"
    fi
  done
  echo "${targets_all}"
}

function _parse_cmdline_arguments() {
  local known_options=""
  local remained_args=""

  for ((pos = 1; pos <= $#; pos++)); do #do echo "$#" "$i" "${!i}"; done
    local opt="${!pos}"
    local optarg

    case "${opt}" in
      --config=*)
        optarg="${opt#*=}"
        known_options="${known_options} ${opt}"
        ;;
      --config)
        ((++pos))
        optarg="${!pos}"
        known_options="${known_options} ${opt} ${optarg}"
        ;;
      -c)
        ((++pos))
        optarg="${!pos}"
        known_options="${known_options} ${opt} ${optarg}"
        ;;
      *)
        remained_args="${remained_args} ${opt}"
        ;;
    esac
  done
  # Strip leading whitespaces
  known_options="$(echo "${known_options}" | sed -e 's/^[[:space:]]*//')"
  remained_args="$(echo "${remained_args}" | sed -e 's/^[[:space:]]*//')"

  CMDLINE_OPTIONS="${known_options}"
  SHORTHAND_TARGETS="${remained_args}"
}

function _run_bazel_build_impl() {
  local job_args="--jobs=$(nproc) --local_ram_resources=HOST_RAM*0.7"
  bazel build ${job_args} $@
}

function bazel_build() {
  if ! "${APOLLO_IN_DOCKER}"; then
    error "The build operation must be run from within docker container"
    exit 1
  fi

  _parse_cmdline_arguments $@

  CMDLINE_OPTIONS="${CMDLINE_OPTIONS} --define USE_ESD_CAN=${USE_ESD_CAN}"

  local build_targets
  build_targets="$(determine_build_targets ${SHORTHAND_TARGETS})"
  build_targets="$(echo ${build_targets} | xargs)"

  info "Build Overview: "
  info "${TAB}Bazel Options: ${GREEN}${CMDLINE_OPTIONS}${NO_COLOR}"
  info "${TAB}Build Targets: ${GREEN}${build_targets}${NO_COLOR}"

  _run_bazel_build_impl "${CMDLINE_OPTIONS}" "$(bazel query ${build_targets})"
}

function build_simulator() {
  local SIMULATOR_TOP_DIR="/apollo-simulator"
  if [ -d "${SIMULATOR_TOP_DIR}" ] && [ -e "${SIMULATOR_TOP_DIR}/build.sh" ]; then
    pushd "${SIMULATOR_TOP_DIR}"
    if bash build.sh build; then
      success "Done building Apollo simulator."
    else
      fail "Building Apollo simulator failed."
    fi
    popd >/dev/null
  fi
}

function main() {
  if [ "${USE_GPU}" -eq 1 ]; then
    info "Your GPU is enabled to run the build on ${ARCH} platform."
  else
    info "Running build under CPU mode on ${ARCH} platform."
  fi
  bazel_build $@
  if [ -z "${SHORTHAND_TARGETS}" ]; then
    SHORTHAND_TARGETS="apollo"
    build_simulator
  fi
  success "Done building ${SHORTHAND_TARGETS}. Enjoy!"
}

main "$@"
