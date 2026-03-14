// SPDX-License-Identifier: GPL-2.0-only
//
// aw88399_setup.c -- Helper module to work around ACPI scan.c limitation
//
// Since scan.c is built into vmlinux and can't be DKMS'd, this module:
// 1. Finds the existing single I2C client created by ACPI for AWDZ8399
// 2. Acquires the reset GPIO from the ACPI device
// 3. Performs hardware reset on the amplifiers
// 4. Queries _DSM for speaker calibration data
// 5. Acquires the interrupt IRQ for fault notification
// 6. Removes the single ACPI client
// 7. Creates two I2C client devices at addresses 0x34 and 0x35
//    passing calibration data and IRQ to each
//

#include <linux/module.h>
#include <linux/i2c.h>
#include <linux/acpi.h>
#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/interrupt.h>
#include "aw88399_pdata.h"

#define AW88399_I2C_ADDR_LEFT  0x35
#define AW88399_I2C_ADDR_RIGHT 0x34

/* SPKR _DSM UUID: 1cc539cd-5a26-4288-a572-25c5744ebf1b */
static const guid_t aw88399_dsm_guid =
	GUID_INIT(0x1cc539cd, 0x5a26, 0x4288,
		  0xa5, 0x72, 0x25, 0xc5, 0x74, 0x4e, 0xbf, 0x1b);

static struct i2c_client *aw88399_clients[2];
static struct i2c_adapter *saved_adapter;
static struct gpio_desc *reset_gpio;
static struct aw88399_pdata pdata;

/*
 * Perform hardware reset on the AW88399 amplifiers using the ACPI-declared
 * reset GPIO (from SPKR device _CRS, GpioIo resource at index 0).
 */
static void aw88399_hw_reset(struct device *acpi_dev)
{
	struct gpio_desc *gpio;

	/* Get GPIO at index 0 from the ACPI device (reset/shutdown line) */
	gpio = gpiod_get_index(acpi_dev, NULL, 0, GPIOD_OUT_LOW);
	if (IS_ERR(gpio)) {
		pr_warn("aw88399_setup: Could not get reset GPIO: %ld (non-fatal)\n",
			PTR_ERR(gpio));
		return;
	}

	reset_gpio = gpio;

	/* Reset sequence: low -> high -> low, with delays */
	gpiod_set_value_cansleep(gpio, 0);
	usleep_range(1000, 2000);
	gpiod_set_value_cansleep(gpio, 1);
	usleep_range(1000, 2000);
	gpiod_set_value_cansleep(gpio, 0);
	usleep_range(5000, 6000);

	pr_info("aw88399_setup: Hardware reset complete via GPIO\n");
}

/*
 * Query SPKR _DSM function 3 for speaker calibration/tuning data (9 bytes).
 * UUID: 1cc539cd-5a26-4288-a572-25c5744ebf1b
 *
 * Function 0 returns device count + I2C addresses
 * Function 1 returns number of amplifiers
 * Function 3 returns calibration parameters
 */
static void aw88399_query_dsm(acpi_handle handle)
{
	union acpi_object *obj;
	int i;

	memset(&pdata, 0, sizeof(pdata));

	obj = acpi_evaluate_dsm(handle, &aw88399_dsm_guid, 0, 3, NULL);
	if (!obj) {
		pr_info("aw88399_setup: _DSM function 3 not available\n");
		return;
	}

	if (obj->type == ACPI_TYPE_BUFFER &&
	    obj->buffer.length >= AW88399_DSM_CALIB_SIZE) {
		memcpy(pdata.calib_data, obj->buffer.pointer,
		       AW88399_DSM_CALIB_SIZE);
		pdata.has_calib = true;

		pr_info("aw88399_setup: _DSM calibration data:");
		for (i = 0; i < AW88399_DSM_CALIB_SIZE; i++)
			pr_cont(" %02x", pdata.calib_data[i]);
		pr_cont("\n");
	} else {
		pr_warn("aw88399_setup: _DSM function 3 unexpected type %d len %d\n",
			obj->type,
			obj->type == ACPI_TYPE_BUFFER ? obj->buffer.length : 0);
	}

	ACPI_FREE(obj);
}

/*
 * Get IRQ from ACPI-declared GpioInt (index 0 in _CRS GpioInt resources).
 * The SPKR device declares an ActiveLow edge interrupt for
 * over-temperature, over-current, and clip detection from the AW88399.
 */
static int aw88399_get_irq(struct acpi_device *adev)
{
	int irq;

	irq = acpi_dev_gpio_irq_get(adev, 0);
	if (irq > 0) {
		pr_info("aw88399_setup: Got fault IRQ %d from ACPI\n", irq);
		return irq;
	}

	pr_info("aw88399_setup: No IRQ from ACPI: %d (non-fatal)\n", irq);
	return 0;
}

static int aw88399_setup_init(void)
{
	struct i2c_client *existing = NULL;
	struct i2c_adapter *adapter = NULL;
	struct i2c_board_info info = {};
	struct acpi_device *adev = NULL;
	struct device *acpi_dev = NULL;
	int irq = 0;
	int i;

	/* Find the existing AWDZ8399 I2C client */
	for (i = 0; i < 32; i++) {
		struct device *dev;
		char name[32];

		adapter = i2c_get_adapter(i);
		if (!adapter)
			continue;

		snprintf(name, sizeof(name), "i2c-AWDZ8399:00");
		dev = bus_find_device_by_name(&i2c_bus_type, NULL, name);
		if (dev) {
			existing = to_i2c_client(dev);
			put_device(dev);
			break;
		}
		i2c_put_adapter(adapter);
		adapter = NULL;
	}

	if (!existing || !adapter) {
		pr_info("aw88399_setup: No AWDZ8399 I2C device found, trying adapter scan\n");
		for (i = 0; i < 32; i++) {
			adapter = i2c_get_adapter(i);
			if (!adapter)
				continue;
			if (strstr(adapter->name, "Synopsys DesignWare I2C")) {
				union i2c_smbus_data data;
				if (i2c_smbus_xfer(adapter, AW88399_I2C_ADDR_LEFT,
						   0, I2C_SMBUS_READ, 0,
						   I2C_SMBUS_BYTE_DATA, &data) >= 0) {
					pr_info("aw88399_setup: Found AW88399 on adapter %d\n", i);
					break;
				}
			}
			i2c_put_adapter(adapter);
			adapter = NULL;
		}
		if (!adapter) {
			pr_err("aw88399_setup: Could not find I2C adapter with AW88399\n");
			return -ENODEV;
		}
	} else {
		/* Get the adapter from the existing client */
		adapter = existing->adapter;
		i2c_get_adapter(adapter->nr);

		pr_info("aw88399_setup: Found existing AWDZ8399 on adapter %s (nr %d)\n",
			adapter->name, adapter->nr);

		/*
		 * Get the ACPI companion device BEFORE removing the I2C client.
		 * We need it to access the reset GPIO.
		 */
		adev = ACPI_COMPANION(&existing->dev);
		if (!adev) {
			/* Try finding it by HID */
			adev = acpi_dev_get_first_match_dev("AWDZ8399", NULL, -1);
		}
		if (adev) {
			acpi_dev = &adev->dev;
			get_device(acpi_dev);
		}

		if (acpi_dev) {
			/* Perform hardware reset using ACPI GPIO */
			aw88399_hw_reset(acpi_dev);

			/* Query _DSM calibration data */
			if (adev)
				aw88399_query_dsm(adev->handle);

			/* Get interrupt IRQ for fault notification */
			irq = aw88399_get_irq(adev);
		}

		/* Unbind and remove the existing client */
		device_release_driver(&existing->dev);
		i2c_unregister_device(existing);
		pr_info("aw88399_setup: Removed existing AWDZ8399 I2C client\n");

		if (acpi_dev)
			put_device(acpi_dev);

		msleep(100);
	}

	saved_adapter = adapter;

	/*
	 * Create two new I2C clients with dev_name set so the HDA component
	 * matching works. The comp_generic_fixup match pattern is:
	 *   bus="i2c", hid="AWDZ8399", match_str="-%s:00-aw88399-hda.%d"
	 * The matcher expects device names like:
	 *   "i2c-AWDZ8399:00-aw88399-hda.0"
	 *   "i2c-AWDZ8399:00-aw88399-hda.1"
	 * Setting dev_name causes i2c_dev_set_name() to prefix "i2c-".
	 */
	strscpy(info.type, "aw88399-hda", sizeof(info.type));
	info.platform_data = &pdata;
	info.irq = irq;

	info.addr = AW88399_I2C_ADDR_RIGHT;  /* 0x34 */
	info.dev_name = "AWDZ8399:00-aw88399-hda.0";
	aw88399_clients[0] = i2c_new_client_device(adapter, &info);
	if (IS_ERR(aw88399_clients[0])) {
		pr_err("aw88399_setup: Failed to create I2C client at 0x%02x: %ld\n",
		       info.addr, PTR_ERR(aw88399_clients[0]));
		aw88399_clients[0] = NULL;
		i2c_put_adapter(adapter);
		return -ENODEV;
	}
	pr_info("aw88399_setup: Created I2C client %s at 0x%02x (irq=%d, calib=%s)\n",
		dev_name(&aw88399_clients[0]->dev), info.addr, irq,
		pdata.has_calib ? "yes" : "no");

	info.addr = AW88399_I2C_ADDR_LEFT;   /* 0x35 */
	info.dev_name = "AWDZ8399:00-aw88399-hda.1";
	aw88399_clients[1] = i2c_new_client_device(adapter, &info);
	if (IS_ERR(aw88399_clients[1])) {
		pr_err("aw88399_setup: Failed to create I2C client at 0x%02x: %ld\n",
		       info.addr, PTR_ERR(aw88399_clients[1]));
		i2c_unregister_device(aw88399_clients[0]);
		aw88399_clients[0] = NULL;
		aw88399_clients[1] = NULL;
		i2c_put_adapter(adapter);
		return -ENODEV;
	}
	pr_info("aw88399_setup: Created I2C client %s at 0x%02x (irq=%d, calib=%s)\n",
		dev_name(&aw88399_clients[1]->dev), info.addr, irq,
		pdata.has_calib ? "yes" : "no");

	pr_info("aw88399_setup: AW88399 dual I2C setup complete\n");
	return 0;
}

static void aw88399_setup_exit(void)
{
	int i;

	for (i = 0; i < 2; i++) {
		if (aw88399_clients[i]) {
			i2c_unregister_device(aw88399_clients[i]);
			aw88399_clients[i] = NULL;
		}
	}

	/* Release reset GPIO */
	if (reset_gpio) {
		/* Assert reset before removing */
		gpiod_set_value_cansleep(reset_gpio, 1);
		gpiod_put(reset_gpio);
		reset_gpio = NULL;
	}

	if (saved_adapter) {
		i2c_put_adapter(saved_adapter);
		saved_adapter = NULL;
	}

	pr_info("aw88399_setup: Cleanup complete\n");
}

module_init(aw88399_setup_init);
module_exit(aw88399_setup_exit);

MODULE_DESCRIPTION("AW88399 I2C setup helper for DKMS (scan.c workaround)");
MODULE_AUTHOR("LenovoLegionLinux");
MODULE_LICENSE("GPL");
