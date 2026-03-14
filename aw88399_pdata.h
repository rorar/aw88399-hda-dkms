/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef __AW88399_PDATA_H__
#define __AW88399_PDATA_H__

#define AW88399_DSM_CALIB_SIZE	9

/*
 * Platform data passed from aw88399_setup module to aw88399_hda driver
 * via i2c_board_info.platform_data.
 *
 * Contains speaker calibration data from ACPI _DSM and fault IRQ info.
 */
struct aw88399_pdata {
	/* _DSM function 3 calibration data (9 bytes from SPKR ACPI device) */
	u8 calib_data[AW88399_DSM_CALIB_SIZE];
	bool has_calib;
};

#endif /* __AW88399_PDATA_H__ */
