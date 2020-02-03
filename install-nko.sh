#!/bin/bash

#Update
cp -v base.lst /usr/share/X11/xkb/rules/base.lst
cp -v base.lst /usr/share/X11/xkb/rules/evdev.lst

cp -v base.xml /usr/share/X11/xkb/rules/base.xml
cp -v base.xml /usr/share/X11/xkb/rules/base.xml

# Install nqo Keyboard
echo "Installing Nko Keyboard";
cp -v nqo /usr/share/X11/xkb/symbols/nqo

dpkg-reconfigure xkb-data
systemctl restart keyboard-setup
# Install Fonts
cp -v NotoSansNKo-Regular.ttf /usr/share/fonts/opentype/noto/

fc-cache -f -v
