#!/bin/bash -ex

git clean -ffxd && git reset --hard
# make sure sbt can find sonatype snapshots, i.e. the latest
# scala nightly.
cat > ~/.sbt/repositories <<EOF
[repositories]
  maven-central
  local
  typesafe-ivy-releases: http://repo.typesafe.com/typesafe/ivy-releases/, [organization]/[module]/[revision]/[type]s/[artifact](-[classifier]).[ext]
  pr-scala: http://private-repo.typesafe.com/typesafe/scala-pr-validation-snapshots/
  sonatype-snapshots: https://oss.sonatype.org/content/repositories/snapshots
  sonatype-releases: https://oss.sonatype.org/content/repositories/releases
  mavenLocal: file:///home/huitseeker/Scala/m2repo
EOF
# create classfiles - a higher version number does not work for Play,
# since with 2.10.4-RCs, dependencies have not been rebuilt
sbt-0.13.0 'set every scalaVersion:="2.10.3"' compile

# Prepare compilation environment
TMPDIR=$(mktemp -d compilXXX)
cat > $TMPDIR/compilationscript.sh <<EOF
#!/bin/bash -ex
EOF
sbt-0.13.0 'export compile' |grep -Ee '^scalac' >> $TMPDIR/compilationscript.sh


# The old process to download a scala 2.11 nightly : scala-dist

pushd $TMPDIR
wget https://github.com/scala/scala-dist/archive/master.zip
unzip master.zip && rm master.zip
mv scala-dist-master scala-dist
SCALA_211_DIR=scala-dist/target/universal/scala-2.11.0-SNAPSHOT
export PATH=`pwd`/$SCALA_211_DIR/bin:$PATH
cd scala-dist
sbt-0.13.0 'set version := "2.11.0-SNAPSHOT"' 'set resolvers += "private-repo" at "http://private-repo.typesafe.com/typesafe/scala-release-temp/"' universal:package-bin
cd target/universal && unzip scala-2.11.0-SNAPSHOT.zip
popd

# The new process: just find the latest file from the download page

# # this depends on the antechronological listing on that page. So be it
# pushd $TMPDIR
# SCALA_NIGHTLY_NAME=$(wget -q -O -
#     http://www.scala-lang.org/files/archive/nightly/distributions/ |  perl -lne 'if (/scala-2.11.0[^\"]*?.zip/){print $&; exit}' )
# wget -q "http://www.scala-lang.org/files/archive/nightly/distributions/$SCALA_NIGHTLY_NAME"
# unzip $SCALA_NIGHTLY_NAME && rm $SCALA_NIGHTLY_NAME
# SCALA_211_DIR=${SCALA_NIGHTLY_NAME%.zip}
# chmod +x $SCALA_211_DIR/bin/*
# export PATH=`pwd`/$SCALA_211_DIR/bin:$PATH
# popd

# Check : now this precise fresh scala 2.11 should be on the path
GREPEE=$($TMPDIR/$SCALA_211_DIR/bin/scala -version 2>&1 |grep -Eoe "2.11.0[^\ ]*")
if [[ $(scala -version 2>&1 | grep -Eoe "2.11.0[^\ ]*") != "$GREPEE" ]]; then echo "Couldn't put scala on path" && exit 2; fi

# protect the nightly and instrument it with a 2.10 library
SCALA_VERSION="2.10.4-RC2"
pushd $TMPDIR
wget "http://scala-lang.org/files/archive/scala-$SCALA_VERSION.tgz"
tar xzvf scala-$SCALA_VERSION.tgz && rm scala-$SCALA_VERSION.tgz
popd
SCALA_LIB_STR=$(find `pwd`/$TMPDIR/scala-$SCALA_VERSION/lib -iname "scala-library*" -printf "%p:")

# The scalac script f#$%* up and adds its scala library on cp if
# the cp is left empty, even with -nobootcp
# See SI-8368
sed -ir "/^.*-Dscala\.usejavacp=true.*/d" $TMPDIR/$SCALA_211_DIR/bin/scalac

if [[ $(basename `pwd`) == "framework" ]]; then
    for i in $(grep -lirc "`pwd`/src" --include="*\.scala" -Ee "scala\.reflect\.macros")
    do
        sed -ir "s|$i||g" $TMPDIR/compilationscript.sh
    done
    # no stinky macroes !
    sed -ir "s|$(find `pwd` -name "PlaySettings.scala" -printf %p)||g" $TMPDIR/compilationscript.sh
    sed -ir "s|$(find `pwd` -name "PlayEclipse.scala" -printf %p)||g" $TMPDIR/compilationscript.sh
    sed -ir "s|$(find `pwd` -name "PlayCommands.scala" -printf %p)||g" $TMPDIR/compilationscript.sh
    sed -ir "s|$(find `pwd` -name "Project.scala" -printf %p)||g" $TMPDIR/compilationscript.sh
    # remove duplicate same-line sources
    perl -pi.bak -e 's/(.*\.scala)\1/$1/g' $TMPDIR/compilationscript.sh

    # I have to add reflect to the classpath, because of Quasiquotes
    # hot call :( See SI-8392
    sed -ir  "s|-classpath |-classpath `pwd`/$TMPDIR/$SCALA_211_DIR/lib/scala-reflect.jar:|g" $TMPDIR/compilationscript.sh
fi

# remove library from the bootcp
sed -r  "s|(-bootclasspath .*):.*?scala-library-$SCALA_VERSION\.jar|\1|g" $TMPDIR/compilationscript.sh > $TMPDIR/compilationscript-without-bootcplib.sh


SCALAC="$(pwd)/$TMPDIR/$SCALA_211_DIR/bin/scalac"
# modify script inline to pass options to scala compiler
sed -ir "s|scalac|$SCALAC -nobootcp -Dscala.usejavacp=false -Xsource:2.10 -Ystop-after:typer -Ylog-classpath|" $TMPDIR/compilationscript-without-bootcplib.sh

# the space here in the pattern is important
sed -r "s|(scalac.*?-classpath) |\1 $SCALA_LIB_STR|" $TMPDIR/compilationscript-without-bootcplib.sh > $TMPDIR/compilationscript-withlibrary.sh

# current BC bug afflicting continuations ?
if [[ $(basename `pwd`) != "framework" ]]; then
    grep -v continuations $TMPDIR/compilationscript-withlibrary.sh > $TMPDIR/compilationscript-withoutcontinuations.sh
    chmod u+x $TMPDIR/compilationscript-withoutcontinuations.sh
    # the 2.11 typing run
    exec $TMPDIR/compilationscript-withoutcontinuations.sh
else
    chmod u+x $TMPDIR/compilationscript-withlibrary.sh
    # the 2.11 typing run
    exec $TMPDIR/compilationscript-withlibrary.sh
fi
