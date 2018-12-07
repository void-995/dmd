#!/bin/bash

set -uexo pipefail

HOST_DMD_VER=2.079.1 # same as in dmd/src/posix.mak
CURL_USER_AGENT="CirleCI $(curl --version | head -n 1)"
N=4
CIRCLE_NODE_INDEX=${CIRCLE_NODE_INDEX:-0}
CIRCLE_STAGE=${CIRCLE_STAGE:-pic}
CIRCLE_PROJECT_REPONAME=${CIRCLE_PROJECT_REPONAME:-dmd}
BUILD="debug"
DMD=dmd
PIC=1

case "${CIRCLE_STAGE}" in
    # Defined by old, existing PRs
    # Added to avoid needing to rebase them
    build)
        ;&
    pic)
        MODEL=64
        PIC=1
        ;;
    no_pic)
        PIC=0
        case $CIRCLE_NODE_INDEX in
            0) MODEL=64 ;;
            1) MODEL=32 ;;
        esac
esac

# clone druntime and phobos
clone() {
    local url="$1"
    local path="$2"
    local branch="$3"
    for i in {0..4}; do
        if git clone --branch "$branch" "$url" "$path" "${@:4}"; then
            break
        elif [ $i -lt 4 ]; then
            sleep $((1 << $i))
        else
            echo "Failed to clone: ${url}"
            exit 1
        fi
    done
}

download() {
    local url="$1"
    local fallbackurl="$2"
    local outputfile="$3"
    for i in {0..4}; do
        if curl -fsS -A "$CURL_USER_AGENT" --max-time 5 "$url" -o "$outputfile" ||
           curl -fsS -A "$CURL_USER_AGENT" --max-time 5 "$fallbackurl" -o "$outputfile" ; then
            break
        elif [ $i -ge 4 ]; then
            sleep $((1 << $i))
        else
            echo "Failed to download script ${outputfile}" 1>&2
            exit 1
        fi
    done
}

install_deps() {
    sudo apt-get update --quiet=2
    if [ $MODEL -eq 32 ]; then
        sudo apt-get install g++-multilib gdb --assume-yes --quiet=2
    else
        sudo apt-get install gdb --assume-yes --quiet=2
    fi

    download "https://dlang.org/install.sh" "https://nightlies.dlang.org/install.sh" "install.sh"

    source "$(CURL_USER_AGENT=\"$CURL_USER_AGENT\" bash install.sh dmd-$HOST_DMD_VER --activate)"
    $DC --version
    env
}

setup_repos() {
    # set a default in case we run into rate limit restrictions
    local base_branch=""
    if [ -n "${CIRCLE_PR_NUMBER:-}" ]; then
        base_branch=$((curl -fsSL https://api.github.com/repos/dlang/$CIRCLE_PROJECT_REPONAME/pulls/$CIRCLE_PR_NUMBER || echo) | jq -r '.base.ref')
    else
        base_branch=$CIRCLE_BRANCH
    fi
    base_branch=${base_branch:-"master"}

    # merge testee PR with base branch (master) before testing
    if [ -n "${CIRCLE_PR_NUMBER:-}" ]; then
        local head=$(git rev-parse HEAD)
        git remote add upstream "https://github.com/dlang/$CIRCLE_PROJECT_REPONAME.git"
        git fetch -q upstream "+refs/pull/${CIRCLE_PR_NUMBER}/merge:"
        git checkout -f FETCH_HEAD
    fi

    for proj in druntime phobos; do
        if [ $base_branch != master ] && [ $base_branch != stable ] &&
            ! git ls-remote --exit-code --heads https://github.com/dlang/$proj.git $base_branch > /dev/null; then
            # use master as fallback for other repos to test feature branches
            clone https://github.com/dlang/$proj.git ../$proj master --depth 1
        else
            clone https://github.com/dlang/$proj.git ../$proj $base_branch --depth 1
        fi
    done
}

coverage()
{
    # load environment for bootstrap compiler
    if [ -f ~/dlang/install.sh ] ; then
        source "$(CURL_USER_AGENT=\"$CURL_USER_AGENT\" bash ~/dlang/install.sh dmd-$HOST_DMD_VER --activate)"
    fi
    RDMD="$(type -p rdmd)"

    # build dmd, druntime, and phobos
    if [ "$MODEL" == "64" ] ; then
        "$RDMD" ./src/build.d MODEL=$MODEL HOST_DMD=$DMD BUILD=$BUILD ENABLE_WARNINGS=1 PIC="$PIC" all
    else
        make -j$N -C src -f posix.mak MODEL=$MODEL HOST_DMD=$DMD BUILD=$BUILD ENABLE_WARNINGS=1 PIC="$PIC" all
    fi
    make -j$N -C ../druntime -f posix.mak MODEL=$MODEL PIC="$PIC"
    make -j$N -C ../phobos -f posix.mak MODEL=$MODEL PIC="$PIC"

    # FIXME
    # Building d_do_test currently uses the host library for linking
    # Remove me after https://github.com/dlang/dmd/pull/7846 has been merged (-conf=)
    if [ -f ~/dlang/install.sh ] ; then
        deactivate
    else
        sudo rm -rf /dlang
    fi

    # FIXME
    # Temporarily the failing long file name test has been removed
    rm -rf test/compilable/issue17167.sh

    # rebuild dmd with coverage enabled
    # use the just build dmd as host compiler this time
    local build_path=generated/linux/release/$MODEL
    # `generated` gets cleaned in the next step, so we create another _generated
    # The nested folder hierarchy is needed to conform to those specified in
    # the generate dmd.conf
    mkdir -p _${build_path}
    cp $build_path/dmd _${build_path}/host_dmd
    cp $build_path/dmd.conf _${build_path}
    make -j$N -C src -f posix.mak MODEL=$MODEL HOST_DMD=../_${build_path}/host_dmd PIC="$PIC" clean
    make -j$N -C src -f posix.mak MODEL=$MODEL HOST_DMD=../_${build_path}/host_dmd ENABLE_COVERAGE=1 ENABLE_WARNINGS=1 PIC="$PIC"

    cp $build_path/dmd _${build_path}/host_dmd_cov
    make -j1 -C src -f posix.mak MODEL=$MODEL HOST_DMD=../_${build_path}/host_dmd_cov ENABLE_COVERAGE=1 PIC="$PIC" unittest
    make -j1 -C test MODEL=$MODEL ARGS="-O -inline -release" DMD_TEST_COVERAGE=1 PIC="$PIC"
}

# Checks that all files have been committed and no temporary, untracked files exist.
# See: https://github.com/dlang/dmd/pull/7483
check_clean_git()
{
    # Restore temporarily removed files
    git checkout test/compilable/issue17167.sh
    # Remove temporary directory + install script
    rm -rf _generated
    rm -f install.sh
    # auto-removal of these files doesn't work on CirleCi
    rm -f test/compilable/vcg-ast.d.cg
    rm -f test/test.mixin
    # Ensure that there are no untracked changes
    make -f posix.mak check-clean-git
}

# sanitycheck for the run_individual_tests script
check_run_individual()
{
    local build_path=generated/linux/release/$MODEL
	"${build_path}/dmd"  -i -run ./test/run.d test/runnable/template2962.d ./test/compilable/test14275.d
}

# Checks the D build.d script
check_d_builder()
{
    echo "Testing D build"
    # load environment for bootstrap compiler
    if [ -f ~/dlang/install.sh ] ; then
        source "$(CURL_USER_AGENT=\"$CURL_USER_AGENT\" bash ~/dlang/install.sh dmd-$HOST_DMD_VER --activate)"
    fi
    ./src/build.d clean
    rm -rf generated # just to be sure
    # TODO: add support for 32-bit builds
    ./src/build.d MODEL=64
    ./generated/linux/release/64/dmd --version | grep -v "dirty"
    ./src/build.d clean
    if [ -f ~/dlang/install.sh ] ; then
        deactivate
    fi
}

codecov()
{
    # CodeCov gets confused by lst files which it can't matched
    rm -rf test/runnable/extra-files
    download "https://codecov.io/bash" "https://raw.githubusercontent.com/codecov/codecov-bash/master/codecov" "codecov.sh"
    cd src # need to run from compilation folder for gcov to find sources
    bash ../codecov.sh -p .. -x gcov-4.9 # must match g++ version (on CircleCI `g++` is 4.9 and `gcov` 4.6 :/)
}

case $1 in
    install-deps) install_deps ;;
    setup-repos) setup_repos ;;
    all)
        check_d_builder;
        coverage;
        check_clean_git;
        check_run_individual;
        codecov;
    ;;
esac
