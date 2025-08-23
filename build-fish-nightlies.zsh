#! /usr/bin/zsh -e

###################
# Script configuration

# Note that you may wish to set the following variables before running
# this tool. There are no sensible defaults.
# DEBFULLNAME (e.g. Janice Lai)
# DEBEMAIL (e.g. jlai@gmail.com)

BUILD_AREA=~/fish_built
FISH_SRCDIR=$BUILD_AREA/fish-shell
FISH_BUILDSRCDIR=$BUILD_AREA/fish-build
# dpkg build for Ubuntu PPAs
DPKG_AREA=$BUILD_AREA/dpkgs
# OpenSUSE Build Service staging area
OBS_AREA=$BUILD_AREA/obs

# build for the following PPA architectures:
PPA_SERIES=(
$(python3 <<EOF
from launchpadlib.launchpad import Launchpad
launchpad = Launchpad.login_anonymously('fish shell build script', 'production', '~/.cache', version='devel')
ubu = launchpad.projects('ubuntu')
print('\n'.join(x['name'] for x in ubu.series.entries if x['supported'] == True))
EOF
 )
)
# (zsh array - will not work in bash or sh)

GPG_KEYID=3E03B4E97C71CD1C0E94B287FCA50E480C273BBA

###################
# Set up

umask 022
set -e

# check whether we have anything to do

cd $FISH_SRCDIR

git fetch origin

CURRENT_SHA=`git rev-parse --short master`
UPSTREAM_SHA=`git rev-parse --short origin/master`

[ "x$1" = "x--force" ] && CURRENT_SHA=force
[ "$CURRENT_SHA" = "$UPSTREAM_SHA" ] && exit 0

# update to the latest git tree

git checkout master
git merge origin/master

VERSION=`git describe --dirty 2>/dev/null`
MASTER_SHA=`git rev-parse --short master`
RPMVERSION=`echo $VERSION |sed 's/-/+/
s/-/./'`

# build archive
build_tools/make_tarball.sh

ARCHIVE=$BUILD_AREA/fish-$VERSION.tar.xz

# build vendor archive
build_tools/make_vendor_tarball.sh

VENDOR_ARCHIVE=$BUILD_AREA/fish-$VERSION-vendor.tar.xz

###################
# Debian package build

# make 'orig' tarball appear
DPKG_ORIG_ARCHIVE=$DPKG_AREA/fish_$VERSION.orig.tar.xz
DPKG_ORIG_VENDOR_ARCHIVE=$DPKG_AREA/fish_$VERSION.orig-cargo-vendor.tar.xz
rm -f $DPKG_ORIG_ARCHIVE $DPKG_ORIG_VENDOR_ARCHIVE
ln -s $ARCHIVE $DPKG_ORIG_ARCHIVE
ln -s $VENDOR_ARCHIVE $DPKG_ORIG_VENDOR_ARCHIVE

# unpack it
cd $DPKG_AREA
tar xf $DPKG_ORIG_ARCHIVE

cd fish-$VERSION
mkdir cargo-vendor
cd cargo-vendor
tar xf $DPKG_ORIG_VENDOR_ARCHIVE
cd ..

# add debian packaging information
# this is copied in from the git repo
# the changes we make are thrown away - that is, not present in future builds
# this is ok for snapshots but not so much for releases. it might confuse
# apt-listchanges and other tools.
# a 'better' way might be to have the whole thing in git with something like
# git-buildpackage, but the workflow is fairly inflexible and there is lots of
# gaps in the documentation.
cp -r $FISH_SRCDIR/debian debian
dch --create --package fish --empty --newversion "$VERSION-1~unstable" --distribution unstable "Snapshot build from $MASTER_SHA"

# build and upload the packages
# lintian takes 10 minutes to run with the vendor tarballs included
for series in $PPA_SERIES; do
	sed -i "s/unstable/$series/g" debian/changelog
	debuild --no-lintian -S -sa -k$GPG_KEYID -d
	dput fish-nightly-master ../fish_"$VERSION"-1~"$series"_source.changes
	sed -i "s/$series/unstable/g" debian/changelog
done

###################
# OBS

# still in $DPKG_AREA
# do a source package for 'unstable', which gets uploaded to OBS, no dput
debuild --no-lintian -S -sa -k$GPG_KEYID -d

cd $OBS_AREA/shells:fish:nightly:master/fish
osc up

# Sources and Debian control
# clean up old files
OBSOLETE=`find . -maxdepth 1 -name fish_\*.orig\*.tar.\?z -o -name fish_\*.debian.tar.\?z -o -name fish_\*.dsc`
[ -n "$OBSOLETE" ] && echo $OBSOLETE | xargs rm
ln -s $DPKG_ORIG_ARCHIVE .
ln -s $DPKG_ORIG_VENDOR_ARCHIVE .
ln -s $DPKG_AREA/fish_"$VERSION"-1~unstable.dsc .
ln -s $DPKG_AREA/fish_"$VERSION"-1~unstable.debian.tar.xz .

# Spec file for RPM
sed "s/@VERSION@/$VERSION/
s/@RPMVERSION@/$RPMVERSION/" < $FISH_SRCDIR/fish.spec.in > fish.spec
osc addremove

# Commit changes
osc commit -m "Snapshot build from $MASTER_SHA"

# clean up
# removes the source tree but leaves the uploaded files behind
cd $DPKG_AREA
rm -rf ./fish-$VERSION
