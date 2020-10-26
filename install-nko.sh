#!/bin/bash

#Update
sudo cp -vb base.lst /usr/share/X11/xkb/rules/base.lst
sudo cp -vb base.lst /usr/share/X11/xkb/rules/evdev.lst

sudo cp -vb base.xml /usr/share/X11/xkb/rules/base.xml
sudo cp -vb base.xml /usr/share/X11/xkb/rules/evdev.xml

# Install nqo Keyboard
echo "Installing Nko Keyboard";
sudo cp -vb nqo /usr/share/X11/xkb/symbols/nqo

sudo dpkg-reconfigure xkb-data
sudo systemctl restart keyboard-setup
# Install Fonts
sudo cp -vb NotoSansNKo-Regular.ttf /usr/share/fonts/opentype/noto/

fc-cache -f -v
