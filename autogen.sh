#!/bin/sh

echo "This is a dummy autogenerated file to make automake happy; please ignore it." > ChangeLog &&
touch po/POTFILES.in &&
aclocal -I m4 &&
autoheader &&
automake --add-missing --copy -Wno-portability &&
aclocal -I m4 &&
autoconf &&
autoheader
