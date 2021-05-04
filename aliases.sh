#!/bin/bash

# These functions by Chris Hajas try to achieve the following:
#
# - Have separate source code directories for gpdb4, gpdb5, gpdb6, master,
#   including separate database files, so we don't have to rebuild the
#   cluster when changing between GPDB versions. All of these are using
#   retail builds by default.
# - Have separate ORCA build directories for debug and retail, so we can
#   switch easily between the two for ctest. Switching the directory used
#   for GPDB from debug to retail requires a rebuild.
# - Install include files, binaries, libraries in the respective build
#   directories, not in /usr/local. This prevents issues with XCode
#   getting confused when files in /usr/local contain out-of-date
#   declarations.

# Commands to use:
#
# src5x            set up path to point to GPDB 5.x
#
# buildOrcaDev     build ORCA in debug mode
# buildOrcaRetail  build ORCA in retail mode (separate directory from debug build)
#
# build5x          build GPDB in retail mode on a 5.x based branch, using
#                  the last ORCA build done with buildOrcaDev or buildOrcaRetail
#
# start5x          start GPDB 5.x
#
# make5xCluster    make the cluster

# One-time setup:
#
# git clone git@github.com:greenplum-db/gpdb $SRC_DIR_5X
# sudo mkdir $INSTALL_DIR_5X
# sudo chown $USER $INSTALL_DIR_5X
# sudo chmod 775 $INSTALL_DIR_5X
# cd $SRC_DIR_5X
# git checkout 5X_STABLE
# git clone git@github.com:greenplum-db/gpdb $SRC_DIR_6X
# sudo mkdir $INSTALL_DIR_6X
# sudo chown $USER $INSTALL_DIR_6X
# sudo chmod 775 $INSTALL_DIR_6X
# cd $SRC_DIR_6X
# git checkout 6X_STABLE

# Customization
# -------------

# set this to the directories with your gpdb git clones
SRC_DIR_MASTER="${HOME}/workspace/gpdb"
SRC_DIR_6X="${HOME}/workspace/gpdb6"
SRC_DIR_5X="${HOME}/workspace/gpdb5"
SRC_DIR_4X="${HOME}/workspace/gpdb4"

# set this to the directories where you want to install the gpdb binaries and include files
INSTALL_DIR_MASTER="/usr/local/gpdb"
INSTALL_DIR_6X="/usr/local/gpdb6"
INSTALL_DIR_5X="/usr/local/gpdb5"
INSTALL_DIR_4X="/usr/local/gpdb4"

# set this to the directory with the ORCA git clone
ORCA_DIR_5X="${HOME}/workspace/gporca"

# specify the local name of the ORCA build directories for
# debug and retail builds
ORCA_BUILD_FILE_NAME=build
ORCA_DEV_SUFFIX=.dev
ORCA_REL_SUFFIX=.rel

# ORCA build directory for 5X, you could change this to the release build directory
# and build ORCA with buildOrcaRetail
ORCA_BUILD_DIR_5X="${ORCA_DIR_5X}/${ORCA_BUILD_FILE_NAME}${ORCA_DEV_SUFFIX}"

# the locations in the build directory where ORCA binaries and include files
# will be installed (note that the ORCA_BUILD_DIR_5X variable is not yet expanded
ORCA_INCLUDE_DIR="\${ORCA_BUILD_DIR_5X}/usr/local/include"
ORCA_LIB_DIR="\${ORCA_BUILD_DIR_5X}/usr/local/lib"

# flags for configure, again the env vars are not yet expanded
# to enable asserts, add this to CONFIGURE_FLAGS: --enable-cassert
# to enable symbols and disable code optimization, add this: --enable-debug
# for plpython, add --with-python
CONFIGURE_FLAGS="--config-cache --without-zstd --disable-gpcloud --enable-debug --enable-depend --enable-orca --with-python --with-quicklz --enable-orafce --disable-gpfdist"
CONFIGURE_FLAGS_DBG="--enable-cassert"
CONFIGURE_FLAGS_REL=""
CONFIGURE_FLAGS_5X="${CONFIGURE_FLAGS} \
                 --with-includes=\${ORCA_INCLUDE_DIR}:/usr/local/include \
                 --with-libraries=\${ORCA_LIB_DIR}:/usr/local/lib"
CLUSTER_FLAGS="WITH_STANDBY=false WITH_MIRRORS=false NUM_PRIMARY_MIRROR_PAIRS=3"
# compiler flags to use
GPDB_CFLAGS_DBG="-O0 -g3"
GPDB_CFLAGS_REL="-O3 -g3"

if [ "${SHELL}" = "/bin/zsh" ]; then
  PROMPT='[%~ $(git branch 2> /dev/null | grep "* " | sed "s/* \(.*\)/{\1}/") $(shortStatus)]\$ '
else
  PS1="[\w: \$(git branch 2> /dev/null | grep -e '\* ' | sed 's/^..\(.*\)/{\1}/') \$(shortStatus)]\$ "
fi

# end of customization
# --------------------

# helper functions, not meant to be invoked outside of this file

function buildGpdbHelper {
  # $1: install dir, gets cleaned out first
  # $2: 0: skip configure, 1: do configure step
  # $3: 0: debug build,    1: release build

  # expand ORCA build directory in needed environment variables (twice, where needed)
  ORCA_LIB_DIR_EXP=$(eval echo ${ORCA_LIB_DIR})
  if [ -d src/backend/gporca ]; then
    # code path for Orca in GPDB, no need to include Orca headers and libraries through flags
    CONFIGURE_FLAGS_EXP=${CONFIGURE_FLAGS}
  else
    CONFIGURE_FLAGS_EXP=$(eval echo $(eval echo ${CONFIGURE_FLAGS_5X}))
  fi
  if [ $3 -eq 0 ]; then
    CONFIGURE_FLAGS_EXP="${CONFIGURE_FLAGS_EXP} $CONFIGURE_FLAGS_DBG"
    GPDB_CFLAGS=${GPDB_CFLAGS_DBG}
  else
    CONFIGURE_FLAGS_EXP="${CONFIGURE_FLAGS_EXP} $CONFIGURE_FLAGS_REL"
    GPDB_CFLAGS=${GPDB_CFLAGS_REL}
  fi
  if [ $2 -ne 0 ]; then
    CONFIGURE_CMD="./configure"
    CONFIGURE_ARGS="--prefix=${1} ${CONFIGURE_FLAGS_EXP}"
  else
    CONFIGURE_CMD=true
    CONFIGURE_ARGS=""
  fi
  if [ -d src/backend/gporca ]; then
    echo "CFLAGS=${GPDB_CFLAGS} ${CONFIGURE_CMD} ${CONFIGURE_ARGS}"
    CFLAGS="${GPDB_CFLAGS}" /bin/bash -c "${CONFIGURE_CMD} ${CONFIGURE_ARGS}" && \
    make -s -j 8 | tee build.log && \
    rm -rf ${1}/* && \
    make -s install | tee build.install.log
  else
    echo "CFLAGS=${GPDB_CFLAGS} LDFLAGS=-rpath ${ORCA_LIB_DIR_EXP} ${CONFIGURE_CMD}"
    CFLAGS=${GPDB_CFLAGS} \
    LDFLAGS="-rpath ${ORCA_LIB_DIR_EXP}" /bin/bash -c "${CONFIGURE_CMD} ${CONFIGURE_ARGS}" && \
    make -s -j8 | tee build.log && \
    rm -rf ${1}/* && \
    make -s install | tee build.install.log
  fi
}

# external functions, use these on the command line
# -------------------------------------------------

# set environment variables so we can start psql for various GPDB versions

function srcGpdb {
  case `whichGpdb` in
    master)
      echo "Running GPDB master"
      srcMaster
      ;;
    6X)
      echo "Running GPDB 6X"
      src6x
      ;;
    5X)
      echo "Running GPDB 5X"
      src5x
      ;;
    4X)
      echo "Running GPDB 4X"
      src4x
      ;;
    none)
      echo "Did nothing, GPDB is not running"
      ;;
	*)
	  echo "Couldn't determine which GPDB version is running"
  esac
}

function srcMaster {
  pushd ${INSTALL_DIR_MASTER}
  if [ -f greenplum_path.sh ]; then
    source greenplum_path.sh
  fi
  source ${SRC_DIR_MASTER}/gpAux/gpdemo/gpdemo-env.sh
  export CURRENT_SRC_DIR=${SRC_DIR_MASTER}
  unset PYTHONHOME
  popd
}

function src6x {
  pushd ${INSTALL_DIR_6X}
  if [ -f greenplum_path.sh ]; then
    source greenplum_path.sh
  fi
  source ${SRC_DIR_6X}/gpAux/gpdemo/gpdemo-env.sh
  export CURRENT_SRC_DIR=${SRC_DIR_6X}
  unset PYTHONHOME
  popd
}

function src5x {
  pushd ${INSTALL_DIR_5X}
  if [ -f greenplum_path.sh ]; then
    source greenplum_path.sh
  fi
  source ${SRC_DIR_5X}/gpAux/gpdemo/gpdemo-env.sh
  export CURRENT_SRC_DIR=${SRC_DIR_5X}
  unset PYTHONHOME
  popd
}

function src4x {
  pushd ${INSTALL_DIR_4X}
  if [ -f ${INSTALL_DIR_4X}/greenplum_path.sh ]; then
    source ${INSTALL_DIR_4X}/greenplum_path.sh
  fi
  source ${SRC_DIR_4X}/gpAux/gpdemo/gpdemo-env.sh
  export CURRENT_SRC_DIR=${SRC_DIR_4X}
  unset PYTHONHOME
  popd
}


# delete the entire cluster

function delMasterCluster {
  killall postgres
  rm -rf ${SRC_DIR_MASTER}/gpAux/gpdemo/datadirs/*
}

function del6xCluster {
  killall postgres
  rm -rf ${SRC_DIR_6X}/gpAux/gpdemo/datadirs/*
}

function del5xCluster {
  killall postgres
  rm -rf ${SRC_DIR_5X}/gpAux/gpdemo/datadirs/*
}

function del4xCluster {
  killall postgres
  rm -rf ${SRC_DIR_4X}/gpAux/gpdemo/datadirs/*
}


# build the code

function buildMaster {
  local DO_CONFIGURE=1
  local DO_RELEASE=0
  while [ $# -gt 0 ]
    do
      if [ "$1" = '-n' ]; then
        DO_CONFIGURE=0
      elif [ "$1" = '-r' ]; then
          DO_RELEASE=1
      else
        echo "Usage: $0 [-n] [-r]\n-n: no configure, -r: release build"
        return
      fi
      shift
  done
  pushd ${SRC_DIR_MASTER} && \
  buildGpdbHelper ${INSTALL_DIR_MASTER} ${DO_CONFIGURE} ${DO_RELEASE} && \
  popd
}

function build6x {
  local DO_CONFIGURE=1
  local DO_RELEASE=0
  while [ $# -gt 0 ]
    do
      if [ "$1" = '-n' ]; then
        DO_CONFIGURE=0
      elif [ "$1" = '-r' ]; then
        DO_RELEASE=1
      else
        echo "Usage: $0 [-n] [-r]\n-n: no configure, -r: release build"
        return
      fi
      shift
  done
  pushd ${SRC_DIR_6X} && \
  buildGpdbHelper ${INSTALL_DIR_6X} ${DO_CONFIGURE} ${DO_RELEASE} && \
  popd
}

function build5x {
  local DO_CONFIGURE=1
  local DO_RELEASE=0
  while [ $# -gt 0 ]
    do
      if [ "$1" = '-n' ]; then
        DO_CONFIGURE=0
      elif [ "$1" = '-r' ]; then
          DO_RELEASE=1
      else
        echo "Usage: $0 [-n] [-r]\n-n: no configure, -r: release build"
        return
      fi
      shift
  done
  pushd ${SRC_DIR_5X} && \
  buildGpdbHelper ${INSTALL_DIR_5X} ${DO_CONFIGURE} ${DO_RELEASE} && \
  popd
}

function build4x {
  echo "Not supported with these scripts, do this instead"
  cat <<EOF
    cd ~/workspace/gp-qpa-ci-infrastructure/scripts
    . ./dev_shell.bashrc
    gpdb_oss_env
    enable_gporca
    src4x
    rebuild_all_gpdb4_clang_retail
    cd ~/workspace/gpdb4/gpAux/gpdemo
    make cluster
    createdb
    exit
EOF
}


# stop GPDB

function stopGpdb {
  case `whichGpdb` in
    master)
      stopMaster
      ;;
    6X)
      stop6x
      ;;
    5X)
      stop5x
      ;;
    none)
      # nothing to do
      ;;
	*)
	  echo "Couldn't determine which GPDB version is running"
  esac
}

function stopMaster {
  srcMaster
  gpstop -ai
}

function stop6x {
  src6x
  gpstop -ai
}

function stop5x {
  src5x
  gpstop -ai
}

function stop4x {
  src4x
  gpstop -ai 
}

# start GPDB

function startMaster {
  stopGpdb
  srcMaster
  gpstart -a
}

function start6x {
  stopGpdb
  src6x
  gpstart -a
}

function start5x {
  stopGpdb
  src5x
  gpstart -a
}

function start4x {
  stopGpdb
  src4x
  gpstart -a
}

# rebuild and restart GPDB after a code change

function updateMaster {
  buildMaster -n
  startMaster
}

function update6x {
  build6x -n
  start6x
}

function update5x {
  buildOrca
  build5x -n
  start5x
}

# rebuild the cluster

function makeMasterCluster {
  stopGpdb
  pushd ${SRC_DIR_MASTER}/gpAux/gpdemo
  srcMaster
  make cluster ${CLUSTER_FLAGS}
  createdb
  popd
}

function make6xCluster {
  stopGpdb
  pushd ${SRC_DIR_6X}/gpAux/gpdemo
  src6x
  make cluster ${CLUSTER_FLAGS}
  createdb
  popd
}

function make5xCluster {
  stopGpdb
  pushd ${SRC_DIR_5X}/gpAux/gpdemo
  src5x
  SHELL=/bin/bash make cluster ${CLUSTER_FLAGS}
  createdb
  popd
}


# build debug and release flavors of ORCA

function buildOrcaDevOrRel {
  if [ -d /usr/local/include/gpopt ]; then
     echo "Found files from other scripts in /usr/local/include, please run cleanUsrLocal"
     return 1
  fi
  local ORCA_BUILD_SUFFIX=${ORCA_DEV_SUFFIX}
  local ORCA_BUILD_TYPE="DEBUG"
  local NINJA_TARGET=""
  if [ ${1} != "dev" ]; then
    local ORCA_BUILD_SUFFIX=${ORCA_REL_SUFFIX}
    local ORCA_BUILD_TYPE="RelWithDebInfo"
  fi
  if [ -d ${CURRENT_SRC_DIR}/src/backend/gporca ]; then
    ORCA_BUILD_DIR=${CURRENT_SRC_DIR}/src/backend/gporca/${ORCA_BUILD_FILE_NAME}${ORCA_BUILD_SUFFIX}
  else
    ORCA_BUILD_DIR=${ORCA_BUILD_DIR_5X}
    NINJA_TARGET="install"
  fi
  if [ ! -d ${ORCA_BUILD_DIR} ]; then
    mkdir ${ORCA_BUILD_DIR}
  fi
  pushd ${ORCA_BUILD_DIR}/..
  echo "DESTDIR=${ORCA_BUILD_DIR} cmake -GNinja -D CMAKE_BUILD_TYPE=${ORCA_BUILD_TYPE} -D CMAKE_EXPORT_COMPILE_COMMANDS=1 -H. -B${ORCA_BUILD_FILE_NAME}${ORCA_BUILD_SUFFIX}"
  DESTDIR=${ORCA_BUILD_DIR} cmake -GNinja -D CMAKE_BUILD_TYPE=${ORCA_BUILD_TYPE} -D CMAKE_EXPORT_COMPILE_COMMANDS=1 -H. -B${ORCA_BUILD_FILE_NAME}${ORCA_BUILD_SUFFIX}
  echo "DESTDIR=${ORCA_BUILD_DIR} ninja ${NINJA_TARGET} -C ${ORCA_BUILD_FILE_NAME}${ORCA_BUILD_SUFFIX} | grep -v -e '-- Up-to-date:'"
  DESTDIR=${ORCA_BUILD_DIR} ninja ${NINJA_TARGET} -C ${ORCA_BUILD_FILE_NAME}${ORCA_BUILD_SUFFIX} | grep -v -e '-- Up-to-date:'
  popd
}

function buildOrcaDev {
  buildOrcaDevOrRel dev
}

function buildOrcaRetail {
  buildOrcaDevOrRel rel
}

function buildOrca {
  buildOrcaDev
}

# clean files installed into default directories (by other install scripts, not this one)

function cleanUsrLocal {
  rm -rf /usr/local/include/naucrates
  rm -rf /usr/local/include/gpdbcost
  rm -rf /usr/local/include/gpopt
  rm -rf /usr/local/include/gpos
  rm -rf /usr/local/lib/libnaucrates.*
  rm -rf /usr/local/lib/libgpdbcost.*
  rm -rf /usr/local/lib/libgpopt.*
  rm -rf /usr/local/lib/libgpos.*
}

# various "cd" commands

function cdOrca {
  if [ -d ${CURRENT_SRC_DIR}/src/backend/gporca ]; then
    cd ${CURRENT_SRC_DIR}/src/backend/gporca
  else
    cd ${ORCA_DIR_5X}
  fi
}

function cdOrca4x {
  cd4x
  cdOrca
}

function cdOrca5x {
  cd5x
  cdOrca
}

function cdOrca6x {
  cd6x
  cdOrca
}

function cdOrcaMaster {
  cdMaster
  cdOrca
}

function cdMaster {
  srcMaster
  cd ${SRC_DIR_MASTER}
}

function cd6x {
  src6x
  cd ${SRC_DIR_6X}
}

function cd5x {
  src5x
  cd ${SRC_DIR_5X}
}

function cd4x {
  src4x
  cd ${SRC_DIR_4X}
}


# status commands

function showOrca {
  XX_HOME=~
  echo "Currently using ORCA build dir $ORCA_BUILD_DIR" | sed "s#${XX_HOME}#~#"
}

function whichGpdb {
  GP_MASTER_EXECUTABLE=`ps -A -o command | grep /bin/postgres | grep -e '-E' -e 'role=dispatch' | cut -f 1 -d ' '`
  if [ -n "${GP_MASTER_EXECUTABLE}" ]; then
    if [ $(dirname $(dirname ${GP_MASTER_EXECUTABLE})) = ${INSTALL_DIR_MASTER} ]; then
      echo "master"
    elif [ $(dirname $(dirname ${GP_MASTER_EXECUTABLE})) = ${INSTALL_DIR_6X} ]; then
      echo "6X"
    elif [ $(dirname $(dirname ${GP_MASTER_EXECUTABLE})) = ${INSTALL_DIR_5X} ]; then
      echo "5X"
    elif [ $(dirname $(dirname ${GP_MASTER_EXECUTABLE})) = ${INSTALL_DIR_4X} ]; then
      echo "4X"
    else
      echo "unknown"
    fi
  else
    echo "none"
  fi
}

function shortStatus {
	XX_S1=$(whichGpdb | sed -e 's/master/M/' -e 's/unknown/?/')
	XX_S2=$(echo ${ORCA_BUILD_DIR_5X} | grep '\.rel$' | sed -e 's/.*\.rel/-r/')
	echo "${XX_S1}${XX_S2}"
}

# rebuild XCode environment

function rebuildGpdbXCodeProject {
  TMP_CMAKELISTS=/tmp/CMakeLists.txt
  XCODE_PROJNAME=gpdb_master
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer/
  wget https://raw.githubusercontent.com/zellerh/gpdb_xcode/master/CMakeLists.txt --output-document=$TMP_CMAKELISTS
  wget https://raw.githubusercontent.com/zellerh/gpdb_xcode/master/pre-push --output-document=.git/hooks/pre-push
  chmod +x .git/hooks/pre-push

  if [ ${CURRENT_SRC_DIR} = ${SRC_DIR_5X} ]; then
    XCODE_PROJNAME=gpdb5
  elif [ ${CURRENT_SRC_DIR} = ${SRC_DIR_6X} ]; then
    XCODE_PROJNAME=gpdb6
  fi

  cd $CURRENT_SRC_DIR
  cat $TMP_CMAKELISTS | sed "s/gpdb/${XCODE_PROJNAME}/" >CMakeLists.txt

  rm -rf build.xcode
  mkdir build.xcode
  cd build.xcode
  cmake -GXcode -DCMAKE_BUILD_TYPE=Debug  ../
  open ${XCODE_PROJNAME}.xcodeproj/

  sudo xcode-select -s /Library/Developer/CommandLineTools
  cd ..
}

function rebuildOrcaXCodeProject {
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer/

  cdOrca
  rm -rf build.xcode
  mkdir build.xcode
  cd build.xcode
  cmake -GXcode -DCMAKE_BUILD_TYPE=Debug  ../
  open gpopt*.xcodeproj/

  sudo xcode-select -s /Library/Developer/CommandLineTools
  cd ..
}

# porting fixes from one release to another (provide commit range as optional argument)

function createOrcaPatch {
    cd $CURRENT_SRC_DIR
    if [ -d src/backend/gporca ]; then
    	git format-patch $* --minimal --stdout -- src/backend/gporca > /tmp/orca_patch
    else
        cdOrca
        pwd
        git format-patch $* --minimal --stdout -- . > /tmp/orca_patch
    fi
}

function createGPDBPatch {
	cd $CURRENT_SRC_DIR
	git format-patch $* --minimal --stdout -- . ':!src/backend/gporca' ':!config/orca.m4' ':!configure' ':!depends/conanfile_orca.txt' ':!gpAux/releng/releng.mk' > /tmp/gpdb_patch
}

function applyOrcaPatch {
    cd $CURRENT_SRC_DIR
    grep -s '/src/backend/gporca' /tmp/orca_patch >/dev/null
    if [ $? -eq 0 ]; then
      if [ ${CURRENT_SRC_DIR} = ${SRC_DIR_5X} ]; then
        echo "patch generated on 6X/master, applying to 5X"
        cdOrca
        git am -3 /tmp/orca_patch -p4
      else
        echo "patch was generated on 6X/master, target is also 6X/master"
        git am -3 /tmp/orca_patch
      fi
    else
      if [ ${CURRENT_SRC_DIR} = ${SRC_DIR_5X} ]; then
        echo "patch generated on 5X, applying to 5X"
        cdOrca
        git am -3 /tmp/orca_patch
      else
        echo "patch was generated on 5X, target is 6X/master"
        git am -3 /tmp/orca_patch --directory src/backend/gporca
      fi
    fi
}

function applyGPDBPatch {
    cd $CURRENT_SRC_DIR
	git am -3 /tmp/gpdb_patch
}
