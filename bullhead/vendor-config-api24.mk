# Additional flags to be inserted at generated BoardConfigVendor.mk

# Bypass location API missing dependencies AOSP compilation problem
# Target shared libs are included as pre-build from factory image
BOARD_VENDOR_QCOM_GPS_LOC_API_HARDWARE :=
