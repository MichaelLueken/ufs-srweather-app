#!/usr/bin/env bash
#
# A unified test script for the SRW application. This script is expected to
# test the SRW application for all supported platforms. NOTE: At this time,
# this script is a placeholder for a more robust test framework.
#
set -e -u -x

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" > /dev/null 2>&1 && pwd)"

# Get repository root from Jenkins WORKSPACE variable if set, otherwise, set
# relative to script directory.
declare workspace
if [[ -n "${WORKSPACE}" ]]; then
    workspace="${WORKSPACE}"
else
    workspace="$(cd -- "${script_dir}/../.." && pwd)"
fi

we2e_experiment_base_dir="${workspace}/experiments"
we2e_test_dir="${workspace}/regional_workflow/tests/WE2E"

we2e_test_file="${we2e_test_dir}/experiments.txt"

# The default set of end-to-end tests to run.
# TODO: Create a list of additional tests that can be run when a parameter
# is set to true.
declare -a we2e_default_tests
we2e_default_tests=('grid_RRFS_CONUS_25km_ics_FV3GFS_lbcs_FV3GFS_suite_GFS_v16'
    'grid_RRFS_CONUS_13km_ics_FV3GFS_lbcs_FV3GFS_suite_GFS_v16'
    'grid_SUBCONUS_Ind_3km_ics_FV3GFS_lbcs_FV3GFS_suite_GFS_v16')

# Parses the test log for the status of a specific test.
function workflow_status() {
    local test="$1"

    local test_dir="${we2e_experiment_base_dir}/${test}"
    local log_file="${test_dir}/log.launch_FV3LAM_wflow"

    if [[ -f "${log_file}" ]]; then
        local status
        status="$(awk 'BEGIN {FS=":";} $1 ~ "^[[:space:]]+Workflow status" {print $2}' "${log_file}" |\
            tail -1 |\
            sed --regexp-extended --expression 's/^[[:space:]]*(.*)[[:space:]]*$/\1/')"
        if [[ "${status}" == 'IN PROGRESS' || "${status}" == 'SUCCESS' || "${status}" == 'FAILURE' ]]; then
            echo "${status}"
        else
            echo 'UNKNOWN'
        fi
    else
        echo 'NOT FOUND'
    fi
}

# Gets the status of all tests. Prints the number of tests that are running.
# Returns a non-zero code when all tests reach a final state.
function check_progress() {
    local in_progress=false
    local remaining=0

    for test in "${we2e_default_tests[@]}"; do
        local status
        status="$(workflow_status "${test}")"
        if [[ "${status}" == 'IN PROGRESS' ]]; then
            in_progress=true
            (( remaining++ ))
        fi
    done

    if "${in_progress}"; then
        echo "Tests remaining: ${remaining}"
    else
        return 1
    fi
}

# Prints the status of all tests.
function get_results() {
    for test in "${we2e_default_tests[@]}"; do
        local status
        status="$(workflow_status "${test}")"
        echo "${test} ${status}"
    done
}

# Verify that there is a non-zero sized weather model executable.
[[ -s "${workspace}/bin/ufs_model" ]] || [[ -s "${workspace}/bin/NEMS.exe" ]]

# Set test related environment variables and load required modules.
source "${workspace}/etc/lmod-setup.sh" "${SRW_PLATFORM}"
module use "${workspace}/modulefiles"
module load "build_${SRW_PLATFORM}_${SRW_COMPILER}"
module load "wflow_${SRW_PLATFORM}"

if [[ "${SRW_PLATFORM}" == 'cheyenne' ]]; then
    export PATH="/glade/p/ral/jntp/UFS_CAM/ncar_pylib_20200427/bin:${PATH}"
else
    conda activate regional_workflow
fi

# Create the experiments/tests base directory.
mkdir "${we2e_experiment_base_dir}"

# Generate the experiments/tests file.
for test in "${we2e_default_tests[@]}"; do
    echo "${test}" >> "${we2e_test_file}"
done

# Run the end-to-end tests.
"${we2e_test_dir}/run_WE2E_tests.sh" \
    tests_file="${we2e_test_file}" \
    machine="${SRW_PLATFORM}" \
    account="${SRW_PROJECT}" \
    expt_basedir="${we2e_experiment_base_dir}" \
    compiler="${SRW_COMPILER}"

# Allow the tests to start before checking for status.
# TODO: Create a parameter that sets the initial start delay.
sleep 180

# Wait for all tests to complete.
while check_progress; do
    # TODO: Create a paremeter that sets the poll frequency.
    sleep 60
done

# Get test results and write to a file.
results="$(get_results |\
    tee "${workspace}/test_results-${SRW_PLATFORM}-${SRW_COMPILER}.txt")"

# Check that the number of tests equals the number of successes, otherwise
# exit with a non-zero code that equals the difference.
successes="$(awk '$2 == "SUCCESS" {print $1}' <<< "${results}" | wc -l)"
if [[ "${#we2e_default_tests[@]}" -ne "${successes}" ]]; then
    exit "$(( "${#we2e_default_tests[@]}" - "${successes}" ))"
fi