#!/usr/bin/env bash
# Raspberry Pi Camera Module 3 (Wide, NoIR) — system setup.
#
# Nothing kernel-side is needed on Ubuntu 26.04: the imx708 sensor driver, the
# dw9807_vcm autofocus driver, rp1-cfe and pisp_be all load automatically from
# camera_auto_detect=1. Only the userspace stack was missing.
#
# Deliberately NOT adding the Raspberry Pi apt repo. Its libcamera/rpicam builds
# target Raspberry Pi OS; mixing them into Ubuntu breaks the stack. Ubuntu 26.04
# carries libcamera 0.7.0, rpicam-apps and picamera2 in the archive already.

source "$(dirname "${BASH_SOURCE[0]}")/../common/lib.sh"
require_root

say "Camera: installing libcamera userspace + rpicam-apps"
apt_install \
  libcamera-tools libcamera-ipa python3-libcamera \
  rpicam-apps gstreamer1.0-libcamera

say "Camera: installing Picamera2 (Python bindings)"
# Use the distro package, not pip: this system runs Python 3.14 and upstream
# wheels for the Pi imaging stack generally don't exist for it yet.
apt_install python3-picamera2

say "Camera: granting video device access"
add_user_to_group video
add_user_to_group render

say "Camera: done"
info "Verify with:  rpicam-hello --list-cameras"
